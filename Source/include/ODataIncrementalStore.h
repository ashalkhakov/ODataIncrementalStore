// ODataIncrementalStore — NSIncrementalStore over OData v4.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Modern Objective-C (libobjc2 / ARC / blocks / properties / zeroing weak).
// Builds on GNUstep (clang + gnustep-base) and Apple Core Data.

#pragma once

#import "OISRuntime.h"
#import "OISCoreData.h"
#import "ODataError.h"
#import "ODataConfiguration.h"
#import "ODataClient.h"
#import "ODataPropertyMapper.h"
#import "ODataValue.h"
#import "ODataBatch.h"
#import "ODataSchema.h"
#import "ODataModelBuilder.h"
#import "ODataResourceIdentifier.h"
#import "ODataPredicateTranslator.h"
#import "ODataQueryBuilder.h"

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
// -[ODataPropertyMapper problemsWithModel:]). Opening fails on them only
// with ODataIncrementalStoreRequireMatchingModelOption.
@property (nonatomic, readonly) NSArray<NSString *> *metadataProblems;

// Every row a fetch or a relationship read brings back is kept, and serves
// the faults that fire afterwards; a later read of the same entities
// replaces it. Discard the kept rows of these objects (nil: all of them)
// to have their next fault read the service. -[NSManagedObjectContext
// refreshObject:mergeChanges:] alone turns an object back into a fault,
// which this store then fills from what it kept.
- (void)discardCachedRowsForObjectIDs:(nullable NSArray<NSManagedObjectID *> *)objectIDs;

@end

NS_ASSUME_NONNULL_END
