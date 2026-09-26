// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "OISCoreData.h"
#import "ODataConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ODataUserInfoEntitySet;
FOUNDATION_EXPORT NSString * const ODataUserInfoProperty;
FOUNDATION_EXPORT NSString * const ODataUserInfoKey;

@interface ODataPropertyMapper : NSObject
@property (nonatomic) ODataPropertyNaming naming;

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity;
- (NSString *)propertyForAttribute:(NSAttributeDescription *)attribute;
- (NSString *)propertyForRelationship:(NSRelationshipDescription *)relationship;
- (NSArray<NSAttributeDescription *> *)keyAttributesForEntity:(NSEntityDescription *)entity;
- (NSString *)wireName:(NSString *)coreDataName;
@end

NS_ASSUME_NONNULL_END
