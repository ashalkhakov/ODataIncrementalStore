// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "OISCoreData.h"
#import "ODataConfiguration.h"
#import "ODataValue.h"
#import "ODataSchema.h"

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

// The service's $metadata, when it could be read. With it the mapper finds
// what the model leaves unsaid: an entity's type and entity set (Person
// is in People), a key with no OData.key, a property's Edm type (an
// Edm.Date on a Date attribute, an enumeration), a name whose case differs
// from the attribute's. userInfo in the model always wins.
@property (nonatomic, strong, nullable) ODataSchema *schema;

// The entity type an entity stands for: userInfo[@"OData.type"] on the
// entity, else the schema's entity type of the entity's name.
- (nullable ODataSchemaEntityType *)entityTypeForEntity:(NSEntityDescription *)entity;
// Its qualified name, from the schema or from userInfo alone.
- (nullable NSString *)qualifiedTypeForEntity:(NSEntityDescription *)entity;
// The path an entity's rows are read from: its entity set, followed by a
// type cast (People/NS.Employee) when the entity is a derived type in a
// set of its base type (Part 2 section 4.11).
- (NSString *)collectionPathForEntity:(NSEntityDescription *)entity;
// Whether a new object of this entity is a derived type in its set, and so
// needs @odata.type in the POST body.
- (BOOL)entityIsDerivedInItsSet:(NSEntityDescription *)entity;
// The entity, or one of its sub-entities, for an entity type named in a
// row's @odata.type.
- (NSEntityDescription *)entity:(NSEntityDescription *)entity forTypeName:(nullable NSString *)typeName;
// The Edm type the schema declares for an attribute, qualified; nil
// without a schema or without the property.
- (nullable NSString *)declaredTypeForAttribute:(NSAttributeDescription *)attribute;

// What does not match between a model and the schema, one sentence each:
// an entity with no entity type or entity set, an attribute or
// relationship with no property, a type that cannot hold the other, a key
// that differs. Empty without a schema.
- (NSArray<NSString *> *)problemsWithModel:(NSManagedObjectModel *)model;
@end

NS_ASSUME_NONNULL_END
