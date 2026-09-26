// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "OISCoreData.h"
#import "ODataPropertyMapper.h"
#import "ODataResourceIdentifier.h"
#import "ODataPredicateTranslator.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataQueryBuilder : NSObject
@property (nonatomic, strong) ODataPropertyMapper *mapper;
// Handed to the predicate translator; see ODataPredicateTranslator.
@property (nonatomic, copy, nullable) ODataObjectKeysResolver keysForObjectID;
@property (nonatomic, copy) NSURL *serviceRoot;

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper serviceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSURL *)URLForFetch:(NSFetchRequest *)fetch
                         entity:(NSEntityDescription *)entity
                          error:(NSError **)error;
- (nullable NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier error:(NSError **)error;
- (nullable NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier
                        relationship:(NSRelationshipDescription *)relationship
                               error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
