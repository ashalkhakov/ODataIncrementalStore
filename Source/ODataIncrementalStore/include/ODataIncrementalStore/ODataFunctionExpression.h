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

NS_ASSUME_NONNULL_END
