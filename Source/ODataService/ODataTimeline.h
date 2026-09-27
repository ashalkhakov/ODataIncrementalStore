// ODataService — application time (OData-Temporal): entity sets whose
// rows are time slices.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// An entity whose userInfo names a period (OData.periodStart and
// OData.periodEnd, ODataPropertyMapper.h) is served as a timeline entity
// set (Temporal.TimelineVisible): each row a time slice, valid from its
// start to its end, of the object its object key names. Periods are
// closed-open, or closed-closed for dates with OData.closedClosedPeriods;
// no end, or 9999-12-31, is no end at all.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataPropertyMapper.h>

NS_ASSUME_NONNULL_BEGIN

// A time slice an action made, changed or took away: the object, or, for a
// period deleted, what the slice held then (Core Data values, the period
// included).
@interface OISTimeslice : NSObject
@property (nonatomic, strong, nullable) NSManagedObject *object;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *values;
@end

// How an action writes: every slice it makes, changes (values by Core
// Data name, NSNull for none) and takes away. NO, or nil, with the error,
// when it cannot.
@protocol OISTimelineWriting <NSObject>
- (nullable NSManagedObject *)timelineInsertValues:(NSDictionary<NSString *, id> *)values entity:(NSEntityDescription *)entity error:(NSError **)error;
- (BOOL)timelineUpdate:(NSManagedObject *)slice values:(NSDictionary<NSString *, id> *)values error:(NSError **)error;
- (BOOL)timelineDelete:(NSManagedObject *)slice error:(NSError **)error;
@end

@interface OISTimeline : NSObject

// nil for an entity whose userInfo names no period (or names attributes
// it does not have, or that are not dates).
+ (nullable instancetype)timelineOfEntity:(NSEntityDescription *)entity mapper:(ODataPropertyMapper *)mapper;

@property (nonatomic, readonly) NSAttributeDescription *startAttribute;
@property (nonatomic, readonly) NSAttributeDescription *endAttribute;
@property (nonatomic, readonly) NSArray<NSAttributeDescription *> *objectKey;
@property (nonatomic, readonly) BOOL isDate;        // Edm.Date, else Edm.DateTimeOffset
@property (nonatomic, readonly) BOOL closedClosed;

// Temporal.ApplicationTimeSupport, as JSON CSDL has it.
- (NSDictionary *)applicationTimeSupport;

// $at, or $from with $to or $toInclusive, as a $filter over the period
// (OData-Temporal section 4.2.3): literals as the request wrote them.
- (NSString *)filterFrom:(NSString *)from to:(nullable NSString *)to inclusive:(BOOL)inclusive;

// Temporal.Update, Upsert or Delete (the vocabulary's names, unqualified)
// of these delta time slices (Core Data values, each with its period),
// over the slices given; what was made or changed, or, for Delete, what
// was taken away. nil, and why (an ODataServiceError), when it cannot.
- (nullable NSArray<OISTimeslice *> *)perform:(NSString *)action
                                        deltas:(NSArray<NSDictionary<NSString *, id> *> *)deltas
                                    candidates:(NSArray<NSManagedObject *> *)candidates
                                        writer:(id<OISTimelineWriting>)writer
                                         error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
