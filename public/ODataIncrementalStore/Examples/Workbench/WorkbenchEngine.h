// In-memory OData v4 service used as the workbench transport.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Implements <ODataTransport>. The store never opens a socket.

#pragma once
#import "ODataClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface WorkbenchLogEntry : NSObject
@property (copy) NSString *method;
@property (copy) NSString *URL;
@property (nonatomic) NSInteger status;
@property (copy, nullable) NSString *requestBody;
@property (copy, nullable) NSString *responseBody;
@property (copy) NSString *storeHint;
@end

@interface WorkbenchEngine : NSObject <ODataTransport>
@property (copy) NSURL *serviceRoot;
@property (nonatomic, readonly) NSArray<WorkbenchLogEntry *> *log;
@property (nonatomic, copy, nullable) void (^didHandle)(WorkbenchLogEntry *entry);
- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
