// ODataServerMessage — a request, its response, and the reply that carries one
// to the other.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What every stage and handler of ODataServer works with, whatever listens
// on the socket: the listener makes the request, the handler at the end of
// the pipeline finishes the reply with a response, and the listener writes
// it.

#pragma once
#import <Foundation/Foundation.h>

@class ODataPrincipal;

NS_ASSUME_NONNULL_BEGIN

@interface ODataServerRequest : NSObject
// URL: the request target as the client sent it (path and query, still
// escaped), on the host the listener answers.
- (instancetype)initWithMethod:(NSString *)method URL:(NSURL *)URL
                       headers:(NSDictionary<NSString *, NSString *> *)headers
                          body:(nullable NSData *)body NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, copy) NSString *method;  // upper case
@property (nonatomic, readonly, copy) NSURL *URL;
// The request target as the client sent it: the path and query, escaped.
@property (nonatomic, readonly, copy) NSString *target;
// The path, unescaped; the query's items, unescaped (the last of a repeated
// name).
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *query;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *headers;
// Header names are case-insensitive.
- (nullable NSString *)valueForHeader:(NSString *)name;
@property (nonatomic, readonly, copy, nullable) NSData *body;
// The body as JSON, or nil when it is none.
@property (nonatomic, readonly, nullable) id JSONBody;
// The client's address, as the listener saw it (the proxy's, behind one).
@property (nonatomic, copy, nullable) NSString *remoteAddress;

// Who is asking, once the authentication stage has asked (authenticated):
// nil for no one.
@property (nonatomic, strong, nullable) ODataPrincipal *principal;
@property (nonatomic, getter=isAuthenticated) BOOL authenticated;
// What the route matched: /orders/:id gives id; a trailing * gives "*".
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *pathParameters;
// The stages' and handlers' own, for the length of the request.
@property (nonatomic, readonly, strong) NSMutableDictionary *userInfo;

// The same request for Foundation's URL loading types (an authenticator,
// an ODataService): on the given origin when there is one (scheme, host,
// port), as the public URL a proxy forwards from.
- (NSURLRequest *)URLRequestOnOrigin:(nullable NSURL *)origin;
@end

@interface ODataServerResponse : NSObject
+ (instancetype)responseWithStatus:(NSInteger)status;
+ (instancetype)responseWithStatus:(NSInteger)status body:(nullable NSData *)body contentType:(nullable NSString *)contentType;
+ (instancetype)responseWithJSON:(id)json status:(NSInteger)status;
+ (instancetype)responseWithText:(NSString *)text status:(NSInteger)status;
// An error as OData answers one ({"error": {"code", "message"}}), its status
// the error's code for an ODataServiceError, 500 for any other (whose own
// message is logged, not shown). A 401 or 403 that names the scopes it
// needs (ODataErrorScopesKey) carries the challenge saying so.
+ (instancetype)responseWithError:(NSError *)error;

@property (nonatomic) NSInteger status;
@property (nonatomic, copy, nullable) NSData *body;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *headers;
// Header names are case-insensitive; nil removes one.
- (nullable NSString *)valueForHeader:(NSString *)name;
- (void)setValue:(nullable NSString *)value forHeader:(NSString *)name;
@end

// One request's answer: finished once, with a response, now or later, from
// any thread; a second answer is ignored. Whoever starts the request (the
// listener, a stage passing it on, a test) makes the reply, and is sent
// the action with it once it is finished.
@interface ODataServerReply : NSObject
- (instancetype)initWithTarget:(id)target action:(SEL)action NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)finishWithResponse:(ODataServerResponse *)response;
// The same with +[ODataServerResponse responseWithError:].
- (void)failWithError:(NSError *)error;
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
@property (nonatomic, readonly, strong, nullable) ODataServerResponse *response;
// Its starter's, to find its way back with.
@property (nonatomic, strong, nullable) id context;
@end

NS_ASSUME_NONNULL_END
