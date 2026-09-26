// ODataIncrementalStore — OData expressions as Core Data predicates.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The server's half of ODataPredicateTranslator: a $filter or $orderby tree
// (ODataExpression.h) becomes an NSPredicate or sort descriptors over an
// entity's key paths. Everything is built from NSComparisonPredicate,
// NSCompoundPredicate and NSExpression objects, and request text is never
// formatted into a predicate string: the one format string is the key path
// off a lambda's variable, made of a generated variable name and the
// model's own property names.
//
// Literals are typed by what they are compared with: 2018-02-11 against a
// Date attribute is an NSDate, 'x' against a UUID attribute an NSUUID, by
// the mapper's value coder. A name that is not a property of the entity is
// a 400; an expression that has no predicate form is a 501. Both come back
// as ODataServiceErrorDomain errors (ODataError.h).

#pragma once
#import "OISCoreData.h"
#import "ODataExpression.h"
#import "ODataPropertyMapper.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataPredicateBuilder : NSObject

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataPropertyMapper *mapper;

// A boolean expression over the entity's properties: eq ne gt ge lt le in,
// and or not, add sub mul div (and mod, on Apple), contains startswith
// endswith, tolower toupper length now, any and all over to-many
// relationships, $count of a to-many relationship, parameter aliases.
- (nullable NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                          entity:(NSEntityDescription *)entity
                                         aliases:(nullable NSDictionary<NSString *, ODataExpression *> *)aliases
                                           error:(NSError **)error;

// $orderby: each item a property path through to-one relationships, or a
// to-many relationship's $count.
- (nullable NSArray<NSSortDescriptor *> *)sortDescriptorsForOrderBy:(NSArray<ODataOrderItem *> *)items
                                                             entity:(NSEntityDescription *)entity
                                                              error:(NSError **)error;

// A path of wire names (Category/CategoryName) as a Core Data key path
// (category.name), through to-one relationships; the property it ends at
// through `property`. nil, with a 400, for a name that is not there.
- (nullable NSString *)keyPathForPath:(NSArray<NSString *> *)path
                               entity:(NSEntityDescription *)entity
                             property:(NSPropertyDescription * _Nullable * _Nullable)property
                                error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
