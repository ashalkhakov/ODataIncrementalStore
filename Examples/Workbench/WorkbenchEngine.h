// The workbench's transports: the built-in service, and the network, each
// with a log.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Both implement <ODataTransport> and report every exchange as a
// WorkbenchLogEntry. WorkbenchEngine never opens a socket: it is the
// library's own server, an ODataService over the built-in model (WorkbenchModel.h)
// in a SQLite store of its own that keeps persistent history, seeded with a
// few of Northwind's rows, with a few operations of its own.

#pragma once
#import "WorkbenchModel.h"
#import <ODataService/ODataService.h>
#import <ODataSync/ODataSyncService.h>

NS_ASSUME_NONNULL_BEGIN

// A stamp of the service's own changes, as ODataSync's hybrid logical clock
// writes them: past the wall clock and past the stamp it replaces.
FOUNDATION_EXPORT NSString *WorkbenchServiceStamp(NSString *_Nullable previous);

@interface WorkbenchEngine : NSObject <ODataTransport>
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
// The compiled Catalog model the built-in model is made from.
@property (nonatomic, readonly, copy) NSURL *modelURL;
@property (nonatomic, readonly) NSArray<WorkbenchLogEntry *> *log;
@property (nonatomic, copy, nullable) void (^didHandle)(WorkbenchLogEntry *entry);
// Exchanges started so far, counted as they start (the log hears of them
// once they are done).
@property (atomic, readonly) NSUInteger started;
// The service behind it, for a look at what it serves.
@property (nonatomic, readonly) ODataService *service;
// Nil when the model does not load.
- (nullable instancetype)initWithServiceRoot:(NSURL *)serviceRoot modelURL:(NSURL *)modelURL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// The seed rows again, and an empty log.
- (void)reset;
// As another client would: a product's price raised at the service (its
// version moves on, and its lastChanged stamp). What changed, in words.
- (NSString *)changeAtTheService;
// The same, of that product (nil: the first).
- (NSString *)changeProductAtTheService:(nullable NSNumber *)productID;
@end

// A real service: every exchange goes to ODataDefaultTransport(), and is
// reported once it is done, on the main thread.
@interface WorkbenchNetworkTransport : NSObject <ODataTransport>
@property (nonatomic, copy, nullable) void (^didHandle)(WorkbenchLogEntry *entry);
@property (atomic, readonly) NSUInteger started;
@end

NS_ASSUME_NONNULL_END
