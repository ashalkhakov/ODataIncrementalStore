// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataPropertyMapper.h>
#import "ODataResourceIdentifier.h"
#import "ODataPredicateTranslator.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataQueryBuilder : NSObject
@property (nonatomic, strong) ODataPropertyMapper *mapper;
// Handed to the predicate translator; see ODataPredicateTranslator.
@property (nonatomic, copy, nullable) ODataObjectKeysResolver keysForObjectID;
@property (nonatomic, copy) NSURL *serviceRoot;
// Address entities as Products/1 rather than Products(1); see
// -[ODataResourceIdentifier pathWithKeyAsSegment:].
@property (nonatomic) BOOL keyAsSegment;
// The OData version $filter is written in; see ODataPredicateTranslator.
@property (nonatomic, copy) NSString *version;

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper serviceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSURL *)URLForFetch:(NSFetchRequest *)fetch
                         entity:(NSEntityDescription *)entity
                          error:(NSError **)error;
// $apply for a fetch that groups and aggregates: its predicate as
// filter(), then groupby((paths),aggregate(...)), or aggregate(...) alone
// (Data Aggregation section 3). Paths are wire paths (Category/CategoryName).
- (nullable NSURL *)URLForAggregateFetch:(NSFetchRequest *)fetch
                                  entity:(NSEntityDescription *)entity
                              groupPaths:(NSArray<NSArray<NSString *> *> *)paths
                              aggregates:(NSArray *)aggregates
                                   error:(NSError **)error;
- (nullable NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier error:(NSError **)error;
// For reading one entity: the entity URL with its to-one keys expanded.
- (nullable NSURL *)URLForReadingIdentifier:(ODataResourceIdentifier *)identifier
                                     entity:(NSEntityDescription *)entity
                                      error:(NSError **)error;
// Entity(key)/Nav/$ref?$id=<target>: removes one entity from a collection-
// valued navigation property (Part 1 section 11.4.6.2).
- (nullable NSURL *)URLForReferenceFromEntityURL:(NSURL *)entity
                                    relationship:(NSRelationshipDescription *)relationship
                                          target:(NSURL *)target;
- (nullable NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier
                        relationship:(NSRelationshipDescription *)relationship
                               error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
