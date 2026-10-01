// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSMessage.h"
#import "HSRouter.h"
#import "HSAuthentication.h"

NSErrorDomain const HSErrorDomain = @"org.gnu.ois.HTTPServerKit";
NSString * const HSErrorTypeKey = @"HSErrorType";
NSString * const HSErrorScopesKey = @"HSErrorScopes";

NSError *HSError(NSInteger status, NSString *message)
{
  return [NSError errorWithDomain:HSErrorDomain code:status
                         userInfo:@{ NSLocalizedDescriptionKey: message ?: [NSHTTPURLResponse localizedStringForStatusCode:status] }];
}

static NSMutableSet<NSString *> *HSStatusDomains(void)
{
  static NSMutableSet *domains;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    domains = [NSMutableSet set];
  });
  return domains;
}

void HSRegisterStatusErrorDomain(NSErrorDomain domain)
{
  @synchronized (HSStatusDomains()) {
    [HSStatusDomains() addObject:domain];
  }
}

// RFC 9110's reason phrases, for a problem's title.
static NSString *HSReasonPhrase(NSInteger status)
{
  static NSDictionary *phrases;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    phrases = @{ @400: @"Bad Request", @401: @"Unauthorized", @403: @"Forbidden", @404: @"Not Found", @405: @"Method Not Allowed",
                 @406: @"Not Acceptable", @408: @"Request Timeout", @409: @"Conflict", @410: @"Gone", @411: @"Length Required",
                 @412: @"Precondition Failed", @413: @"Content Too Large", @414: @"URI Too Long", @415: @"Unsupported Media Type",
                 @422: @"Unprocessable Content", @428: @"Precondition Required", @429: @"Too Many Requests",
                 @500: @"Internal Server Error", @501: @"Not Implemented", @502: @"Bad Gateway", @503: @"Service Unavailable",
                 @504: @"Gateway Timeout" };
  });
  return phrases[@(status)] ?: (status >= 500 ? @"Server Error" : @"Client Error");
}

// The value of a header by any case of its name.
static NSString *HSHeaderIn(NSDictionary<NSString *, NSString *> *headers, NSString *name)
{
  NSString *exact = headers[name];
  if (exact) return exact;
  for (NSString *key in headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
  }
  return nil;
}

@implementation HSRequest {
  NSData *_body;
  id _owner;
}

- (instancetype)initWithMethod:(NSString *)method URL:(NSURL *)URL headers:(NSDictionary *)headers body:(NSData *)body
{
  self = [self initWithMethod:method URL:URL headers:headers bodyFileURL:nil owner:nil];
  if (!self) return nil;
  _body = body.length ? [body copy] : nil;
  return self;
}

- (instancetype)initWithMethod:(NSString *)method URL:(NSURL *)URL headers:(NSDictionary *)headers
                   bodyFileURL:(NSURL *)bodyFileURL owner:(id)owner
{
  self = [super init];
  if (!self) return nil;
  _method = [method.uppercaseString copy];
  _URL = [URL copy];
  _headers = [headers copy] ?: @{};
  _bodyFileURL = [bodyFileURL copy];
  _owner = owner;
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
  return HSHeaderIn(self.headers, name);
}

// A file's, mapped rather than read, once.
- (NSData *)body
{
  @synchronized (self) {
    if (!_body && _bodyFileURL) {
      NSData *mapped = [NSData dataWithContentsOfURL:_bodyFileURL options:NSDataReadingMappedIfSafe error:NULL];
      _body = mapped.length ? mapped : nil;
    }
    return _body;
  }
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
  return [NSString stringWithFormat:@"<HSRequest %@ %@>", self.method, self.target];
}

@end

@implementation HSResponse {
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
  HSResponse *response = [[self alloc] init];
  response.status = status;
  return response;
}

+ (instancetype)responseWithStatus:(NSInteger)status body:(NSData *)body contentType:(NSString *)contentType
{
  HSResponse *response = [self responseWithStatus:status];
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

+ (instancetype)responseWithFile:(NSURL *)file contentType:(NSString *)contentType status:(NSInteger)status
{
  HSResponse *response = [self responseWithStatus:status];
  response.bodyFileURL = file;
  [response setValue:contentType ?: @"application/octet-stream" forHeader:@"Content-Type"];
  return response;
}

+ (instancetype)responseWithStream:(id<HSResponseStream>)stream contentType:(NSString *)contentType status:(NSInteger)status
{
  HSResponse *response = [self responseWithStatus:status];
  response.bodyStream = stream;
  [response setValue:contentType ?: @"application/octet-stream" forHeader:@"Content-Type"];
  return response;
}

+ (instancetype)responseWithError:(NSError *)error
{
  return [self responseWithError:error request:nil];
}

+ (instancetype)responseWithError:(NSError *)error request:(HSRequest *)request
{
  HSRoute *route = request.route;
  id<HSErrorFormatting> formatter = route.errorFormatter;
  if (formatter) {
    HSResponse *formatted = [formatter responseForError:error request:request];
    if (formatted) return formatted;
  }
  NSInteger status = [self statusOfError:error];
  NSString *detail = @"The server could not answer the request";
  if (status != 500 || [error.domain isEqualToString:HSErrorDomain]) {
    detail = error.localizedDescription ?: detail;
  } else if (error) {
    // Its own words may say more of the server than a client should know.
    NSLog(@"HTTPServerKit: %@", error);
  }
  NSMutableDictionary *problem = [NSMutableDictionary dictionary];
  problem[@"type"] = [error.userInfo[HSErrorTypeKey] isKindOfClass:[NSString class]] ? error.userInfo[HSErrorTypeKey] : @"about:blank";
  problem[@"title"] = HSReasonPhrase(status);
  problem[@"status"] = @(status);
  problem[@"detail"] = detail;
  NSData *body = [NSJSONSerialization dataWithJSONObject:problem options:0 error:NULL];
  HSResponse *response = [self responseWithStatus:status body:body contentType:@"application/problem+json"];
  NSString *challenge = [self challengeForError:error];
  if (challenge) [response setValue:challenge forHeader:@"WWW-Authenticate"];
  return response;
}

+ (NSInteger)statusOfError:(NSError *)error
{
  if (!error) return 500;
  BOOL statusDomain = [error.domain isEqualToString:HSErrorDomain];
  @synchronized (HSStatusDomains()) {
    statusDomain = statusDomain || [HSStatusDomains() containsObject:error.domain];
  }
  return statusDomain && error.code >= 400 && error.code < 600 ? error.code : 500;
}

+ (NSString *)challengeForError:(NSError *)error
{
  NSInteger status = [self statusOfError:error];
  NSArray *scopes = [error.userInfo[HSErrorScopesKey] isKindOfClass:[NSArray class]] ? error.userInfo[HSErrorScopesKey] : nil;
  NSString *scope = [[scopes componentsJoinedByString:@" "] stringByReplacingOccurrencesOfString:@"\"" withString:@""];
  if (status == 401) return scope.length ? [NSString stringWithFormat:@"Bearer scope=\"%@\"", scope] : @"Bearer";
  if (status == 403 && scope.length) {
    NSCharacterSet *unsafe = [NSCharacterSet characterSetWithCharactersInString:@"\"\\"];
    NSString *description = [[error.localizedDescription ?: @"" componentsSeparatedByCharactersInSet:unsafe] componentsJoinedByString:@"'"];
    return [NSString stringWithFormat:@"Bearer realm=\"api\", error=\"insufficient_scope\", error_description=\"%@\", scope=\"%@\"",
                                      description, scope];
  }
  return nil;
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
    return HSHeaderIn(_headers, name);
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
  return [NSString stringWithFormat:@"<HSResponse %ld, %lu bytes>", (long)self.status, (unsigned long)self.body.length];
}

@end

@interface HSReply ()
@property (nonatomic, strong, nullable) id target;
@property (nonatomic) SEL action;
@property (nonatomic, readwrite) BOOL finished;
@property (nonatomic, readwrite, strong, nullable) HSResponse *response;
@end

@implementation HSReply

- (instancetype)initWithTarget:(id)target action:(SEL)action
{
  self = [super init];
  if (!self) return nil;
  _target = target;
  _action = action;
  return self;
}

- (void)finishWithResponse:(HSResponse *)response
{
  id target;
  @synchronized (self) {
    if (self.finished) return;
    self.finished = YES;
    self.response = response ?: [HSResponse responseWithStatus:500];
    target = self.target;
    self.target = nil;
  }
  if (!target) return;
  void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:self.action];
  send(target, self.action, self);
}

- (void)failWithError:(NSError *)error
{
  [self finishWithResponse:[HSResponse responseWithError:error request:self.request]];
}

@end
