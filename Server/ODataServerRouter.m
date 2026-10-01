// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataServerRouter.h"
#import "ODataError.h"
#import "ODataAuthentication.h"

static NSArray<NSString *> *OISSegments(NSString *path)
{
  NSMutableArray *segments = [NSMutableArray array];
  for (NSString *part in [path componentsSeparatedByString:@"/"]) {
    if (part.length) [segments addObject:part];
  }
  return segments;
}

@implementation ODataServerRoute {
  NSArray<NSString *> *_segments;
}

+ (instancetype)routeWithMethod:(NSString *)method path:(NSString *)pattern handler:(id<ODataServerHandler>)handler
{
  return [[self alloc] initWithMethod:method path:pattern handler:handler];
}

- (instancetype)initWithMethod:(NSString *)method path:(NSString *)pattern handler:(id<ODataServerHandler>)handler
{
  self = [super init];
  if (!self) return nil;
  _method = [method.uppercaseString copy];
  _pattern = [pattern copy];
  _handler = handler;
  _segments = OISSegments(pattern);
  return self;
}

- (NSDictionary *)parametersOfPath:(NSString *)path
{
  NSArray<NSString *> *parts = OISSegments(path);
  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
  NSUInteger count = _segments.count;
  BOOL rest = count && [_segments.lastObject isEqualToString:@"*"];
  if (rest) count--;
  if (rest ? parts.count < count : parts.count != count) return nil;
  for (NSUInteger i = 0; i < count; i++) {
    NSString *segment = _segments[i];
    if ([segment hasPrefix:@":"] && segment.length > 1) {
      parameters[[segment substringFromIndex:1]] = parts[i];
    } else if (![segment isEqualToString:parts[i]]) {
      return nil;
    }
  }
  if (rest) parameters[@"*"] = [[parts subarrayWithRange:NSMakeRange(count, parts.count - count)] componentsJoinedByString:@"/"];
  return parameters;
}

- (BOOL)takesMethod:(NSString *)method
{
  if (!self.method) return YES;
  NSString *asked = method.uppercaseString;
  return [self.method isEqualToString:asked] || ([self.method isEqualToString:@"GET"] && [asked isEqualToString:@"HEAD"]);
}

- (NSString *)description
{
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@ -> %@", self.method ?: @"*", self.pattern, self.handler];
  if (self.scopes.count) {
    [text appendFormat:@" (scopes %@)", [[self.scopes.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "]];
  } else if (self.requiresPrincipal) {
    [text appendString:@" (signed in)"];
  }
  return text;
}

@end

@implementation ODataServerRouter

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _routes = @[];
  return self;
}

- (void)addRoute:(ODataServerRoute *)route
{
  @synchronized (self) {
    self.routes = [self.routes arrayByAddingObject:route];
  }
}

- (void)insertRoute:(ODataServerRoute *)route atIndex:(NSUInteger)index
{
  @synchronized (self) {
    NSMutableArray *routes = [self.routes mutableCopy];
    [routes insertObject:route atIndex:MIN(index, routes.count)];
    self.routes = routes;
  }
}

- (void)removeRoute:(ODataServerRoute *)route
{
  @synchronized (self) {
    NSMutableArray *routes = [self.routes mutableCopy];
    [routes removeObjectIdenticalTo:route];
    self.routes = routes;
  }
}

- (ODataServerRoute *)routeWithPath:(NSString *)pattern method:(NSString *)method
{
  for (ODataServerRoute *route in self.routes) {
    if ([route.pattern isEqualToString:pattern] && (!method || [route.method isEqualToString:method.uppercaseString])) return route;
  }
  return nil;
}

- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  NSArray<ODataServerRoute *> *routes;
  @synchronized (self) {
    routes = self.routes;
  }
  NSMutableOrderedSet *allowed = [NSMutableOrderedSet orderedSet];
  for (ODataServerRoute *route in routes) {
    NSDictionary *parameters = [route parametersOfPath:request.path];
    if (!parameters) continue;
    if (![route takesMethod:request.method]) {
      [allowed addObject:route.method];
      if ([route.method isEqualToString:@"GET"]) [allowed addObject:@"HEAD"];
      continue;
    }
    request.pathParameters = parameters;
    request.route = route;
    if (![self request:request mayCall:route reply:reply]) return;
    [route.handler handleRequest:request reply:reply];
    return;
  }
  if (allowed.count) {
    ODataServerResponse *response = [ODataServerResponse responseWithError:ODataServiceError(405, [NSString stringWithFormat:@"%@ is not taken here", request.method])];
    [response setValue:[allowed.array componentsJoinedByString:@", "] forHeader:@"Allow"];
    [reply finishWithResponse:response];
    return;
  }
  [reply failWithError:ODataServiceError(404, [NSString stringWithFormat:@"Nothing answers %@", request.path])];
}

// Who may call a route: refused (answered) when the caller is not.
- (BOOL)request:(ODataServerRequest *)request mayCall:(ODataServerRoute *)route reply:(ODataServerReply *)reply
{
  NSSet<NSString *> *scopes = route.scopes;
  if (!scopes.count && !route.requiresPrincipal) return YES;
  ODataPrincipal *principal = request.principal;
  NSArray *named = [scopes.allObjects sortedArrayUsingSelector:@selector(compare:)];
  if (principal && (!scopes.count || [scopes intersectsSet:principal.scopes])) return YES;
  NSString *what = [NSString stringWithFormat:@"%@ %@", request.method, request.path];
  NSString *message = !principal ? [NSString stringWithFormat:@"%@ names no one: sign in", what]
                                 : [NSString stringWithFormat:@"To call %@ needs one of the scopes %@", what, [named componentsJoinedByString:@" "]];
  NSMutableDictionary *info = [ODataServiceError(principal ? 403 : 401, message).userInfo mutableCopy];
  if (named.count) info[ODataErrorScopesKey] = named;
  [reply failWithError:[NSError errorWithDomain:ODataServiceErrorDomain code:principal ? 403 : 401 userInfo:info]];
  return NO;
}

- (NSString *)description
{
  NSMutableString *text = [NSMutableString stringWithString:@"<ODataServerRouter"];
  for (ODataServerRoute *route in self.routes) [text appendFormat:@"\n  %@", route];
  [text appendString:@">"];
  return text;
}

@end
