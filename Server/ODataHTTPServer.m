// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataHTTPServer.h"
#import "ODataService.h"
#import "GCDWebServer.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"

@implementation ODataHTTPServer {
  GCDWebServer *_server;
}

- (instancetype)initWithService:(ODataService *)service
{
  self = [super init];
  if (!self) return nil;
  _service = service;
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

- (NSDictionary *)optionsForPort:(NSUInteger)port
{
  return @{
    GCDWebServerOption_Port: @(port),
    GCDWebServerOption_BindToLocalhost: @(self.bindToLocalhost),
    GCDWebServerOption_MaxBodySize: @(self.maxBodySize),
    GCDWebServerOption_ServerName: @"ODataIncrementalStore",
    GCDWebServerOption_AutomaticallyMapHEADToGET: @NO,
  };
}

- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error
{
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

// The request target as the client sent it, still escaped, on the public
// root's scheme and host.
- (NSURL *)publicURLFor:(GCDWebServerRequest *)request
{
  NSURL *received = request.URL;
  NSString *target = received.relativeString ?: @"/";
  if ([target rangeOfString:@"://"].location != NSNotFound) {
    NSString *query = received.query;
    target = [(received.path.length ? received.path : @"/") stringByAppendingString:query ? [@"?" stringByAppendingString:query] : @""];
  }
  NSURL *root = self.service.serviceRoot;
  NSString *origin = [NSString stringWithFormat:@"%@://%@%@", root.scheme, root.host, root.port ? [NSString stringWithFormat:@":%@", root.port] : @""];
  return [NSURL URLWithString:[origin stringByAppendingString:target]];
}

- (void)answer:(GCDWebServerDataRequest *)request completion:(GCDWebServerCompletionBlock)completion
{
  NSURL *url = [self publicURLFor:request];
  if (!url) {
    completion([GCDWebServerResponse responseWithStatusCode:400]);
    return;
  }
  NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:url];
  urlRequest.HTTPMethod = request.method;
  for (NSString *name in request.headers) [urlRequest setValue:request.headers[name] forHTTPHeaderField:name];
  if (request.hasBody) urlRequest.HTTPBody = request.data;
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:urlRequest target:self action:@selector(exchangeDidFinish:)];
  exchange.context = completion;
  [self.service startExchange:exchange];
}

- (void)exchangeDidFinish:(ODataExchange *)exchange
{
  GCDWebServerCompletionBlock completion = exchange.context;
  NSHTTPURLResponse *http = [exchange.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)exchange.URLResponse : nil;
  if (!http) {
    completion([GCDWebServerResponse responseWithStatusCode:500]);
    return;
  }
  NSDictionary *headers = http.allHeaderFields;
  NSString *type = nil;
  for (NSString *name in headers) {
    if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame) type = headers[name];
  }
  GCDWebServerResponse *response;
  if (exchange.data.length) {
    response = [GCDWebServerDataResponse responseWithData:exchange.data contentType:type ?: @"application/octet-stream"];
  } else {
    response = [GCDWebServerResponse response];
  }
  response.statusCode = http.statusCode;
  for (NSString *name in headers) {
    if ([name caseInsensitiveCompare:@"Content-Type"] == NSOrderedSame || [name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
    [response setValue:headers[name] forAdditionalHeader:name];
  }
  if (http.statusCode >= 500) {
    NSLog(@"ODataHTTPServer: %@ %@ answered %ld", exchange.request.HTTPMethod, exchange.request.URL, (long)http.statusCode);
  }
  completion(response);
}

@end
