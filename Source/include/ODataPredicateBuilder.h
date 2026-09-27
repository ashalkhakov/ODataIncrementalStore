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
// The entity each qualified type name stands for, for casts and isof.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSEntityDescription *> *entitiesByTypeName;
// Properties (Core Data names) of an entity that $filter (sorting: NO) or
// $orderby (YES) may not use; a use is a 400.
@property (nonatomic, copy, nullable) NSSet<NSString *> * _Nullable (^restrictedProperties)(NSEntityDescription *entity, BOOL sorting);

// A boolean expression over the entity's properties: eq ne gt ge lt le in,
// and or not, add sub mul div (and mod, on Apple), contains startswith
// endswith, tolower toupper length now, any and all over to-many
// relationships, $count of a to-many relationship, parameter aliases; type
// casts (NS.Manager/Budget, Boss/NS.Manager, Staff/NS.Manager/$count,
// cast(Boss,NS.Manager)) and isof(NS.Manager), isof(Boss,NS.Manager);
// year, date, floor, ceiling and round compared with a literal, as a range
// of their argument (year(d) eq 2025 is 2025-01-01 <= d < 2026-01-01);
// has, of an enumeration kept as a number, as IN the values with the bits.
//
// A cast asks an object's type with "entity IN {the type, its
// subentities}", which Apple's stores and FreeCoreData's answer, of the
// fetched object and of one it reaches. What reads a cast object is behind
// that test, in an AND, so a store that evaluates the predicate itself
// never asks an Employee for a Manager's property; where the object is not
// of the type, the cast is null (Default.Manager/Budget eq null holds for
// every Employee that is not a Manager).
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
