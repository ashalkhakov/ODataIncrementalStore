// ODataIncrementalStore — NSIncrementalStore over OData v4.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Modern Objective-C (libobjc2 / ARC / blocks / properties / zeroing weak).
// Builds on GNUstep (clang + gnustep-base) and Apple Core Data.

#pragma once

#import <ODataKit/ODataKit.h>
#import "ODataConfiguration.h"
#import "ODataClient.h"
#import "ODataModelBuilder.h"
#import "ODataClassWriter.h"
#import "ODataResourceIdentifier.h"
#import "ODataPredicateTranslator.h"
#import "ODataQueryBuilder.h"
#import "ODataOperationCall.h"
#import "ODataStreamTransfer.h"
#import "ODataSearchPredicate.h"
#import "ODataTemporalPredicate.h"
#import "ODataFunctionExpression.h"
#import "ODataHierarchyPredicate.h"
#import "ODataQuery.h"
#import "ODataHistory.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataIncrementalStore : NSIncrementalStore

+ (NSString *)storeType;
+ (void)registerStore;

// A dynamic client's model: the one the service's $metadata describes,
// built at runtime (see ODataModelBuilder). Options as for the store:
// credentials, a transport.
+ (nullable NSManagedObjectModel *)modelForServiceAtURL:(NSURL *)url
                                               options:(nullable NSDictionary *)options
                                                 error:(NSError **)error;

// The service's schema as store metadata: the version hashes and version
// identifier of the model its $metadata describes. With models generated
// ahead of time, this picks the version that matches the service the way
// Core Data picks a model for any store:
//
//   NSDictionary *metadata = [ODataIncrementalStore metadataForServiceAtURL:url options:nil error:&error];
//   NSManagedObjectModel *model = [NSManagedObjectModel mergedModelFromBundles:nil forStoreMetadata:metadata];
//
// A store opened with a generated model checks it the same way: when the
// service's schema is no longer the model's, adding the store fails with
// NSPersistentStoreIncompatibleVersionHashError. A model written by hand
// is not version-checked; it is compared with the schema, see
// metadataProblems.
+ (nullable NSDictionary *)metadataForServiceAtURL:(NSURL *)url
                                          options:(nullable NSDictionary *)options
                                            error:(NSError **)error;

// The service's schema, read from $metadata when the store was added; nil
// when it could not be read.
@property (nonatomic, readonly, nullable) ODataSchema *schema;
// Where the model and the schema disagree, one sentence each (see
// -[ODataPropertyMapper problemsWithModel:]): of the store's
// configuration's entities, when it was added with one -- the service's
// own configurationName, say, of the model it serves -- else of all.
// Opening fails on them only with ODataIncrementalStoreRequireMatchingModelOption.
@property (nonatomic, readonly) NSArray<NSString *> *metadataProblems;

// Every row a fetch or a relationship read brings back is kept, and serves
// the faults that fire afterwards; a later read of the same entities
// replaces it. Discard the kept rows of these objects (nil: all of them)
// to have their next fault read the service. -[NSManagedObjectContext
// refreshObject:mergeChanges:] alone turns an object back into a fault,
// which this store then fills from what it kept.
- (void)discardCachedRowsForObjectIDs:(nullable NSArray<NSManagedObjectID *> *)objectIDs;

// Temporal.Update, Upsert or Delete (OData-Temporal section 4.3.2) on the
// set of an entity with application time (ODataTemporalPredicate.h),
// which the service does all or nothing. Each delta time slice is
// attribute values by Core Data name, its period included; a missing end
// is no end, and a missing object key attribute matches every object.
// Returns the slices the service made or changed (for Delete, the periods
// it took away) as attribute values. The rows kept of the entity are
// dropped, and the context's objects of it refreshed, so they and the
// next fetch show the timeline as it is now. Call on the context's queue.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)performTemporalAction:(NSString *)action
                                                              onEntityNamed:(NSString *)entityName
                                                            deltaTimeslices:(NSArray<NSDictionary<NSString *, id> *> *)deltas
                                                                    context:(nullable NSManagedObjectContext *)context
                                                                      error:(NSError **)error;

// What changed at the service since the store last looked (Part 1 section
// 11.3, delta), for the entities in ODataIncrementalStoreTrackedEntitiesOption,
// or every entity with an entity set of its own (of the store's
// configuration, when it was added with one). The first call reads each
// set and starts tracking it: it reports no changes. Later calls follow
// the delta link the service gave, and where it gave none, read the set
// again and compare. The rows the store keeps are brought up to date, so
// the objects' next faults see the changes.
//
// The answer is a notification in the shape of
// NSManagedObjectContextDidSaveObjectIDsNotification (NSInsertedObjectIDsKey,
// NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey), for
// -mergeChangesFromContextDidSaveNotification:. With
// NSPersistentHistoryTrackingKey the changes are also a history
// transaction, by ODataRemoteChangesAuthor, and with
// NSPersistentStoreRemoteChangeNotificationPostOptionKey the store posts
// NSPersistentStoreRemoteChangeNotification for it. nil and the error when
// a request fails.
- (nullable NSNotification *)fetchRemoteChanges:(NSError **)error;

// The GET a fetch request is sent as: its collection read (or /$count);
// for a grouping dictionary fetch, the $apply where the service has it,
// else the read of the rows it is grouped from here. nil, and why, when
// the request cannot be sent.
- (nullable NSURL *)URLForFetchRequest:(NSFetchRequest *)request error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
