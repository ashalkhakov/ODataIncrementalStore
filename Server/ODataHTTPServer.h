// ODataHTTPServer — an ODataService on the network.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The HTTP adapter of docs/server-design.md: the one part of the server that
// touches sockets. It listens with the vendored GCDWebServer
// (ThirdParty/GCDWebServer), turns each request under the service root into
// an NSURLRequest, hands it to the service as an ODataExchange, and writes
// the response back. HTTP/1.1, one request a connection, no TLS: it is meant
// to sit behind a reverse proxy (nginx, Caddy), which passes the request
// path on unchanged. The URLs the service writes begin with its serviceRoot,
// so give the service the public one.
//
// A separate library from ODataIncrementalStore, so that neither the client
// nor the service's core links the listener.

#pragma once
#import <Foundation/Foundation.h>

@class ODataService;

NS_ASSUME_NONNULL_BEGIN

// What a bundle's principal class implements for ois-serve to hand it the
// service before the first request: register entity set handlers, set
// paging, and so on.
@protocol ODataServiceConfiguring <NSObject>
+ (void)configureService:(ODataService *)service;
@end

@interface ODataHTTPServer : NSObject

- (instancetype)initWithService:(ODataService *)service NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) ODataService *service;
// Listen on 127.0.0.1 and ::1 only (the default: the proxy is on the same
// machine), or on every address.
@property (nonatomic) BOOL bindToLocalhost;
// The largest request body taken, in bytes; a larger one is answered 413.
// Default: 64 MiB.
@property (nonatomic) NSUInteger maxBodySize;

// Starts listening; port 0 asks the system for a free one. Handlers run on
// dispatch queues, so the caller need not run a run loop.
- (BOOL)startOnPort:(NSUInteger)port error:(NSError **)error;
// The same, and waits until the process gets SIGINT or SIGTERM, then stops.
- (BOOL)runOnPort:(NSUInteger)port error:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger port;

@end

NS_ASSUME_NONNULL_END
