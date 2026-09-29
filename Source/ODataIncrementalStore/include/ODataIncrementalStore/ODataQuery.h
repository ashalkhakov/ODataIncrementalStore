// ODataIncrementalStore — a query sent as it is written.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A fetch request is translated: its predicate, sort, grouping and the
// rest become query options. What it cannot say, OData can: $apply's
// hierarchies (ancestors, descendants, traverse), $these, an expression
// $orderby, any function the service has. This is a read of an entity's
// set with query options as they are written, in OData's own syntax, which
// the store sends untranslated:
//
//   ODataQuery *query = [ODataQuery queryOfEntity:@"SalesOrganization" inContext:context];
//   query.options = @{ @"$apply": @"traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,preorder)",
//                      @"$expand": @"Superordinate" };
//   NSArray *organizations = [query execute:&error];
//
// What comes back is what a fetch gives, as far as the rows allow:
//
// - Objects (NSManagedObjectResultType, the default): each row an object
//   of the entity (or the sub-entity its @odata.type names), in the order
//   the service gave them, every page of them. They are the context's
//   objects, one per entity, their rows kept (and those of what $expand
//   brought), so their faults and prefetched relationships cost nothing.
//   A row without the entity's key is an error: rows grouped or
//   aggregated by $apply are not objects; ask for dictionaries.
// - Dictionaries (NSDictionaryResultType): each row as its JSON has it, by
//   wire name, nested for a path (Category/Name is {"Category": {"Name":
//   ...}}), without its annotations; numbers and strings as JSON reads
//   them.
//
// -execute: waits for the service: call it on the context's queue.
// -executeWithTarget:action: returns at once and sends the action, with
// the query, on the context's queue (the main thread for a context of
// neither queue type), its result or its error set.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataExpression.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataQuery : NSObject

+ (instancetype)queryOfEntity:(NSString *)entityName inContext:(NSManagedObjectContext *)context;
// What the store would ask the service for a fetch request, typed: a
// start for what the fetch cannot say (its options to change or add to,
// $apply steps to add). What the store would do here, beyond what it asks,
// is not part of it. A grouping or counting fetch is no query: nil.
+ (nullable instancetype)queryWithFetchRequest:(NSFetchRequest *)fetch inContext:(NSManagedObjectContext *)context error:(NSError **)error;
@property (nonatomic, readonly, copy) NSString *entityName;
@property (nonatomic, readonly, strong) NSManagedObjectContext *context;

// Query options by name ($filter, $apply, $orderby, $expand, $select,
// $search, $compute, $top, $skip, or the service's own), written as OData
// writes them; the store percent-encodes them. Setting them reads them
// into queryOptions (a mistake in them is the query's error); reading them
// writes queryOptions.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSString *> *options;
// The same, typed (ODataKit's ODataQueryOptions): an ODataExpression
// filter, order and expand items, $apply's transformations.
@property (nonatomic, copy, nullable) ODataQueryOptions *queryOptions;
// NSManagedObjectResultType or NSDictionaryResultType.
@property (nonatomic) NSFetchRequestResultType resultType;

// $apply's steps in Core Data's terms, translated as a fetch request is:
// predicates, key paths and sort descriptors of the model. They come
// first, then the $apply of options, if any.
//
//   // $apply=descendants($root/SalesOrganizations,SalesOrgHierarchy,ID,filter(Name eq 'US'),keep start)
//   //   /traverse($root/SalesOrganizations,SalesOrgHierarchy,ID,preorder,Name asc)
//   [query addDescendantsInHierarchy:@"SalesOrgHierarchy" nodeKeyPath:nil
//                                 of:[NSPredicate predicateWithFormat:@"name == 'US'"] maxDistance:0 keepStart:YES];
//   [query addTraversalOfHierarchy:@"SalesOrgHierarchy" nodeKeyPath:nil postorder:NO
//                  sortDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ]];
//
// A hierarchy is the one the model declares with the qualifier
// (ODataHierarchyPredicate.h); nodeKeyPath is where each object's node
// identifier is (nil: the object's own, when it is a node; a sale's
// organization: salesOrganization.id). The start of ancestors and
// descendants is the objects the predicate picks; maxDistance 0 is any.
// A traversal's roots, and here each node's children, are sorted by the
// sort descriptors, key paths of the hierarchy's entity.
- (void)addFilter:(NSPredicate *)predicate;
- (void)addAncestorsInHierarchy:(NSString *)qualifier nodeKeyPath:(nullable NSString *)nodeKeyPath
                             of:(NSPredicate *)start maxDistance:(NSUInteger)maxDistance keepStart:(BOOL)keepStart;
- (void)addDescendantsInHierarchy:(NSString *)qualifier nodeKeyPath:(nullable NSString *)nodeKeyPath
                               of:(NSPredicate *)start maxDistance:(NSUInteger)maxDistance keepStart:(BOOL)keepStart;
- (void)addTraversalOfHierarchy:(NSString *)qualifier nodeKeyPath:(nullable NSString *)nodeKeyPath postorder:(BOOL)postorder
                sortDescriptors:(nullable NSArray<NSSortDescriptor *> *)sortDescriptors;

// The GET it is sent as; nil, and why, when it cannot be.
- (nullable NSURL *)URL:(NSError **)error;

// The rows: managed objects, or dictionaries; nil and the error when the
// service refuses the query, or when a row is no object.
- (nullable NSArray *)execute:(NSError **)error;
- (void)executeWithTarget:(id)target action:(SEL)action;
@property (nonatomic, readonly, copy, nullable) NSArray *result;
@property (nonatomic, readonly, strong, nullable) NSError *error;

@end

// Part of a fetch request's predicate written in OData: a $filter
// expression, sent as it is, ANDed, ORed or negated with the rest, which
// the store translates. For what a predicate cannot say, in a fetch that
// otherwise can (sorted, batched, in an NSFetchedResultsController):
//
//   // Sales?$filter=(Amount mul 3 ge $these/aggregate(Amount with sum)) and (ID gt 2)
//   fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
//     [ODataFilterPredicate predicateWithFilter:@"Amount mul 3 ge $these/aggregate(Amount with sum)"],
//     [NSPredicate predicateWithFormat:@"id > 2"] ]];
//
// The service evaluates it; in memory it holds for no object (an object
// the service has not given cannot answer it), so a fetch that includes
// the context's unsaved objects leaves them out.
@interface ODataFilterPredicate : NSPredicate <NSSecureCoding>
+ (instancetype)predicateWithFilter:(NSString *)filter;
@property (nonatomic, readonly, copy) NSString *filter;
@end

NS_ASSUME_NONNULL_END
