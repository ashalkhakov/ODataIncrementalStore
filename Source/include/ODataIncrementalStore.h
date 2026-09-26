// ODataIncrementalStore — NSIncrementalStore over OData v4.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Modern Objective-C (libobjc2 / ARC / blocks / properties / zeroing weak).
// Builds on GNUstep (clang + gnustep-base) and Apple Core Data.

#pragma once

#import "OISRuntime.h"
#import "OISCoreData.h"
#import "ODataError.h"
#import "ODataConfiguration.h"
#import "ODataClient.h"
#import "ODataPropertyMapper.h"
#import "ODataValue.h"
#import "ODataBatch.h"
#import "ODataResourceIdentifier.h"
#import "ODataPredicateTranslator.h"
#import "ODataQueryBuilder.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataIncrementalStore : NSIncrementalStore

+ (NSString *)storeType;
+ (void)registerStore;

// Every row a fetch or a relationship read brings back is kept, and serves
// the faults that fire afterwards; a later read of the same entities
// replaces it. Discard the kept rows of these objects (nil: all of them)
// to have their next fault read the service. -[NSManagedObjectContext
// refreshObject:mergeChanges:] alone turns an object back into a fault,
// which this store then fills from what it kept.
- (void)discardCachedRowsForObjectIDs:(nullable NSArray<NSManagedObjectID *> *)objectIDs;

@end

NS_ASSUME_NONNULL_END
