// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataServerHandlers.h"
#import "ODataService.h"
#import "ODataAuthentication.h"
#import "ODataError.h"
#import "ODataServerRouter.h"
#import "ODataServerObservability.h"
#include <zlib.h>
#include <time.h>
#include <sys/time.h>

NSString * const ODataServerRequestIDKey = @"OData.requestID";
static NSString * const OISStartKey = @"OData.started";

#pragma mark - A mounted service

@implementation ODataServiceHandler

- (instancetype)initWithService:(ODataService *)service
{
  self = [super init];
  if (!self) return nil;
  _service = service;
  return self;
}

// What a request under the service root asks, by a name of few values: the
// entity set (or operation import) it names first, $metadata, $batch...;
// the service document; or (other), so a client cannot make up new ones.
- (NSString *)operationOf:(ODataServerRequest *)request
{
  NSString *root = self.service.serviceRoot.path.length ? self.service.serviceRoot.path : @"/";
  NSString *path = request.path;
  NSString *rest = [path hasPrefix:root] ? [path substringFromIndex:root.length] : @"";
  if ([rest hasPrefix:@"/"]) rest = [rest substringFromIndex:1];
  NSString *first = [rest componentsSeparatedByString:@"/"].firstObject ?: @"";
  NSRange parenthesis = [first rangeOfString:@"("];
  if (parenthesis.location != NSNotFound) first = [first substringToIndex:parenthesis.location];
  if (!first.length) return @"(service document)";
  if ([first hasPrefix:@"$"] && first.length < 20) return first;
  return [self.service.entitySets containsObject:first] ? first : @"(other)";
}

- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  request.operation = [self operationOf:request];
  NSMutableURLRequest *urlRequest = [[request URLRequestOnOrigin:self.service.serviceRoot] mutableCopy];
  // Who asked, for the service's handlers and logs: the request id, and the
  // trace context this server's span carries on.
  NSString *requestID = request.userInfo[ODataServerRequestIDKey];
  if (requestID) [urlRequest setValue:requestID forHTTPHeaderField:@"X-Request-ID"];
  NSString *traceparent = request.userInfo[ODataServerTraceparentKey];
  if (traceparent) [urlRequest setValue:traceparent forHTTPHeaderField:@"traceparent"];
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:urlRequest target:self action:@selector(exchangeDidFinish:)];
  exchange.context = reply;
  if (request.authenticated) {
    [self.service startExchange:exchange principal:request.principal];
  } else {
    [self.service startExchange:exchange];
  }
}

- (void)exchangeDidFinish:(ODataExchange *)exchange
{
  ODataServerReply *reply = exchange.context;
  NSHTTPURLResponse *http = [exchange.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)exchange.URLResponse : nil;
  if (!http) {
    [reply failWithError:exchange.error ?: ODataServiceError(500, @"The service gave no answer")];
    return;
  }
  ODataServerResponse *response = [ODataServerResponse responseWithStatus:http.statusCode];
  response.body = exchange.data.length ? exchange.data : nil;
  NSDictionary *headers = http.allHeaderFields;
  for (NSString *name in headers) {
    if ([name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
    [response setValue:headers[name] forHeader:name];
  }
  if (http.statusCode >= 500) {
    NSLog(@"ODataServer: %@ %@ answered %ld", exchange.request.HTTPMethod, exchange.request.URL, (long)http.statusCode);
  }
  [reply finishWithResponse:response];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataServiceHandler %@>", self.service.serviceRoot.absoluteString];
}

@end

#pragma mark - Health

@implementation ODataHealthHandler

- (NSDictionary *)status
{
  return @{ @"status": @"ok" };
}

- (NSInteger)statusCode
{
  return 200;
}

- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  ODataServerResponse *response = [ODataServerResponse responseWithJSON:[self status] status:[self statusCode]];
  [response setValue:@"no-store" forHeader:@"Cache-Control"];
  [reply finishWithResponse:response];
}

- (NSString *)description
{
  return @"<ODataHealthHandler>";
}

@end

#pragma mark - Authentication

// One request's question to the authenticator, and where it goes next.
@interface OISAuthenticationStep : NSObject
@property (nonatomic, strong) ODataServerRequest *request;
@property (nonatomic, strong) ODataServerReply *reply;
@property (nonatomic, strong) id<ODataServerHandler> next;
@end

@implementation OISAuthenticationStep

- (void)didAuthenticate:(ODataAuthentication *)answer
{
  if (answer.error) {
    ODataServerResponse *response = [ODataServerResponse responseWithError:answer.error];
    if (answer.challenge) [response setValue:answer.challenge forHeader:@"WWW-Authenticate"];
    [self.reply finishWithResponse:response];
    return;
  }
  self.request.principal = answer.principal;
  self.request.authenticated = YES;
  [self.next handleRequest:self.request reply:self.reply];
}

@end

@implementation ODataAuthenticationStage

- (instancetype)initWithAuthenticator:(id<ODataAuthenticator>)authenticator
{
  self = [super init];
  if (!self) return nil;
  _authenticator = authenticator;
  _timeout = 60;
  return self;
}

// It waits for the authenticator, so it owns its step.
- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply next:(id<ODataServerHandler>)next
{
  OISAuthenticationStep *step = [[OISAuthenticationStep alloc] init];
  step.request = request;
  step.reply = reply;
  step.next = next;
  [ODataAuthentication authenticateURLRequest:[request URLRequestOnOrigin:nil] with:self.authenticator
                                      timeout:self.timeout target:step action:@selector(didAuthenticate:)];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataAuthenticationStage %@>", NSStringFromClass([(NSObject *)self.authenticator class])];
}

@end

#pragma mark - Request ids

@implementation ODataRequestIDStage

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _headerName = @"X-Request-ID";
  return self;
}

// One a log line can carry as it is: short, and nothing but visible ASCII.
static BOOL OISUsableID(NSString *given)
{
  if (!given.length || given.length > 128) return NO;
  for (NSUInteger i = 0; i < given.length; i++) {
    unichar c = [given characterAtIndex:i];
    if (c <= ' ' || c > '~') return NO;
  }
  return YES;
}

- (BOOL)shouldPassRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  NSString *given = [request valueForHeader:self.headerName];
  request.userInfo[ODataServerRequestIDKey] = OISUsableID(given) ? given : [NSUUID UUID].UUIDString.lowercaseString;
  return YES;
}

- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response
{
  [response setValue:request.userInfo[ODataServerRequestIDKey] forHeader:self.headerName];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataRequestIDStage %@>", self.headerName];
}

@end

#pragma mark - CORS

@implementation ODataCORSStage

- (instancetype)initWithAllowedOrigins:(NSArray<NSString *> *)origins
{
  self = [super init];
  if (!self) return nil;
  _allowedOrigins = [origins copy] ?: @[];
  _allowedMethods = @[ @"GET", @"HEAD", @"POST", @"PUT", @"PATCH", @"DELETE" ];
  _allowedHeaders = @[ @"Authorization", @"Content-Type", @"Accept", @"OData-Version", @"OData-MaxVersion", @"If-Match",
                       @"If-None-Match", @"Prefer", @"Isolation", @"X-Request-ID" ];
  _exposedHeaders = @[ @"OData-Version", @"ETag", @"Location", @"OData-EntityId", @"Preference-Applied", @"Retry-After",
                       @"WWW-Authenticate", @"X-Request-ID" ];
  _maxAge = 600;
  return self;
}

- (BOOL)allowsOrigin:(NSString *)origin
{
  for (NSString *allowed in self.allowedOrigins) {
    if ([allowed isEqualToString:@"*"] || [allowed caseInsensitiveCompare:origin] == NSOrderedSame) return YES;
  }
  return NO;
}

// Who the response is for: the origin itself, unless any may read it and
// no credentials go with it.
- (void)allowOrigin:(NSString *)origin onResponse:(ODataServerResponse *)response
{
  BOOL any = [self.allowedOrigins containsObject:@"*"] && !self.allowsCredentials;
  [response setValue:any ? @"*" : origin forHeader:@"Access-Control-Allow-Origin"];
  if (!any) {
    NSString *vary = [response valueForHeader:@"Vary"];
    if (![vary.lowercaseString containsString:@"origin"]) [response setValue:vary.length ? [vary stringByAppendingString:@", Origin"] : @"Origin" forHeader:@"Vary"];
  }
  if (self.allowsCredentials) [response setValue:@"true" forHeader:@"Access-Control-Allow-Credentials"];
}

- (BOOL)shouldPassRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  NSString *origin = [request valueForHeader:@"Origin"];
  NSString *asked = [request valueForHeader:@"Access-Control-Request-Method"];
  if (!origin || ![request.method isEqualToString:@"OPTIONS"] || !asked) return YES;
  if (![self allowsOrigin:origin] || ![self.allowedMethods containsObject:asked.uppercaseString]) {
    [reply failWithError:ODataServiceError(403, [NSString stringWithFormat:@"%@ may not %@ here", origin, asked])];
    return NO;
  }
  ODataServerResponse *response = [ODataServerResponse responseWithStatus:204];
  [self allowOrigin:origin onResponse:response];
  [response setValue:[self.allowedMethods componentsJoinedByString:@", "] forHeader:@"Access-Control-Allow-Methods"];
  // The headers it asks for, those it may.
  NSMutableArray *headers = [NSMutableArray array];
  for (NSString *header in [[request valueForHeader:@"Access-Control-Request-Headers"] ?: @"" componentsSeparatedByString:@","]) {
    NSString *name = [header stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSString *allowed in self.allowedHeaders) {
      if (name.length && [allowed caseInsensitiveCompare:name] == NSOrderedSame) [headers addObject:allowed];
    }
  }
  if (headers.count) [response setValue:[headers componentsJoinedByString:@", "] forHeader:@"Access-Control-Allow-Headers"];
  [response setValue:[NSString stringWithFormat:@"%lu", (unsigned long)self.maxAge] forHeader:@"Access-Control-Max-Age"];
  [reply finishWithResponse:response];
  return NO;
}

- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response
{
  NSString *origin = [request valueForHeader:@"Origin"];
  if (!origin || ![self allowsOrigin:origin] || [response valueForHeader:@"Access-Control-Allow-Origin"]) return;
  [self allowOrigin:origin onResponse:response];
  if (self.exposedHeaders.count) [response setValue:[self.exposedHeaders componentsJoinedByString:@", "] forHeader:@"Access-Control-Expose-Headers"];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataCORSStage %@>", [self.allowedOrigins componentsJoinedByString:@" "]];
}

@end

#pragma mark - Compression

@implementation ODataCompressionStage

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _minimumSize = 1024;
  _compressibleTypes = @[ @"application/json", @"application/xml", @"application/xhtml+xml", @"text/" ];
  return self;
}

// Whether the client takes gzip: named (or *) in Accept-Encoding without q=0.
static BOOL OISTakesGzip(NSString *accepted)
{
  for (NSString *item in [accepted ?: @"" componentsSeparatedByString:@","]) {
    NSArray *parts = [item componentsSeparatedByString:@";"];
    NSString *coding = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
    if (![coding isEqualToString:@"gzip"] && ![coding isEqualToString:@"*"]) continue;
    BOOL refused = NO;
    for (NSString *parameter in [parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]) {
      NSString *p = [parameter stringByReplacingOccurrencesOfString:@" " withString:@""].lowercaseString;
      if ([p hasPrefix:@"q="] && [[p substringFromIndex:2] doubleValue] <= 0) refused = YES;
    }
    if (!refused) return YES;
  }
  return NO;
}

- (BOOL)compresses:(NSString *)contentType
{
  NSString *type = [[contentType componentsSeparatedByString:@";"][0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
  for (NSString *compressible in self.compressibleTypes) {
    if ([compressible hasSuffix:@"/"] ? [type hasPrefix:compressible] : [type isEqualToString:compressible]) return YES;
    if ([type hasSuffix:@"+json"] && [compressible isEqualToString:@"application/json"]) return YES;
  }
  return NO;
}

static NSData *OISGzip(NSData *data)
{
  z_stream stream;
  memset(&stream, 0, sizeof(stream));
  if (deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY) != Z_OK) return nil;
  NSMutableData *compressed = [NSMutableData dataWithLength:deflateBound(&stream, (uLong)data.length) + 32];
  stream.next_in = (Bytef *)data.bytes;
  stream.avail_in = (uInt)data.length;
  stream.next_out = compressed.mutableBytes;
  stream.avail_out = (uInt)compressed.length;
  int status = deflate(&stream, Z_FINISH);
  compressed.length = stream.total_out;
  deflateEnd(&stream);
  return status == Z_STREAM_END ? compressed : nil;
}

- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response
{
  NSData *body = response.body;
  if (body.length < self.minimumSize || response.status == 204 || response.status == 304) return;
  if ([response valueForHeader:@"Content-Encoding"] || ![self compresses:[response valueForHeader:@"Content-Type"] ?: @""]) return;
  // Whether it is compressed depends on what the client takes, for a cache.
  NSString *vary = [response valueForHeader:@"Vary"];
  if (![vary.lowercaseString containsString:@"accept-encoding"]) {
    [response setValue:vary.length ? [vary stringByAppendingString:@", Accept-Encoding"] : @"Accept-Encoding" forHeader:@"Vary"];
  }
  if (!OISTakesGzip([request valueForHeader:@"Accept-Encoding"])) return;
  NSData *compressed = OISGzip(body);
  if (!compressed || compressed.length >= body.length) return;
  response.body = compressed;
  [response setValue:@"gzip" forHeader:@"Content-Encoding"];
  // The same entity, other bytes: a strong ETag no longer holds.
  NSString *etag = [response valueForHeader:@"ETag"];
  if (etag.length && ![etag hasPrefix:@"W/"]) [response setValue:[@"W/" stringByAppendingString:etag] forHeader:@"ETag"];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataCompressionStage from %lu bytes>", (unsigned long)self.minimumSize];
}

@end

#pragma mark - Access log

// Now, as RFC 3339 in UTC with milliseconds.
static NSString *OISTimestamp(void)
{
  struct timeval now;
  gettimeofday(&now, NULL);
  struct tm utc;
  gmtime_r(&now.tv_sec, &utc);
  char text[32];
  strftime(text, sizeof(text), "%Y-%m-%dT%H:%M:%S", &utc);
  return [NSString stringWithFormat:@"%s.%03dZ", text, (int)(now.tv_usec / 1000)];
}

@implementation ODataAccessLogStage

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _slowRequestThreshold = 1;
  return self;
}

- (BOOL)shouldPassRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  request.userInfo[OISStartKey] = [NSDate date];
  return YES;
}

- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response
{
  NSDate *started = request.userInfo[OISStartKey];
  double milliseconds = started ? -[started timeIntervalSinceNow] * 1000.0 : 0;
  NSString *who = request.principal.subject ?: @"-";
  if (self.format == ODataAccessLogJSON) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[@"time"] = OISTimestamp();
    entry[@"level"] = response.status >= 500 || milliseconds > self.slowRequestThreshold * 1000 ? @"warn" : @"info";
    entry[@"remote"] = request.remoteAddress ?: [NSNull null];
    entry[@"principal"] = request.principal.subject ?: [NSNull null];
    entry[@"method"] = request.method;
    entry[@"target"] = request.target;
    entry[@"route"] = request.route.pattern ?: [NSNull null];
    entry[@"operation"] = request.operation ?: [NSNull null];
    entry[@"status"] = @(response.status);
    entry[@"bytes"] = response.bodyFileURL || response.bodyStream ? [NSNull null] : @(response.body.length);
    // A decimal, so it is written as 0.7, not as the double nearest it.
    entry[@"duration_ms"] = [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.1f", milliseconds]];
    entry[@"request_id"] = request.userInfo[ODataServerRequestIDKey] ?: [NSNull null];
    entry[@"trace_id"] = request.userInfo[ODataServerTraceIDKey] ?: [NSNull null];
    entry[@"user_agent"] = [request valueForHeader:@"User-Agent"] ?: [NSNull null];
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
    [self writeLine:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    return;
  }
  // A file's or a stream's size is not known here.
  NSString *size = response.bodyFileURL || response.bodyStream ? @"-" : [NSString stringWithFormat:@"%lu", (unsigned long)response.body.length];
  NSString *line = [NSString stringWithFormat:@"%@ %@ \"%@ %@\" %ld %@ %.1fms %@", request.remoteAddress ?: @"-", who, request.method,
                                              request.target, (long)response.status, size, milliseconds,
                                              request.userInfo[ODataServerRequestIDKey] ?: @"-"];
  [self writeLine:line];
}

- (void)writeLine:(NSString *)line
{
  fprintf(stderr, "%s\n", line.UTF8String);
}

@end
