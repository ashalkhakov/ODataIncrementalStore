// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "OISCoreData.h"
#import "ODataConfiguration.h"
#import "ODataValue.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ODataUserInfoEntitySet;
FOUNDATION_EXPORT NSString * const ODataUserInfoProperty;
FOUNDATION_EXPORT NSString * const ODataUserInfoKey;

@interface ODataPropertyMapper : NSObject
@property (nonatomic) ODataPropertyNaming naming;
// How values are written and read; see ODataValue.h.
@property (nonatomic, strong) ODataValueCoder *values;

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity;
- (NSString *)propertyForAttribute:(NSAttributeDescription *)attribute;
- (NSString *)propertyForRelationship:(NSRelationshipDescription *)relationship;
- (NSArray<NSAttributeDescription *> *)keyAttributesForEntity:(NSEntityDescription *)entity;
- (NSString *)wireName:(NSString *)coreDataName;
// A Core Data key path as an OData property path: each step by its wire
// name, through relationships, joined with '/' (Part 2 section 5.1.1.15).
- (NSString *)propertyPathForKeyPath:(NSString *)keyPath entity:(nullable NSEntityDescription *)entity;
@end

NS_ASSUME_NONNULL_END
