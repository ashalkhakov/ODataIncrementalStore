// The workbench's transports: an in-memory OData v4 service, and the
// network with a log.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Both implement <ODataTransport> and report every exchange as a
// WorkbenchLogEntry. WorkbenchEngine never opens a socket.

#pragma once
#if __has_include(<ODataIncrementalStore/ODataIncrementalStore.h>)
#import <ODataIncrementalStore/ODataIncrementalStore.h>
#else
#import "ODataIncrementalStore.h"
#endif

NS_ASSUME_NONNULL_BEGIN

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
@property (copy) NSURL *serviceRoot;
@property (nonatomic, readonly) NSArray<WorkbenchLogEntry *> *log;
@property (nonatomic, copy, nullable) void (^didHandle)(WorkbenchLogEntry *entry);
- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)reset;
@end

// A real service: every exchange goes to ODataDefaultTransport(), and is
// reported once it is done, on the main thread.
@interface WorkbenchNetworkTransport : NSObject <ODataTransport>
@property (nonatomic, copy, nullable) void (^didHandle)(WorkbenchLogEntry *entry);
@end

NS_ASSUME_NONNULL_END
