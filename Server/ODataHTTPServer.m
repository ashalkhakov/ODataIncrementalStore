// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataHTTPServer.h"
#import "ODataServerRouter.h"
#import "ODataServerHandlers.h"
#import "ODataService.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#include <errno.h>

// One request's way back to the socket.
@interface OISListenerAnswer : NSObject
@property (nonatomic, copy) GCDWebServerCompletionBlock completion;
@property (nonatomic) BOOL headOnly;
@end

@implementation OISListenerAnswer

- (void)replyDidFinish:(ODataServerReply *)reply
{
  ODataServerResponse *answer = reply.response;
  NSDictionary *headers = answer.headers;
  NSData *body = self.headOnly ? nil : answer.body;
  GCDWebServerResponse *response;
  if (body.length) {
    response = [GCDWebServerDataResponse responseWithData:body contentType:[answer valueForHeader:@"Content-Type"] ?: @"application/octet-stream"];
  } else {
    response = [GCDWebServerResponse response];
  }
  response.statusCode = answer.status;
  for (NSString *name in headers) {
    if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame || [name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
    [response setValue:headers[name] forAdditionalHeader:name];
  }
  // HEAD: the headers a GET would have, with no body.
  if (self.headOnly && answer.body.length && [answer valueForHeader:@"Content-Type"]) {
    [response setValue:[answer valueForHeader:@"Content-Type"] forAdditionalHeader:@"Content-Type"];
  }
  self.completion(response);
}

@end

@implementation ODataHTTPServer {
  GCDWebServer *_server;
}

- (instancetype)initWithHandler:(id<ODataServerHandler>)handler
{
  self = [super init];
  if (!self) return nil;
  _handler = handler;
  _bindToLocalhost = YES;
  _maxBodySize = 64 * 1024 * 1024;
  _server = [[GCDWebServer alloc] init];
  __weak ODataHTTPServer *weakSelf = self;
  [_server addHandlerWithMatchBlock:^GCDWebServerRequest *(NSString *method, NSURL *url, NSDictionary *headers, NSString *path, NSDictionary *query) {
    return [[GCDWebServerDataRequest alloc] initWithMethod:method url:url headers:headers path:path query:query];
  } asyncProcessBlock:^(GCDWebServerRequest *request, GCDWebServerCompletionBlock completion) {
    [weakSelf answer:(GCDWebServerDataRequest *)request completion:completion];
  }];
  return self;
}

- (instancetype)initWithService:(ODataService *)service
{
  ODataServerRouter *router = [[ODataServerRouter alloc] init];
  NSString *root = service.serviceRoot.path.length ? service.serviceRoot.path : @"/";
  [router addRoute:[ODataServerRoute routeWithMethod:nil path:[root stringByAppendingPathComponent:@"*"]
                                           handler:[[ODataServiceHandler alloc] initWithService:service]]];
  self = [self initWithHandler:router];
  if (!self) return nil;
  _service = service;
  return self;
}

- (NSDictionary *)optionsForPort:(NSUInteger)port
{
  return @{
    GCDWebServerOption_Port: @(port),
    GCDWebServerOption_BindToLocalhost: @(self.bindToLocalhost),
    GCDWebServerOption_MaxBodySize: @(self.maxBodySize),
    GCDWebServerOption_ServerName: @"ODataServer",
    GCDWebServerOption_AutomaticallyMapHEADToGET: @NO,
  };
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error
{
  // With port 0 GCDWebServer takes the port the system picks for IPv4 and
  // binds IPv6 to the same one, which may be taken there: then any other
  // free port will do.
  for (int attempt = 0; attempt < 8; attempt++) {
    NSError *failure = nil;
    if ([_server startWithOptions:[self optionsForPort:port] error:&failure]) return YES;
    BOOL taken = [failure.domain isEqualToString:NSPOSIXErrorDomain] && failure.code == EADDRINUSE;
    if (port != 0 || !taken) {
      if (error) *error = failure;
      return NO;
    }
  }
  return [_server startWithOptions:[self optionsForPort:port] error:error];
}

- (BOOL)runOnPort:(NSUInteger)port error:(NSError **)error
{
  return [_server runWithOptions:[self optionsForPort:port] error:error];
}

- (void)stop
{
  [_server stop];
}

- (BOOL)isRunning
{
  return _server.running;
}

- (NSUInteger)port
{
  return _server.port;
}

// The request target as the client sent it, still escaped, on the host it
// was sent to.
- (NSURL *)URLOf:(GCDWebServerRequest *)request
{
  NSURL *received = request.URL;
  NSString *target = received.relativeString ?: @"/";
  if ([target rangeOfString:@"://"].location != NSNotFound) {
    NSString *query = received.query;
    target = [(received.path.length ? received.path : @"/") stringByAppendingString:query ? [@"?" stringByAppendingString:query] : @""];
  }
  NSString *host = request.headers[@"Host"];
  for (NSString *name in request.headers) {
    if ([name caseInsensitiveCompare:@"Host"] == NSOrderedSame) host = request.headers[name];
  }
  if (!host.length || [host rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#@ "]].location != NSNotFound) {
    host = [NSString stringWithFormat:@"127.0.0.1:%lu", (unsigned long)self.port];
  }
  return [NSURL URLWithString:[NSString stringWithFormat:@"http://%@%@", host, target]];
}

- (void)answer:(GCDWebServerDataRequest *)request completion:(GCDWebServerCompletionBlock)completion
{
  NSURL *url = [self URLOf:request];
  if (!url) {
    completion([GCDWebServerResponse responseWithStatusCode:400]);
    return;
  }
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSString *name in request.headers) headers[name] = request.headers[name];
  ODataServerRequest *httpRequest = [[ODataServerRequest alloc] initWithMethod:request.method URL:url headers:headers
                                                                      body:request.hasBody ? request.data : nil];
  httpRequest.remoteAddress = request.remoteAddressString;
  OISListenerAnswer *answer = [[OISListenerAnswer alloc] init];
  answer.completion = completion;
  answer.headOnly = [httpRequest.method isEqualToString:@"HEAD"];
  ODataServerReply *reply = [[ODataServerReply alloc] initWithTarget:answer action:@selector(replyDidFinish:)];
  [self.handler handleRequest:httpRequest reply:reply];
}

@end
