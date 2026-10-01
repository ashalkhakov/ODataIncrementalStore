// ODataHTTPServer — a handler on the network.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The one part of ODataServer that touches sockets. It listens with the
// vendored GCDWebServer (ThirdParty/GCDWebServer), turns each request into
// an ODataServerRequest for its handler -- a pipeline, a router, a mounted
// service -- and writes the response back. HTTP/1.1, with persistent
// connections (keepAliveTimeout), no TLS: it is meant to sit behind a
// reverse proxy (nginx, Caddy), which passes the request path on unchanged.
//
// Most applications do not make one themselves: ODataServerApplication
// does, with a pipeline and router around their service.
//
// A separate library from ODataService, so that neither the client
// nor the service's core links the listener.

#pragma once
#import <Foundation/Foundation.h>
#import "ODataServerPipeline.h"

@class ODataService;

NS_ASSUME_NONNULL_BEGIN

// What a bundle's principal class implements for ois-serve to hand it the
// service before the first request: register entity set handlers, set
// paging, and so on. (A bundle whose principal class is an
// ODataServerApplication subclass can add routes and stages too.)
@protocol ODataServiceConfiguring <NSObject>
+ (void)configureService:(ODataService *)service;
@end

@interface ODataHTTPServer : NSObject

- (instancetype)initWithHandler:(id<ODataServerHandler>)handler NS_DESIGNATED_INITIALIZER;
// A service alone, at its service root's path: a router with that one
// route, and nothing in front of it (the service asks its authenticator
// itself).
- (instancetype)initWithService:(ODataService *)service;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, strong) id<ODataServerHandler> handler;
// The service it was made with, if it was.
@property (nonatomic, readonly, strong, nullable) ODataService *service;
// Listen on 127.0.0.1 and ::1 only (the default: the proxy is on the same
// machine), or on every address.
@property (nonatomic) BOOL bindToLocalhost;
// The largest request body taken, in bytes; a larger one is answered 413.
// Default: 64 MiB.
@property (nonatomic) NSUInteger maxBodySize;
// A larger request body, or a chunked one (whose size is not said), is
// written to a temporary file as it comes, not kept in memory
// (ODataServerRequest's bodyFileURL). Default: 1 MiB.
@property (nonatomic) NSUInteger maxBodyInMemory;
// How long a connection is kept open for the next request after a
// response (HTTP/1.1 persistent connections; a proxy's upstream keepalive),
// and how many requests it answers before it is closed. 0 closes each
// after one response. Default: 5 seconds, 100 requests.
@property (nonatomic) NSTimeInterval keepAliveTimeout;
@property (nonatomic) NSUInteger maxRequestsPerConnection;

// Starts listening; port 0 asks the system for a free one. Handlers run on
// dispatch queues, so the caller need not run a run loop.
- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;
// The same, and waits until the process gets SIGINT or SIGTERM, then stops.
- (BOOL)runOnPort:(NSUInteger)port error:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger port;
// Requests received and not yet answered: what a graceful stop waits for.
@property (atomic, readonly) NSUInteger requestsInFlight;

@end

NS_ASSUME_NONNULL_END
