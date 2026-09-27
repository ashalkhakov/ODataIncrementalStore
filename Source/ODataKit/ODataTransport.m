// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The default transport is NSURLSession wherever Foundation has it: Apple,
// and gnustep-base built with libcurl. gnustep-base's NSURLConnection is
// the fallback, and only that: it does not follow a relative redirect
// (NSURLProtocol resolves Location without the request URL, and the
// request times out), and it returns an empty body for a multipart
// response, which every $batch answer is (GSMimeParser keeps the parts,
// not the bytes).

#import "ODataTransport.h"
#import "ODataError.h"

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
  @synchronized([ODataExchange class]) {
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
