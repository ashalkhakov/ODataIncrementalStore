// ODataKit — $apply: grouping and aggregating (OData Data Aggregation 4.0).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// $apply is a sequence of transformations, each on the result of the one
// before (Data Aggregation section 3):
//
//   filter(UnitPrice gt 10)/groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total,$count as Products))
//
// These are read and written: filter, groupby (of property paths, with an
// aggregate), and aggregate, of property paths with sum, min, max,
// average or countdistinct, and of $count. The others (compute, topcount,
// concat, expand, search, rollup, custom methods) are
// ODataIncrementalStoreErrorUnsupportedExpression; what is not $apply at
// all is ODataIncrementalStoreErrorSyntax.

#pragma once
#import "OISRuntime.h"
#import "ODataExpression.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ODataApplyKind) {
  ODataApplyFilter,     // filter
  ODataApplyGroupBy,    // groupPaths, aggregates (may be empty)
  ODataApplyAggregate   // aggregates
};

// Path with method as alias, or $count as alias (path nil).
@interface ODataAggregate : NSObject
+ (instancetype)aggregateOfPath:(nullable NSArray<NSString *> *)path method:(nullable NSString *)method alias:(NSString *)alias;
@property (nonatomic, readonly, copy, nullable) NSArray<NSString *> *path;
@property (nonatomic, readonly, copy, nullable) NSString *method;
@property (nonatomic, readonly, copy) NSString *alias;
@end

@interface ODataApplyTransformation : NSObject
+ (nullable NSArray<ODataApplyTransformation *> *)transformationsWithString:(NSString *)text error:(NSError **)error;
// The transformations as $apply writes them.
+ (NSString *)stringForTransformations:(NSArray<ODataApplyTransformation *> *)transformations;

+ (instancetype)filterWithExpression:(ODataExpression *)expression;
+ (instancetype)groupByPaths:(NSArray<NSArray<NSString *> *> *)paths aggregates:(NSArray<ODataAggregate *> *)aggregates;
+ (instancetype)aggregateWith:(NSArray<ODataAggregate *> *)aggregates;

@property (nonatomic, readonly) ODataApplyKind kind;
@property (nonatomic, readonly, strong, nullable) ODataExpression *filter;
@property (nonatomic, readonly, copy) NSArray<NSArray<NSString *> *> *groupPaths;
@property (nonatomic, readonly, copy) NSArray<ODataAggregate *> *aggregates;
@end

@interface ODataAggregation : NSObject
// The methods it computes: sum, min, max, average, countdistinct.
+ (NSSet<NSString *> *)methods;
// Objects (anything answering key paths) grouped by the values at
// keyPaths, first seen first, and aggregated: one dictionary per group,
// each key path to its value (NSNull for none), each aggregate's alias to
// its value. An aggregate's path is a key path's components. sum, min,
// max and average leave out nulls and are NSNull over none; sum and
// average of integers and decimals are NSDecimalNumbers; $count and
// countdistinct are NSNumbers. No key paths: one dictionary, even for no
// objects.
+ (NSArray<NSDictionary *> *)groupObjects:(NSArray *)objects
                               byKeyPaths:(NSArray<NSString *> *)keyPaths
                               aggregates:(NSArray<ODataAggregate *> *)aggregates;
// An expression over the members of rows (dictionaries, nested for a
// path: Category/CategoryName is Category.CategoryName) as a predicate:
// comparisons with literals, and, or, not. nil with
// ODataIncrementalStoreErrorUnsupportedExpression for anything more.
+ (nullable NSPredicate *)predicateForExpression:(ODataExpression *)expression error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
