// ODataIncrementalStore — a service's functions inside $filter and $orderby.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A function bound to an entity type is a computed property of its
// entities, and the service can filter and sort by it (Part 2 section
// 5.1.1.12, a function call in a path):
//
//   // People?$filter=NS.GetFavoriteAirline()/Name eq 'American Airlines'
//   NSExpression *airline = [ODataFunctionExpression expressionForFunction:@"GetFavoriteAirline"
//                                                                onKeyPath:nil parameters:nil resultKeyPath:@"name"];
//   fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:airline
//                                                        rightExpression:[NSExpression expressionForConstantValue:@"American Airlines"]
//                                                               modifier:NSDirectPredicateModifier
//                                                                   type:NSEqualToPredicateOperatorType options:0];
//
//   // Animals?$orderby=Zoo.Age(On=2024-01-01) desc
//   fetch.sortDescriptors = @[ [ODataSortDescriptor sortDescriptorWithExpression:age ascending:NO] ];
//
// The function is found in $metadata as an operation call finds it (see
// ODataOperationCall.h), bound to the entity the key path leads to (the
// fetched one when there is none), or to a collection when it ends in a
// to-many relationship. Parameters are written as literals of their
// declared types. The result key path goes on into the result: an
// entity's attributes and relationships, a complex value's members.
//
// Evaluated in memory, as by -[NSArray filteredArrayUsingPredicate:], the
// expression calls the function on the object, over the network, and
// waits: evaluate it where the object's context may be used.

#pragma once
#import <ODataKit/OISCoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataFunctionExpression : NSExpression <NSSecureCoding>

+ (instancetype)expressionForFunction:(NSString *)name
                            onKeyPath:(nullable NSString *)keyPath
                           parameters:(nullable NSDictionary<NSString *, id> *)parameters
                        resultKeyPath:(nullable NSString *)resultKeyPath;

@property (nonatomic, readonly, copy) NSString *functionName;
@property (nonatomic, readonly, copy, nullable) NSString *bindingKeyPath;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *parameters;
@property (nonatomic, readonly, copy, nullable) NSString *resultKeyPath;

@end

// A sort by any expression the store can write in $orderby: a function's
// result, a key path, lowercase:(...). In memory it compares the values
// the expression gives for the two objects.
@interface ODataSortDescriptor : NSSortDescriptor

+ (instancetype)sortDescriptorWithExpression:(NSExpression *)expression ascending:(BOOL)ascending;

@property (nonatomic, readonly, strong) NSExpression *expression;

@end

// An aggregate of the collection the predicate filters, its "current
// collection" (Data Aggregation section 3.6): $these/aggregate(Amount with
// sum), or $these/$count. A value like any other in a comparison or in
// arithmetic, at a service that has Data Aggregation:
//
//   // Sales?$filter=Amount mul 3 ge $these/aggregate(Amount with sum)
//   NSExpression *total = [ODataTheseExpression expressionForAggregate:@"sum" keyPath:@"amount"];
//   fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionWithFormat:@"amount * 3"]
//                                                        rightExpression:total modifier:NSDirectPredicateModifier
//                                                                   type:NSGreaterThanOrEqualToPredicateOperatorType options:0];
//
// The collection is the entity's set, as the caller may see it, before the
// rest of the $filter. The aggregate is sum, average, min, max or
// countdistinct, of a key path through to-one relationships to an
// attribute. Evaluated in memory, it reads the entity's objects in the
// evaluated object's context and aggregates them.
@interface ODataTheseExpression : NSExpression <NSSecureCoding>

+ (instancetype)expressionForAggregate:(NSString *)method keyPath:(NSString *)keyPath;
+ (instancetype)expressionForCount;

// nil for $count.
@property (nonatomic, readonly, copy, nullable) NSString *method;
@property (nonatomic, readonly, copy, nullable) NSString *aggregatedKeyPath;

@end

NS_ASSUME_NONNULL_END
