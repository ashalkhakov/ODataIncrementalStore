// ODataIncrementalStore — application time in a fetch request.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A timeline entity set (OData-Temporal; Temporal.ApplicationTimeSupport
// in $metadata, which a model built from it keeps in the entity's userInfo
// as OData.periodStart and the rest) has a row per time slice. This
// predicate asks for the slices valid at a point, or overlapping an
// interval: $at, or $from with $to (closed-open) or $toInclusive
// (closed-closed), or $from alone. As the fetch's predicate, or ANDed at
// its top, it is sent as those query options beside the $filter the rest
// makes:
//
//   // Departments?$at=2012-03-01&$filter=ID eq 'D08'
//   fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
//     [ODataTemporalPredicate predicateAt:march], [NSPredicate predicateWithFormat:@"department == 'D08'"] ]];
//
// Anywhere else, or on an entity without a period, the fetch fails with
// ODataIncrementalStoreErrorUnsupportedPredicate. Evaluated in memory it
// compares the object's period, as the service would.

#pragma once
#import <ODataKit/OISCoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataTemporalPredicate : NSPredicate <NSSecureCoding>
+ (instancetype)predicateAt:(NSDate *)date;
// to nil: from on, with no end.
+ (instancetype)predicateFrom:(NSDate *)from to:(nullable NSDate *)to;
+ (instancetype)predicateFrom:(NSDate *)from toInclusive:(NSDate *)to;
@property (nonatomic, readonly, copy, nullable) NSDate *at;
@property (nonatomic, readonly, copy, nullable) NSDate *from;
@property (nonatomic, readonly, copy, nullable) NSDate *to;
@property (nonatomic, readonly) BOOL toInclusive;
@end

NS_ASSUME_NONNULL_END
