// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataServerHandlers.h"
#import "ODataService.h"
#import "ODataAuthentication.h"
#import "ODataError.h"

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

- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  NSURLRequest *urlRequest = [request URLRequestOnOrigin:self.service.serviceRoot];
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

#pragma mark - Access log

@implementation ODataAccessLogStage

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
  NSString *line = [NSString stringWithFormat:@"%@ %@ \"%@ %@\" %ld %lu %.1fms %@", request.remoteAddress ?: @"-", who, request.method,
                                              request.target, (long)response.status, (unsigned long)response.body.length,
                                              milliseconds, request.userInfo[ODataServerRequestIDKey] ?: @"-"];
  [self writeLine:line];
}

- (void)writeLine:(NSString *)line
{
  fprintf(stderr, "%s\n", line.UTF8String);
}

@end
