// ODataServerApplication — a server, made from its settings, that an
// application adds to by overriding a few methods.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   @interface CatalogServer : ODataServerApplication
//   @end
//
//   @implementation CatalogServer
//   - (void)configureService:(ODataService *)service
//   {
//     [service setHandler:[[OrdersHandler alloc] initWithEntity:...] forEntitySet:@"Orders"];
//   }
//   - (void)configureRouter:(ODataServerRouter *)router
//   {
//     [router insertRoute:[ODataServerRoute routeWithMethod:@"POST" path:@"/webhooks/billing"
//                                                 handler:[[BillingWebhook alloc] init]] atIndex:0];
//   }
//   - (void)configurePipeline:(ODataServerPipeline *)pipeline
//   {
//     [pipeline insertStage:[[TenantStage alloc] init] afterStageOfClass:[ODataAuthenticationStage class]];
//   }
//   @end
//
//   int main(int argc, const char *argv[])
//   {
//     return ODataServerMain(argc, argv, [CatalogServer class]);
//   }
//
// The settings are ois-serve's (ODataServerConfiguration below), from a
// property list and the command line. What it makes, in order:
//
//   the service    the model, the store, the limits; its authenticator
//   the router     GET /health (HealthPath), then the service at its
//                  service root's path (/odata/*)
//   the pipeline   ODataRequestIDStage, ODataAccessLogStage (AccessLog),
//                  ODataCORSStage (CORSOrigins), ODataCompressionStage
//                  (Compression), ODataAuthenticationStage (with the
//                  authenticator, when the settings name one), then the
//                  router
//   the listener   on Port, loopback unless Localhost is NO
//
// and each is handed to its -configure method, to add to or change, before
// the next is made. Everything is a public class: an application that
// would rather build its own pipeline does, and hands it to an
// ODataHTTPServer.

#pragma once
#import <Foundation/Foundation.h>
#import "ODataHTTPServer.h"
#import "ODataServerRouter.h"
#import "ODataServerHandlers.h"

@class ODataService;
@protocol ODataAuthenticator;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const ODataServerErrorDomain;

// The settings a server is made from, and what they make.
//
//   Model         the compiled model (.momd, .mom; on GNUstep an
//                 .xcdatamodeld too)
//   StoreType     SQLite, InMemory (default), XML, Binary (Apple only), or a
//                 store type a linked or loaded backend registers
//   StoreURL      the store's URL; a plain path is a file
//   StoreOptions  a dictionary, handed to the coordinator as it is
//   ServiceRoot   the public URL of the service, which its links begin with
//                 (default http://127.0.0.1:<Port>/odata/)
//   Port          default 8080
//   Localhost     YES (the default): listen on loopback only, for a proxy
//                 on the same machine
//   MaxBodySize   bytes; default 64 MiB
//   MaxPageSize, MaxVersion, Namespace, Container, MaxURLLength,
//   MaxExpandDepth, MaxBatchRequests, MaxRowsInMemory, MaxJSONDepth,
//   MaxAsyncRequests, ReplyTimeout, AsyncResultDuration,
//   RepeatabilityDuration   the service's (ODataService.h)
//   TrustedUserHeader, TrustedClaimHeaders, ProxySecretHeader,
//   ProxySecretEnvironment   who is asking, from the headers of a proxy
//                 that signs users in (ODataTrustedHeaderAuthenticator)
//   JWTIssuer, JWTAudience, JWTKeysURL   or from a JWT access token
//   IntrospectionEndpoint, IntrospectionClientID,
//   IntrospectionSecretEnvironment   or any access token, asked about
//   RequiredScopes  scopes every token needs (JWT or introspection)
//   AllowAnonymous  YES: a request that names no one is answered too
//   HealthPath    default /health; empty for none
//   AccessLog     YES (the default): a line per request on standard error
//   CORSOrigins   origins browsers may call from (a list, or text with
//                 spaces or commas between; * for any): ODataCORSStage
//   CORSCredentials  YES: browsers may send cookies and Authorization
//   Compression   YES (the default): gzip for clients that take it
//   MaxBodyInMemory  bytes; a larger request body (or a chunked one) waits
//                 in a temporary file. Default 1 MiB
//   KeepAliveTimeout  seconds a connection waits for its next request
//                 (default 5; 0 closes each after one response)
//   MaxRequestsPerConnection  default 100
//   Bundles       bundles to load before the store is opened (the
//                 application's code; see ODataServerMain)
//   Libraries     shared libraries to load before the store is opened (a
//                 store backend's); lib<StoreType> is tried by itself
//   PrintMetadata YES: write $metadata to standard output and exit
//
// Each can come from the environment too (+environmentVariableForSetting:),
// as a container is configured: OIS_PORT=8080 OIS_LOCALHOST=NO.
@interface ODataServerConfiguration : NSObject
- (instancetype)initWithSettings:(NSDictionary<NSString *, id> *)settings NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The property list -Config names (or OIS_CONFIG), then the environment's
// OIS_ variables, then the rest of the command line's -Name value pairs:
// a later one wins.
+ (nullable instancetype)configurationFromCommandLine:(NSError **)error;
// The same from given arguments (-Name value pairs, without the dashes)
// and environment.
+ (nullable instancetype)configurationWithArguments:(NSDictionary<NSString *, id> *)arguments
                                        environment:(NSDictionary<NSString *, NSString *> *)environment
                                              error:(NSError **)error;
// A setting's environment variable: OIS_ and its name in capitals, words
// apart (Port: OIS_PORT, MaxPageSize: OIS_MAX_PAGE_SIZE, JWTIssuer:
// OIS_JWT_ISSUER). A value that starts with { or [ is read as JSON (a
// dictionary, a list); Bundles and Libraries take a list as paths
// separated by ':'.
+ (NSString *)environmentVariableForSetting:(NSString *)name;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *settings;

@property (nonatomic, readonly) NSUInteger port;
@property (nonatomic, readonly) BOOL bindToLocalhost;
@property (nonatomic, readonly) NSUInteger maxBodySize;
@property (nonatomic, readonly, copy) NSArray<NSString *> *bundlePaths;
// Shared libraries loaded before the store is opened: a store backend
// registers its type when loaded (Libraries). A StoreType no library
// registers is looked for as lib<StoreType> on the library path, so
// -StoreType CDPostgreSQLStore needs nothing more where FreeCoreData's
// backend is installed.
@property (nonatomic, readonly, copy) NSArray<NSString *> *libraryPaths;
@property (nonatomic, readonly, copy) NSString *healthPath;
@property (nonatomic, readonly) BOOL accessLog;
@property (nonatomic, readonly, copy) NSArray<NSString *> *corsOrigins;
@property (nonatomic, readonly) BOOL corsCredentials;
@property (nonatomic, readonly) BOOL compression;
@property (nonatomic, readonly) NSUInteger maxBodyInMemory;
@property (nonatomic, readonly) NSTimeInterval keepAliveTimeout;
@property (nonatomic, readonly) NSUInteger maxRequestsPerConnection;
@property (nonatomic, readonly) BOOL printsMetadata;

// Who is asking, as the settings say to find out; nil, without an error,
// when they name no way.
- (nullable id<ODataAuthenticator>)authenticatorWithError:(NSError **)error;
// The service, its store opened, with the authenticator (which may be nil).
- (nullable ODataService *)serviceWithAuthenticator:(nullable id<ODataAuthenticator>)authenticator error:(NSError **)error;
// What is allowed but probably not meant, one sentence each, once the
// authenticator is made.
@property (nonatomic, readonly, copy) NSArray<NSString *> *warnings;
@end

@interface ODataServerApplication : NSObject
- (instancetype)initWithConfiguration:(ODataServerConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataServerConfiguration *configuration;

// What -prepare: makes, in this order, each handed to its -configure
// method before the next is made.
@property (nonatomic, readonly, strong, nullable) id<ODataAuthenticator> authenticator;
@property (nonatomic, readonly, strong, nullable) ODataService *service;
@property (nonatomic, readonly, strong, nullable) ODataServerRouter *router;
@property (nonatomic, readonly, strong, nullable) ODataServerPipeline *pipeline;
@property (nonatomic, readonly, strong, nullable) ODataHTTPServer *server;

// What an application overrides. Each default does nothing.
- (void)configureService:(ODataService *)service;
- (void)configureRouter:(ODataServerRouter *)router;
- (void)configurePipeline:(ODataServerPipeline *)pipeline;
- (void)configureServer:(ODataHTTPServer *)server;

// Makes everything; NO, with the error, for settings it cannot use or an
// operation the service cannot declare. Once only.
- (BOOL)prepare:(NSError **)error;
// Prepares (unless it has), listens, and serves until SIGINT or SIGTERM:
// the process's exit status, 0 on a clean stop. Says what it is doing on
// standard error.
- (int)run;
@end

// What ois-serve is, and an application's main can be: the settings from
// the command line; the bundles they name loaded; the application made
// (of applicationClass, or of the one bundle whose principal class is an
// ODataServerApplication subclass, when applicationClass is
// ODataServerApplication itself), each bundle whose principal class is
// ODataServiceConfiguring handed the service after the application's
// -configureService:; then run. Exits 1 for settings it cannot use.
FOUNDATION_EXPORT int ODataServerMain(int argc, const char *_Nonnull argv[_Nonnull], Class applicationClass);

NS_ASSUME_NONNULL_END
