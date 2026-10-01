// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataServerMessage.h"
#import "ODataError.h"
#import "ODataAuthentication.h"

// The value of a header by any case of its name.
static NSString *OISHeaderIn(NSDictionary<NSString *, NSString *> *headers, NSString *name)
{
  NSString *exact = headers[name];
  if (exact) return exact;
  for (NSString *key in headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
  }
  return nil;
}

@implementation ODataServerRequest

- (instancetype)initWithMethod:(NSString *)method URL:(NSURL *)URL headers:(NSDictionary *)headers body:(NSData *)body
{
  self = [super init];
  if (!self) return nil;
  _method = [method.uppercaseString copy];
  _URL = [URL copy];
  _headers = [headers copy] ?: @{};
  _body = body.length ? [body copy] : nil;
  _pathParameters = @{};
  _userInfo = [NSMutableDictionary dictionary];
  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:YES];
  _path = components.path.length ? components.path : @"/";
  NSString *escaped = components.percentEncodedPath.length ? components.percentEncodedPath : @"/";
  _target = components.percentEncodedQuery ? [NSString stringWithFormat:@"%@?%@", escaped, components.percentEncodedQuery] : escaped;
  NSMutableDictionary *query = [NSMutableDictionary dictionary];
  for (NSURLQueryItem *item in components.queryItems) query[item.name] = item.value ?: @"";
  _query = query;
  return self;
}

- (NSString *)valueForHeader:(NSString *)name
{
  return OISHeaderIn(self.headers, name);
}

- (id)JSONBody
{
  return self.body ? [NSJSONSerialization JSONObjectWithData:self.body options:0 error:NULL] : nil;
}

- (NSURLRequest *)URLRequestOnOrigin:(NSURL *)origin
{
  NSURL *url = self.URL;
  if (origin.host) {
    // The target as it came, still escaped, after the public origin.
    NSString *port = origin.port ? [NSString stringWithFormat:@":%@", origin.port] : @"";
    url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://%@%@%@", origin.scheme ?: @"http", origin.host, port, self.target]] ?: url;
  }
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = self.method;
  for (NSString *name in self.headers) [request setValue:self.headers[name] forHTTPHeaderField:name];
  request.HTTPBody = self.body;
  return request;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataServerRequest %@ %@>", self.method, self.target];
}

@end

@implementation ODataServerResponse {
  NSMutableDictionary<NSString *, NSString *> *_headers;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _status = 200;
  _headers = [NSMutableDictionary dictionary];
  return self;
}

+ (instancetype)responseWithStatus:(NSInteger)status
{
  ODataServerResponse *response = [[self alloc] init];
  response.status = status;
  return response;
}

+ (instancetype)responseWithStatus:(NSInteger)status body:(NSData *)body contentType:(NSString *)contentType
{
  ODataServerResponse *response = [self responseWithStatus:status];
  response.body = body;
  if (contentType && body) [response setValue:contentType forHeader:@"Content-Type"];
  return response;
}

+ (instancetype)responseWithJSON:(id)json status:(NSInteger)status
{
  NSData *body = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] ?: [NSData data];
  return [self responseWithStatus:status body:body contentType:@"application/json;charset=utf-8"];
}

+ (instancetype)responseWithText:(NSString *)text status:(NSInteger)status
{
  return [self responseWithStatus:status body:[text dataUsingEncoding:NSUTF8StringEncoding] contentType:@"text/plain;charset=utf-8"];
}

+ (instancetype)responseWithError:(NSError *)error
{
  NSInteger status = 500;
  NSString *message = @"The server could not answer the request";
  if ([error.domain isEqualToString:ODataServiceErrorDomain] && error.code >= 400 && error.code < 600) {
    status = error.code;
    message = error.localizedDescription ?: message;
  } else if (error) {
    // Its own words may say more of the server than a client should know.
    NSLog(@"ODataServer: %@", error);
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                               error.userInfo[ODataErrorCodeKey] ?: [NSString stringWithFormat:@"%ld", (long)status], @"code",
                               message, @"message", nil];
  if (error.userInfo[ODataErrorTargetKey]) body[@"target"] = error.userInfo[ODataErrorTargetKey];
  ODataServerResponse *response = [self responseWithJSON:@{ @"error": body } status:status];
  // The scopes it needs, as the challenge names them (RFC 6750 section 3).
  NSArray *scopes = [error.userInfo[ODataErrorScopesKey] isKindOfClass:[NSArray class]] ? error.userInfo[ODataErrorScopesKey] : nil;
  NSString *scope = [[scopes componentsJoinedByString:@" "] stringByReplacingOccurrencesOfString:@"\"" withString:@""];
  if (status == 401) {
    [response setValue:scope.length ? [NSString stringWithFormat:@"Bearer scope=\"%@\"", scope] : @"Bearer" forHeader:@"WWW-Authenticate"];
  } else if (status == 403 && scope.length) {
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"\"\\"];
    NSString *description = [[message componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"'"];
    [response setValue:[NSString stringWithFormat:@"Bearer realm=\"odata\", error=\"insufficient_scope\", error_description=\"%@\", scope=\"%@\"",
                                                  description, scope]
             forHeader:@"WWW-Authenticate"];
  }
  return response;
}

- (NSDictionary *)headers
{
  @synchronized (self) {
    return [_headers copy];
  }
}

- (NSString *)valueForHeader:(NSString *)name
{
  @synchronized (self) {
    return OISHeaderIn(_headers, name);
  }
}

- (void)setValue:(NSString *)value forHeader:(NSString *)name
{
  @synchronized (self) {
    for (NSString *key in _headers.allKeys) {
      if ([key caseInsensitiveCompare:name] == NSOrderedSame) [_headers removeObjectForKey:key];
    }
    if (value) _headers[name] = value;
  }
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataServerResponse %ld, %lu bytes>", (long)self.status, (unsigned long)self.body.length];
}

@end

@interface ODataServerReply ()
@property (nonatomic, strong, nullable) id target;
@property (nonatomic) SEL action;
@property (nonatomic, readwrite) BOOL finished;
@property (nonatomic, readwrite, strong, nullable) ODataServerResponse *response;
@end

@implementation ODataServerReply

- (instancetype)initWithTarget:(id)target action:(SEL)action
{
  self = [super init];
  if (!self) return nil;
  _target = target;
  _action = action;
  return self;
}

- (void)finishWithResponse:(ODataServerResponse *)response
{
  id target;
  @synchronized (self) {
    if (self.finished) return;
    self.finished = YES;
    self.response = response ?: [ODataServerResponse responseWithStatus:500];
    target = self.target;
    self.target = nil;
  }
  if (!target) return;
  void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:self.action];
  send(target, self.action, self);
}

- (void)failWithError:(NSError *)error
{
  [self finishWithResponse:[ODataServerResponse responseWithError:error]];
}

@end
