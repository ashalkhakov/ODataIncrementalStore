// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "OISCoreData.h"
#import "ODataPropertyMapper.h"

NS_ASSUME_NONNULL_BEGIN

// The key properties of a saved object, by wire name (the keys of its
// ODataResourceIdentifier), or nil for an object the store does not know.
typedef NSDictionary * _Nullable (^ODataObjectKeysResolver)(NSManagedObjectID *objectID);

@interface ODataPredicateTranslator : NSObject
@property (nonatomic, strong) ODataPropertyMapper *mapper;
@property (nonatomic, strong) NSEntityDescription *entity;
// Lets `category == %@` compare keys when the constant is a managed
// object or an object ID. Without it, only a managed object whose key
// attributes are loaded can be compared.
@property (nonatomic, copy, nullable) ODataObjectKeysResolver keysForObjectID;

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper entity:(NSEntityDescription *)entity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSString *)translatePredicate:(NSPredicate *)predicate error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
