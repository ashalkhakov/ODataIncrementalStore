// ODataServerHandlers — the handlers and stages ODataServer comes with.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "ODataServerPipeline.h"

@class ODataService;
@protocol ODataAuthenticator;

NS_ASSUME_NONNULL_BEGIN

// An ODataService, mounted: each request becomes an ODataExchange on the
// service's public URL (its serviceRoot's scheme, host and port, then the
// request target as it came), with who is asking when the authentication
// stage found out, so the service does not ask again. Mount it at the
// service root's path: /odata/*.
@interface ODataServiceHandler : NSObject <ODataServerHandler>
- (instancetype)initWithService:(ODataService *)service NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataService *service;
@end

// Whether the server is up, for a load balancer or an orchestrator: 200
// with -status as JSON. Subclass to say more (or 503, from -statusCode).
@interface ODataHealthHandler : NSObject <ODataServerHandler>
- (NSDictionary *)status;   // default: {"status": "ok"}
- (NSInteger)statusCode;    // default: 200
@end

// Who is asking, once for every route: the authenticator's answer is the
// request's principal (nil for no one: whether that is let in is each
// route's to say, and a mounted service's). A refusal (a token that is not
// valid) is answered here, with the authenticator's challenge.
@interface ODataAuthenticationStage : ODataServerStage
- (instancetype)initWithAuthenticator:(id<ODataAuthenticator>)authenticator NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, strong) id<ODataAuthenticator> authenticator;
// How long a deferred authenticator may take: then 504. Default: 60 s.
@property (nonatomic) NSTimeInterval timeout;
@end

// The request's id: the client's (or the proxy's) X-Request-ID when it
// sends a usable one, else a new one; in userInfo[ODataServerRequestIDKey],
// and sent back in the response's header.
FOUNDATION_EXPORT NSString * const ODataServerRequestIDKey;
@interface ODataRequestIDStage : ODataServerStage
@property (nonatomic, copy) NSString *headerName;  // default: X-Request-ID
@end

// Browsers on other origins (CORS, Fetch section 3.2): which may call, and
// with what. A preflight (OPTIONS with Origin and
// Access-Control-Request-Method) is answered here, before authentication;
// any other response to an allowed origin carries the headers that let the
// browser hand it over. A request without Origin passes untouched; one from
// an origin not allowed passes without them (its preflight is 403).
@interface ODataCORSStage : ODataServerStage
// Origins as browsers send them (https://app.example.com); "*" for any.
- (instancetype)initWithAllowedOrigins:(NSArray<NSString *> *)origins NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, copy) NSArray<NSString *> *allowedOrigins;
// Default: GET, HEAD, POST, PUT, PATCH, DELETE.
@property (nonatomic, copy) NSArray<NSString *> *allowedMethods;
// Request headers a preflight may ask for. Default: the ones OData and
// sign-in use (Authorization, Content-Type, Accept, OData-Version,
// OData-MaxVersion, If-Match, If-None-Match, Prefer, Isolation,
// X-Request-ID).
@property (nonatomic, copy) NSArray<NSString *> *allowedHeaders;
// Response headers the browser shows the page. Default: OData's (OData-
// Version, ETag, Location, OData-EntityId, Preference-Applied, Retry-After),
// WWW-Authenticate, X-Request-ID.
@property (nonatomic, copy) NSArray<NSString *> *exposedHeaders;
// Cookies or Authorization sent by the browser itself: the origin is named,
// never "*". Default: NO.
@property (nonatomic) BOOL allowsCredentials;
// How long a browser may keep a preflight's answer, in seconds. Default: 600.
@property (nonatomic) NSUInteger maxAge;
@end

// gzip, for a client that takes it (Accept-Encoding), of a body worth it: at
// least minimumSize bytes, of a type that compresses (JSON, XML, text), not
// already encoded, and only when it comes out smaller. A streamed or file
// body is left as it is.
@interface ODataCompressionStage : ODataServerStage
@property (nonatomic) NSUInteger minimumSize;  // default: 1024
// Content types (before any ;parameters) that compress: exact, or ending in
// "/" for a whole family. Default: application/json, application/xml,
// application/xhtml+xml, text/.
@property (nonatomic, copy) NSArray<NSString *> *compressibleTypes;
@end

// One line per request, once answered: who, what, the status, the size and
// how long it took, and its request id. To standard error; override
// -writeLine: to send it elsewhere (it must not wait).
@interface ODataAccessLogStage : ODataServerStage
- (void)writeLine:(NSString *)line;
@end

NS_ASSUME_NONNULL_END
