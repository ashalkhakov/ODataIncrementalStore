// HSRouter — which handler answers a request, by its method and path.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Routes are objects in an ordered array, the first that matches answering:
// add the specific ones before a mount that takes everything under a path.
// A path that some route has, but not for this method, is answered 405
// with Allow; a path none has, 404.

#pragma once
#import <Foundation/Foundation.h>
#import "HSPipeline.h"

NS_ASSUME_NONNULL_BEGIN

@interface HSRoute : NSObject
// method: GET, POST, ... (GET also takes HEAD); nil for any. pattern:
// segments, each literal or :name (one segment, by that name in the
// request's pathParameters); a last segment * takes the rest of the path,
// none or more segments ("*"): /odata/* answers /odata and all under it.
+ (instancetype)routeWithMethod:(nullable NSString *)method path:(NSString *)pattern handler:(id<HSHandler>)handler;
- (instancetype)initWithMethod:(nullable NSString *)method path:(NSString *)pattern
                       handler:(id<HSHandler>)handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy, nullable) NSString *method;
@property (nonatomic, readonly, copy) NSString *pattern;
@property (nonatomic, readonly, strong) id<HSHandler> handler;
// Who may call it, as the authentication stage found them: someone at all
// (requiresPrincipal; 401 for no one), with one of these OAuth scopes (403
// without, the challenge naming them). Default: anyone.
@property (nonatomic) BOOL requiresPrincipal;
@property (nonatomic, copy, nullable) NSSet<NSString *> *scopes;
// How errors of the requests it takes are answered (HSErrorFormatting):
// by default its handler, when it formats errors (a mounted OData service
// answers in OData's format); else problem+json.
@property (nonatomic, strong, nullable) id<HSErrorFormatting> errorFormatter;
// The parameters of a path it takes (empty for none), or nil.
- (nullable NSDictionary<NSString *, NSString *> *)parametersOfPath:(NSString *)path;
// Whether it answers the method (nil, the same, or GET for HEAD).
- (BOOL)takesMethod:(NSString *)method;
@end

@interface HSRouter : NSObject <HSHandler>
@property (copy) NSArray<HSRoute *> *routes;
// The route a request would take, and the parameters its path gives; nil
// for none. (Whether the method is one it takes is not asked.)
- (nullable HSRoute *)routeForRequest:(HSRequest *)request parameters:(NSDictionary<NSString *, NSString *> * _Nullable * _Nullable)parameters;
- (void)addRoute:(HSRoute *)route;
- (void)insertRoute:(HSRoute *)route atIndex:(NSUInteger)index;
- (void)removeRoute:(HSRoute *)route;
// The first route with this pattern (and method, when given), or nil.
- (nullable HSRoute *)routeWithPath:(NSString *)pattern method:(nullable NSString *)method;
@end

// The route found first, before the other stages: so that an error they
// answer with (a sign-in refused) is in the format of the API the request
// is for, and they can see where it goes. The router takes the route found
// here, without looking again.
@interface HSRoutingStage : HSStage
- (instancetype)initWithRouter:(HSRouter *)router NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) HSRouter *router;
@end

NS_ASSUME_NONNULL_END
