// ODataIncrementalStore — OData expressions as Core Data predicates.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The service's half of ODataPredicateTranslator, and anyone's who holds a
// parsed $filter or $orderby (ODataExpression.h): it becomes an NSPredicate
// or sort descriptors over an entity's key paths. Everything is built from
// NSComparisonPredicate, NSCompoundPredicate and NSExpression objects, and
// request text is never formatted into a predicate string: the one format
// string is the key path off a lambda's variable, made of a generated
// variable name and the model's own property names.
//
// Literals are typed by what they are compared with: 2018-02-11 against a
// Date attribute is an NSDate, 'x' against a UUID attribute an NSUUID, by
// the mapper's value coder. A name that is not a property of the entity is
// a 400; an expression that has no predicate form is a 501. Both come back
// as ODataServiceErrorDomain errors (ODataError.h).

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataExpression.h>
#import <ODataKit/ODataPropertyMapper.h>

NS_ASSUME_NONNULL_BEGIN

// A property an entity does not have (a dynamic property of an open type),
// compared with a value: its path of names from the entity (Priority, or
// Variables/amount), the operator (equal, not equal, greater, greater or
// equal, less, less or equal) as the comparison reads with the property
// on the left, and the value (a number, string, boolean, NSDate, ...; nil
// for null). The predicate over the entity it stands for; nil with an
// error to refuse the comparison, nil without one for a property that is
// not there (400). userInfo is the builder's (a service's: the request).
typedef NSPredicate * _Nullable (^ODataDynamicPropertyPredicate)(NSEntityDescription *entity, NSArray<NSString *> *path,
                                                                 NSPredicateOperatorType type, id _Nullable value,
                                                                 id _Nullable userInfo, NSError **error);

@interface ODataPredicateBuilder : NSObject

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataPropertyMapper *mapper;
// The entity each qualified type name stands for, for casts and isof.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSEntityDescription *> *entitiesByTypeName;
// Properties (Core Data names) of an entity that $filter (sorting: NO) or
// $orderby (YES) may not use; a use is a 400.
@property (nonatomic, copy, nullable) NSSet<NSString *> * _Nullable (^restrictedProperties)(NSEntityDescription *entity, BOOL sorting);
// What $filter's comparisons of a name the entity does not have -- on
// its own, or members after it -- with a value stand for: eq ne gt ge lt
// le, in (each value as eq), and the name alone as a condition (eq true).
// Only of $it, not inside any or all (501), and a dynamic property is
// compared with a value, not another property; anything else it is used
// in is a 400, as an unknown name's. nil, the default: every such name is
// unknown.
@property (nonatomic, copy, nullable) ODataDynamicPropertyPredicate dynamicProperty;
// What the blocks are handed: whatever one use of the builder is for (a
// service's, the request it answers). nil, the default.
@property (nonatomic, strong, nullable, readonly) id userInfo;
// A builder like this one, the same in all but its userInfo: cheap, for
// the length of one request.
- (instancetype)builderWithUserInfo:(nullable id)userInfo;

// A boolean expression over the entity's properties: eq ne gt ge lt le in,
// and or not, add sub mul div (and mod, on Apple), contains startswith
// endswith, tolower toupper length now, any and all over to-many
// relationships, $count of a to-many relationship, parameter aliases; type
// casts (NS.Manager/Budget, Boss/NS.Manager, Staff/NS.Manager/$count,
// cast(Boss,NS.Manager)) and isof(NS.Manager), isof(Boss,NS.Manager);
// year, date, floor, ceiling and round compared with a literal, as a range
// of their argument (year(d) eq 2025 is 2025-01-01 <= d < 2026-01-01);
// with a context, month, day, hour, minute and second as well, as a range
// in each year (month(d) eq 3), month, day, hour or minute the dates the
// context reads span;
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
// The context to read the span of a date from, for month() and the rest;
// called on its queue.
- (nullable NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                          entity:(NSEntityDescription *)entity
                                         aliases:(nullable NSDictionary<NSString *, ODataExpression *> *)aliases
                                         context:(nullable NSManagedObjectContext *)context
                                           error:(NSError **)error;

// $orderby: each item a property path through to-one relationships, or a
// to-many relationship's $count.
- (nullable NSArray<NSSortDescriptor *> *)sortDescriptorsForOrderBy:(NSArray<ODataOrderItem *> *)items
                                                             entity:(NSEntityDescription *)entity
                                                              error:(NSError **)error;

// $compute (Part 2 section 5.1.3): its names stand for their expressions,
// and a join's alias ($apply's join, as an NSEntityDescription) for the
// joined member, an entity of that type,
// by alias, in the filter and the ordering. A value's expression, to be
// evaluated with each object (in memory); and an ordering, as key paths
// where each item is one, else (*inMemory YES) as descriptors that compare
// the objects' values, which a store cannot sort by.
- (nullable NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                          entity:(NSEntityDescription *)entity
                                         aliases:(nullable NSDictionary<NSString *, ODataExpression *> *)aliases
                                        computed:(nullable NSDictionary<NSString *, ODataExpression *> *)computed
                                         context:(nullable NSManagedObjectContext *)context
                                           error:(NSError **)error;
// The same, month() and the rest ranging over the spans given (by
// +spanKeyOfAttribute:, each @[earliest, latest], NSNull where there is
// none), not over a context: what a service reads through its handlers.
// One not given is 500.
- (nullable NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                          entity:(NSEntityDescription *)entity
                                         aliases:(nullable NSDictionary<NSString *, ODataExpression *> *)aliases
                                        computed:(nullable NSDictionary<NSString *, ODataExpression *> *)computed
                                           spans:(nullable NSDictionary<NSString *, NSArray *> *)spans
                                           error:(NSError **)error;
// The date attributes whose spans an expression's month() and the rest
// need; what cannot be read is left out.
- (NSArray<NSAttributeDescription *> *)spanAttributesOfExpression:(ODataExpression *)expression entity:(NSEntityDescription *)entity
                                                            aliases:(nullable NSDictionary<NSString *, ODataExpression *> *)aliases
                                                           computed:(nullable NSDictionary<NSString *, ODataExpression *> *)computed;
+ (NSString *)spanKeyOfAttribute:(NSAttributeDescription *)attribute;
- (nullable NSExpression *)valueExpressionForExpression:(ODataExpression *)expression
                                                 entity:(NSEntityDescription *)entity
                                                aliases:(nullable NSDictionary<NSString *, ODataExpression *> *)aliases
                                               computed:(nullable NSDictionary<NSString *, ODataExpression *> *)computed
                                                  error:(NSError **)error;
- (nullable NSArray<NSSortDescriptor *> *)sortDescriptorsForOrderBy:(NSArray<ODataOrderItem *> *)items
                                                             entity:(NSEntityDescription *)entity
                                                           computed:(nullable NSDictionary<NSString *, ODataExpression *> *)computed
                                                           inMemory:(BOOL *)inMemory
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
