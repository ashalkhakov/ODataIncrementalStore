// The Workbench's model, the built-in service's and its devices': the
// Workbench (macOS, GNUstep) and the Device app (iOS) share it.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <ODataIncrementalStore/ODataIncrementalStore.h>

NS_ASSUME_NONNULL_BEGIN

// The built-in service's model, the client's as well: the Catalog, and
// what it does not show. Products have a version (ETags, and so
// conflicts); Budgets have application time (a category's budget over
// time: $at, $from and $to, Temporal.Update and the rest); Pictures are
// media entities (Download, Upload); EquipmentUnits are an open type,
// each kind with dynamic properties of its own. Keys are kept in a deletion's
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

NS_ASSUME_NONNULL_END
