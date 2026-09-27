// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataPropertyMapper.h>

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
// The OData version to write in, @"4.0" by default. IN is `in` in 4.01
// and a chain of `eq … or eq …` in 4.0; LIKE and MATCHES are
// matchesPattern in 4.01 and an error in 4.0, which has no such function.
@property (nonatomic, copy) NSString *version;

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper entity:(NSEntityDescription *)entity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSString *)translatePredicate:(NSPredicate *)predicate error:(NSError **)error;
// One expression, as a $filter or $orderby operand: a key path, a
// constant, a function (lowercase:, an ODataFunctionExpression).
- (nullable NSString *)translateExpression:(NSExpression *)expression error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
