// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Requests go out through a transport and come back by target-action (an
// ODataExchange). The synchronous methods, which the store uses because
// NSIncrementalStore's callbacks are synchronous, wait on a condition for
// the exchange to finish; nothing else has to be asynchronous.
//
// The default transport is NSURLSession wherever Foundation has it: Apple,
// and gnustep-base built with libcurl. gnustep-base's NSURLConnection is
// the fallback, and only that: it does not follow a relative redirect
// (NSURLProtocol resolves Location without the request URL, and the
// request times out), and it returns an empty body for a multipart
// response, which every $batch answer is (GSMimeParser keeps the parts,
// not the bytes).

#import "ODataClient.h"
#import "ODataError.h"
#import "ODataBatch.h"

#if defined(__APPLE__) || (defined(GS_HAVE_NSURLSESSION) && GS_HAVE_NSURLSESSION)
#define OIS_HAVE_NSURLSESSION 1
#else
#define OIS_HAVE_NSURLSESSION 0
#endif

NSString * const ODataMessagesAnnotation = @"@Org.OData.Core.V1.Messages";

@implementation ODataMessage

+ (instancetype)messageWithCode:(NSString *)code text:(NSString *)text severity:(NSString *)severity target:(NSString *)target
{
  ODataMessage *message = [[self alloc] init];
  message.code = code ?: @"";
  message.message = text ?: @"";
  message.severity = severity ?: @"info";
  message.target = target;
  message.details = @[];
  return message;
}

static ODataMessage *OISMessageFromJSON(id json)
{
  if (![json isKindOfClass:[NSDictionary class]]) return nil;
  id code = json[@"code"], text = json[@"message"], severity = json[@"severity"], target = json[@"target"];
  ODataMessage *message = [ODataMessage messageWithCode:[code isKindOfClass:[NSString class]] ? code : [code description]
                                                   text:[text isKindOfClass:[NSString class]] ? text : @""
                                               severity:[severity isKindOfClass:[NSString class]] ? severity : @"info"
                                                 target:[target isKindOfClass:[NSString class]] ? target : nil];
  NSMutableArray *details = [NSMutableArray array];
  for (id detail in [json[@"details"] isKindOfClass:[NSArray class]] ? json[@"details"] : @[]) {
    ODataMessage *inner = OISMessageFromJSON(detail);
    if (inner) [details addObject:inner];
  }
  message.details = details;
  return message;
}

+ (NSArray *)messagesInJSON:(id)json
{
  if (![json isKindOfClass:[NSDictionary class]]) return nil;
  id list = json[ODataMessagesAnnotation] ?: json[@"@Core.Messages"];
  if (![list isKindOfClass:[NSArray class]]) return nil;
  NSMutableArray *messages = [NSMutableArray array];
  for (id item in list) {
    ODataMessage *message = OISMessageFromJSON(item);
    if (message) [messages addObject:message];
  }
  return messages.count ? messages : nil;
}

- (NSDictionary *)JSONObject
{
  NSMutableDictionary *json = [@{ @"code": self.code ?: @"", @"message": self.message ?: @"", @"severity": self.severity ?: @"info" } mutableCopy];
  if (self.target) json[@"target"] = self.target;
  if (self.details.count) json[@"details"] = [self.details valueForKey:@"JSONObject"];
  return json;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataMessage %@ %@: %@%@>", self.severity, self.code, self.message,
          self.target ? [@" at " stringByAppendingString:self.target] : @""];
}

@end

@implementation ODataHTTPResponse
- (NSString *)etag
{
  return [self valueForHeader:@"ETag"];
}

- (NSString *)valueForHeader:(NSString *)name
{
  for (NSString *key in self.headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return self.headers[key];
  }
  return nil;
}

- (id)JSONWithError:(NSError **)error
{
  id json = [NSJSONSerialization JSONObjectWithData:self.data ?: [NSData data] options:0 error:error];
  return json ? ODataNormalizedControlInformation(json, [self valueForHeader:@"OData-Version"]) : nil;
}
@end

#pragma mark - Control information

// The control information names of JSON Format 4.01 section 4.5.
static NSString *OISControlName(NSString *annotation)
{
  static NSSet *names;
  if (!names) {
    names = [NSSet setWithArray:@[ @"context", @"metadataEtag", @"type", @"count", @"nextLink", @"deltaLink", @"id",
                                   @"editLink", @"readLink", @"etag", @"navigationLink", @"associationLink",
                                   @"mediaEditLink", @"mediaReadLink", @"mediaContentType", @"mediaEtag",
                                   @"removed", @"delta", @"bind" ]];
  }
  return [names containsObject:annotation] ? [@"odata." stringByAppendingString:annotation] : nil;
}

id ODataNormalizedControlInformation(id json, NSString *version)
{
  if ([version hasPrefix:@"4.0"] && ![version hasPrefix:@"4.01"]) return json;
  if ([json isKindOfClass:[NSArray class]]) {
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:[json count]];
    for (id item in json) [out addObject:ODataNormalizedControlInformation(item, version)];
    return out;
  }
  if (![json isKindOfClass:[NSDictionary class]]) return json;
  NSMutableDictionary *out = [NSMutableDictionary dictionaryWithCapacity:[json count]];
  for (NSString *key in json) {
    id value = ODataNormalizedControlInformation(json[key], version);
    NSRange at = [key rangeOfString:@"@" options:NSBackwardsSearch];
    NSString *prefixed = at.location == NSNotFound ? nil : OISControlName([key substringFromIndex:at.location + 1]);
    if (prefixed) {
      NSString *spelled = [NSString stringWithFormat:@"%@@%@", [key substringToIndex:at.location], prefixed];
      if (!json[spelled]) out[spelled] = value;
      continue;
    }
    out[key] = value;
  }
  return out;
}

#pragma mark - Exchanges

@implementation ODataExchange {
  id _target;
  SEL _action;
  BOOL _finished;
}

- (instancetype)initWithRequest:(NSURLRequest *)request target:(id)target action:(SEL)action
{
  self = [super init];
  if (!self) return nil;
  _request = [request copy];
  _target = target;
  _action = action;
  return self;
}

- (BOOL)isFinished
{
  @synchronized(self) {
    return _finished;
  }
}

- (void)finish
{
  id target;
  SEL action;
  @synchronized(self) {
    if (_finished) return;
    _finished = YES;
    target = _target;
    action = _action;
    _target = nil;
  }
  if (target && action) {
    void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:action];
    send(target, action, self);
  }
}
@end

// Waits for an exchange: the target of the synchronous methods.
@interface OISWaiter : NSObject
- (void)exchangeDidFinish:(ODataExchange *)exchange;
- (BOOL)waitUntil:(NSDate *)deadline;
@end

@implementation OISWaiter {
  NSCondition *_condition;
  BOOL _done;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _condition = [[NSCondition alloc] init];
  return self;
}

- (void)exchangeDidFinish:(ODataExchange *)exchange
{
  [_condition lock];
  _done = YES;
  [_condition signal];
  [_condition unlock];
}

- (BOOL)waitUntil:(NSDate *)deadline
{
  [_condition lock];
  while (!_done && [_condition waitUntilDate:deadline]) {}
  BOOL done = _done;
  [_condition unlock];
  return done;
}
@end

#pragma mark - Default transports

#if OIS_HAVE_NSURLSESSION
@interface OISURLSessionTransport : NSObject <ODataTransport>
@end

@implementation OISURLSessionTransport
- (void)startExchange:(ODataExchange *)exchange
{
  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:exchange.request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
          exchange.data = data;
          exchange.URLResponse = response;
          exchange.error = error;
          [exchange finish];
        }];
  [task resume];
}
@end
#endif

#if !defined(__APPLE__)
// gnustep-base without libcurl: a synchronous NSURLConnection on a thread
// of its own, so the thread that started the exchange is free to wait.
@interface OISURLConnectionTransport : NSObject <ODataTransport>
@end

@implementation OISURLConnectionTransport
- (void)startExchange:(ODataExchange *)exchange
{
  [NSThread detachNewThreadSelector:@selector(send:) toTarget:self withObject:exchange];
}

- (void)send:(ODataExchange *)exchange
{
  @autoreleasepool {
    NSURLResponse *response = nil;
    NSError *error = nil;
    exchange.data = [NSURLConnection sendSynchronousRequest:exchange.request returningResponse:&response error:&error];
    exchange.URLResponse = response;
    exchange.error = error;
    [exchange finish];
  }
}
@end
#endif

id<ODataTransport> ODataDefaultTransport(void)
{
  static id<ODataTransport> transport;
  @synchronized([ODataClient class]) {
    if (!transport) {
#if OIS_HAVE_NSURLSESSION
      if (NSClassFromString(@"NSURLSession")) transport = [[OISURLSessionTransport alloc] init];
#endif
#if !defined(__APPLE__)
      if (!transport) transport = [[OISURLConnectionTransport alloc] init];
#endif
    }
  }
  return transport;
}

#pragma mark - The client

@implementation ODataClient

- (instancetype)initWithConfiguration:(ODataConfiguration *)configuration
{
  self = [super init];
  if (!self) return nil;
  _configuration = configuration;
  return self;
}

// The client's own exchange rides in the transport's as its context.
- (ODataExchange *)sendRequest:(NSURLRequest *)request target:(id)target action:(SEL)action
{
  NSMutableURLRequest *req = [request mutableCopy];
  [self.configuration applyToRequest:req];
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:req target:target action:action];
  [self transport:req context:exchange action:@selector(requestDidFinish:)];
  return exchange;
}

- (void)transport:(NSURLRequest *)request context:(ODataExchange *)exchange action:(SEL)action
{
  id<ODataTransport> transport = self.transport ?: ODataDefaultTransport();
  ODataExchange *wire = [[ODataExchange alloc] initWithRequest:request target:self action:action];
  wire.context = exchange;
  if (!transport) {
    wire.error = OISError(ODataIncrementalStoreErrorTransport, @"No transport: this Foundation has neither NSURLSession nor NSURLConnection");
    [wire finish];
    return;
  }
  [transport startExchange:wire];
}

// An HTTP response from the wire as an ODataHTTPResponse, or the error an
// error status is.
- (ODataHTTPResponse *)responseFrom:(ODataExchange *)wire error:(NSError **)error
{
  if (wire.error) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, wire.error.localizedDescription);
    return nil;
  }
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)wire.URLResponse;
  if (![http isKindOfClass:[NSHTTPURLResponse class]]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, @"No HTTP response");
    return nil;
  }
  NSData *body = wire.data ?: [NSData data];
  if (http.statusCode >= 400) {
    ODataIncrementalStoreErrorCode code = http.statusCode == 412
        ? ODataIncrementalStoreErrorOptimisticLocking
        : (ODataIncrementalStoreErrorCode)(ODataIncrementalStoreErrorHTTP + http.statusCode);
    if (error) *error = OISHTTPError(code, http.statusCode, http.URL ?: wire.request.URL, body);
    return nil;
  }
  ODataHTTPResponse *out = [[ODataHTTPResponse alloc] init];
  out.status = http.statusCode;
  out.data = body;
  out.headers = http.allHeaderFields ?: @{};
  out.URL = http.URL;
  return out;
}

- (void)requestDidFinish:(ODataExchange *)wire
{
  ODataExchange *exchange = wire.context;
  NSError *error = nil;
  exchange.response = [self responseFrom:wire error:&error];
  exchange.error = error;
  exchange.URLResponse = wire.URLResponse;
  exchange.data = wire.data;
  [exchange finish];
}

// Waits for an exchange started by `start`, for as long as the request's
// own timeout allows and then some; a transport that never finishes is an
// error rather than a hang.
- (ODataExchange *)waitFor:(ODataExchange *(^)(OISWaiter *waiter))start error:(NSError **)error
{
  OISWaiter *waiter = [[OISWaiter alloc] init];
  ODataExchange *exchange = start(waiter);
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:self.configuration.timeout + 30.0];
  if (![waiter waitUntil:deadline]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, @"The transport did not finish the request");
    return nil;
  }
  if (exchange.error) {
    if (error) *error = exchange.error;
    return nil;
  }
  return exchange;
}

- (ODataHTTPResponse *)sendRequest:(NSURLRequest *)request error:(NSError **)error
{
  NSError *failure = nil;
  ODataHTTPResponse *response = [self waitFor:^ODataExchange *(OISWaiter *waiter) {
    return [self sendRequest:request target:waiter action:@selector(exchangeDidFinish:)];
  } error:&failure].response;
  BOOL refused = !response && [failure.userInfo[ODataErrorHTTPStatusKey] integerValue] == 401;
  // Refused: once more, with a fresh token from the provider.
  if (refused && [self.configuration refreshCredentials]) {
    NSMutableURLRequest *again = [request mutableCopy];
    [again setValue:nil forHTTPHeaderField:@"Authorization"];
    failure = nil;
    response = [self waitFor:^ODataExchange *(OISWaiter *waiter) {
      return [self sendRequest:again target:waiter action:@selector(exchangeDidFinish:)];
    } error:&failure].response;
    refused = !response && [failure.userInfo[ODataErrorHTTPStatusKey] integerValue] == 401;
  }
  // Refused still: what the service would take, as $metadata says.
  NSString *expected = refused ? self.configuration.expectedCredentials : nil;
  if (expected) {
    NSMutableDictionary *info = [failure.userInfo mutableCopy];
    info[NSLocalizedRecoverySuggestionErrorKey] = expected;
    failure = [NSError errorWithDomain:failure.domain code:failure.code userInfo:info];
  }
  if (!response && error) *error = failure;
  return response;
}

- (id)JSONAtURL:(NSURL *)url error:(NSError **)error
{
  return [self JSONAtURL:url headers:nil error:error];
}

- (id)JSONAtURL:(NSURL *)url headers:(NSDictionary *)headers error:(NSError **)error
{
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  for (NSString *name in headers) [req setValue:headers[name] forHTTPHeaderField:name];
  ODataHTTPResponse *response = [self sendRequest:req error:error];
  if (!response) return nil;
  if (response.status == 204) return [NSNull null];
  return [response JSONWithError:error];
}

- (NSString *)textAtURL:(NSURL *)url error:(NSError **)error
{
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  [req setValue:@"text/plain" forHTTPHeaderField:@"Accept"];
  ODataHTTPResponse *response = [self sendRequest:req error:error];
  if (!response) return nil;
  return [[NSString alloc] initWithData:response.data encoding:NSUTF8StringEncoding] ?: @"";
}

- (ODataHTTPResponse *)sendJSONMethod:(NSString *)method
                                  URL:(NSURL *)url
                                 body:(id)body
                                 etag:(NSString *)etag
                                error:(NSError **)error
{
  NSMutableURLRequest *req = [self requestWithMethod:method URL:url body:body etag:etag error:error];
  return req ? [self sendRequest:req error:error] : nil;
}

- (NSArray *)sendChangeSet:(NSArray *)requests error:(NSError **)error
{
  return [self waitFor:^ODataExchange *(OISWaiter *waiter) {
    return [self sendChangeSet:requests target:waiter action:@selector(exchangeDidFinish:)];
  } error:error].responses;
}

- (ODataExchange *)sendChangeSet:(NSArray *)requests target:(id)target action:(SEL)action
{
  NSString *boundary = [@"batch_" stringByAppendingString:[[NSUUID UUID] UUIDString]];
  NSURL *url = [self.configuration.serviceRoot URLByAppendingPathComponent:@"$batch"];
  NSMutableURLRequest *batch = [NSMutableURLRequest requestWithURL:url];
  batch.HTTPMethod = @"POST";
  batch.HTTPBody = ODataChangeSetBody(requests, boundary);
  [batch setValue:[@"multipart/mixed; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
  [batch setValue:@"multipart/mixed" forHTTPHeaderField:@"Accept"];
  [self.configuration applyToRequest:batch];
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:batch target:target action:action];
  exchange.context = requests;
  [self transport:batch context:exchange action:@selector(changeSetDidFinish:)];
  return exchange;
}

- (void)changeSetDidFinish:(ODataExchange *)wire
{
  ODataExchange *exchange = wire.context;
  NSArray *requests = exchange.context;
  NSError *error = nil;
  exchange.responses = [self changeSetResponsesFrom:wire requests:requests error:&error];
  exchange.error = error;
  exchange.URLResponse = wire.URLResponse;
  exchange.data = wire.data;
  [exchange finish];
}

- (NSArray *)changeSetResponsesFrom:(ODataExchange *)wire requests:(NSArray *)requests error:(NSError **)error
{
  ODataHTTPResponse *response = [self responseFrom:wire error:error];
  if (!response) return nil;
  NSURL *url = wire.request.URL;
  NSString *responseBoundary = ODataMultipartBoundary([response valueForHeader:@"Content-Type"] ?: @"");
  NSArray *parts = responseBoundary ? ODataBatchParts(response.data, responseBoundary) : nil;
  if (!parts) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, @"The $batch response is not a multipart body");
    return nil;
  }
  // A change set that failed is answered with one response: the failure
  // (section 11.7.7.5).
  for (ODataBatchPart *part in parts) {
    if (part.status < 400) continue;
    NSUInteger index = part.contentID ? (NSUInteger)(part.contentID.integerValue - 1) : 0;
    NSURL *failed = index < requests.count ? [requests[index] URL] : url;
    ODataIncrementalStoreErrorCode code = part.status == 412
        ? ODataIncrementalStoreErrorOptimisticLocking
        : (ODataIncrementalStoreErrorCode)(ODataIncrementalStoreErrorHTTP + part.status);
    if (error) *error = OISHTTPError(code, part.status, failed, part.body);
    return nil;
  }
  if (parts.count != requests.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding,
                                 [NSString stringWithFormat:@"$batch answered %lu of %lu requests", (unsigned long)parts.count, (unsigned long)requests.count]);
    return nil;
  }
  NSMutableArray *responses = [NSMutableArray array];
  for (NSUInteger i = 0; i < parts.count; i++) {
    ODataBatchPart *part = parts[i];
    ODataHTTPResponse *one = [[ODataHTTPResponse alloc] init];
    one.status = part.status;
    one.data = part.body;
    one.headers = part.headers;
    one.URL = [requests[i] URL];
    [responses addObject:one];
  }
  return responses;
}

- (NSMutableURLRequest *)requestWithMethod:(NSString *)method
                                      URL:(NSURL *)url
                                     body:(id)body
                                     etag:(NSString *)etag
                                    error:(NSError **)error
{
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = method;
  if (body) {
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
    if (!req.HTTPBody) return nil;
  }
  if (etag) [req setValue:etag forHTTPHeaderField:@"If-Match"];
  // The entity back in the response, with its new key and ETag, saves a
  // GET (Part 1 section 8.2.8.7). Not for $ref, which has no entity.
  BOOL entity = ([method isEqualToString:@"POST"] || [method isEqualToString:@"PATCH"]) &&
                ![url.path hasSuffix:@"/$ref"];
  if (entity) [req setValue:@"return=representation" forHTTPHeaderField:@"Prefer"];
  [self.configuration applyToRequest:req];
  return req;
}

- (NSData *)metadataWithError:(NSError **)error
{
  NSURL *url = [self.configuration.serviceRoot URLByAppendingPathComponent:@"$metadata"];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  [req setValue:@"application/xml" forHTTPHeaderField:@"Accept"];
  return [self sendRequest:req error:error].data;
}

@end
