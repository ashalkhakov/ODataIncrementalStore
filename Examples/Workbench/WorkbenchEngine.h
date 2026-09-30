// The workbench's transports: the built-in service, and the network, each
// with a log.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Both implement <ODataTransport> and report every exchange as a
// WorkbenchLogEntry. WorkbenchEngine never opens a socket: it is the
// library's own server, an ODataService over the built-in model (below)
// in a SQLite store of its own that keeps persistent history, seeded with a
// few of Northwind's rows, with a few operations of its own.

#pragma once
#import <ODataIncrementalStore/ODataIncrementalStore.h>
#import <ODataService/ODataService.h>

NS_ASSUME_NONNULL_BEGIN

// The built-in service's model, the client's as well: the Catalog, and
// what it does not show. Products have a version (ETags, and so
// conflicts); Budgets have application time (a category's budget over
// time: $at, $from and $to, Temporal.Update and the rest); Pictures are
// media entities (Download, Upload). Keys are kept in a deletion's
// tombstone, so its sets' changes can be followed by delta links.
FOUNDATION_EXPORT NSManagedObjectModel * _Nullable WorkbenchBuiltInModel(NSURL *catalogURL);
// The configuration of it the built-in service serves (and the client's
// store holds): every entity but AuditEntry, the application's own record
// of what its actions did.
FOUNDATION_EXPORT NSString * const WorkbenchServedConfiguration;

// One exchange, as it went over the wire: nothing shortened.
@interface WorkbenchLogEntry : NSObject
@property (copy) NSString *method;
@property (copy) NSString *URL;
@property (nonatomic) NSInteger status;                              // 0: no answer
@property (copy, nullable) NSDictionary<NSString *, NSString *> *requestHeaders;
@property (copy, nullable) NSData *requestData;
@property (copy, nullable) NSDictionary<NSString *, NSString *> *responseHeaders;
@property (copy, nullable) NSData *responseData;
@property (copy, nullable) NSString *failure;                        // why there was no answer
@property (strong) NSDate *date;
@property (nonatomic) NSTimeInterval duration;
@property (copy) NSString *storeHint;                                // what the store was doing, where known
@end

@interface WorkbenchEngine : NSObject <ODataTransport>
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
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
// version moves on). What changed, in words.
- (NSString *)changeAtTheService;
@end

// A real service: every exchange goes to ODataDefaultTransport(), and is
// reported once it is done, on the main thread.
@interface WorkbenchNetworkTransport : NSObject <ODataTransport>
@property (nonatomic, copy, nullable) void (^didHandle)(WorkbenchLogEntry *entry);
@property (atomic, readonly) NSUInteger started;
@end

NS_ASSUME_NONNULL_END
