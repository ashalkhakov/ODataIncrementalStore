// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "OISCoreData.h"
#import "ODataValue.h"
#import "ODataSchema.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ODataPropertyNaming) {
  ODataPropertyNamingAsIs = 0,
  ODataPropertyNamingPascalCase = 1
};


FOUNDATION_EXPORT NSString * const ODataUserInfoEntitySet;
FOUNDATION_EXPORT NSString * const ODataUserInfoProperty;
FOUNDATION_EXPORT NSString * const ODataUserInfoKey;
// The Core vocabulary in userInfo: OData.description and
// OData.longDescription (text), OData.computed and OData.immutable (YES),
// OData.permissions (Read, ReadWrite, None); and OData.annotations, any
// annotations at all, by term, as a dictionary of JSON CSDL values or JSON
// text of one ({"Validation.Pattern": "^[A-Z]", "Core.Description#fr":
// "Nom"}). A service writes them into $metadata; a model built from
// $metadata has them from its annotations.
FOUNDATION_EXPORT NSString * const ODataUserInfoDescription;
FOUNDATION_EXPORT NSString * const ODataUserInfoLongDescription;
FOUNDATION_EXPORT NSString * const ODataUserInfoComputed;
FOUNDATION_EXPORT NSString * const ODataUserInfoImmutable;
FOUNDATION_EXPORT NSString * const ODataUserInfoPermissions;
FOUNDATION_EXPORT NSString * const ODataUserInfoAnnotations;

@interface ODataPropertyMapper : NSObject
@property (nonatomic) ODataPropertyNaming naming;
// How values are written and read; see ODataValue.h.
@property (nonatomic, strong) ODataValueCoder *values;

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity;
- (NSString *)propertyForAttribute:(NSAttributeDescription *)attribute;
- (NSString *)propertyForRelationship:(NSRelationshipDescription *)relationship;
- (NSArray<NSAttributeDescription *> *)keyAttributesForEntity:(NSEntityDescription *)entity;
// The other way: the attribute or relationship of an entity (its own or
// inherited) that a service calls this; nil when there is none.
- (nullable NSPropertyDescription *)propertyForWireName:(NSString *)name entity:(NSEntityDescription *)entity;
- (NSString *)wireName:(NSString *)coreDataName;
// A Core Data key path as an OData property path: each step by its wire
// name, through relationships, joined with '/' (Part 2 section 5.1.1.15).
// A key path that goes on past an attribute holding a complex value
// (address.city) goes on into its members: Address/City.
- (NSString *)propertyPathForKeyPath:(NSString *)keyPath entity:(nullable NSEntityDescription *)entity;
// The same, with the type the path ends at, when it ends in a complex
// value's member (qualified; nil otherwise).
- (NSString *)propertyPathForKeyPath:(NSString *)keyPath
                              entity:(nullable NSEntityDescription *)entity
                          memberType:(NSString * _Nullable * _Nullable)memberType;
// Members of a value of this type (a complex type, or a collection of
// one): each by the schema's name for it, which may differ in case from
// the one given, joined with '/'; the last one's type through memberType.
- (NSString *)memberPath:(NSArray<NSString *> *)members
                  ofType:(nullable NSString *)typeName
              memberType:(NSString * _Nullable * _Nullable)memberType;

// The service's $metadata, when it could be read. With it the mapper finds
// what the model leaves unsaid: an entity's type and entity set (Person
// is in People), a key with no OData.key, a property's Edm type (an
// Edm.Date on a Date attribute, an enumeration), a name whose case differs
// from the attribute's. userInfo in the model always wins.
@property (nonatomic, strong, nullable) ODataSchema *schema;

// The entity type an entity stands for: userInfo[@"OData.type"] on the
// entity, else the schema's entity type of the entity's name.
- (nullable ODataSchemaEntityType *)entityTypeForEntity:(NSEntityDescription *)entity;
// An attribute a client does not write: Core.Computed, or Core.Permissions
// Read (or None), in its userInfo or the schema's annotations of its
// property.
- (BOOL)attributeIsComputed:(NSAttributeDescription *)attribute;
// Written when the entity is made, and not after: Core.Immutable.
- (BOOL)attributeIsImmutable:(NSAttributeDescription *)attribute;
// What of the Validation vocabulary Core Data cannot hold an object
// breaks: Validation.MultipleOf of an attribute, Validation.Constraint of
// its entity type or a property (a condition, a CSDL expression over the
// entity's properties: Eq, Ne, Gt, Ge, Lt, Le, And, Or, Not, If, In, Path,
// Null, constants, and Apply of odata.matchesPattern; a property's only
// while it has a value). A
// NSManagedObjectValidationError naming the object, and the property, with
// the constraint's FailureMessage; nil when it breaks none. From the
// schema's annotations, else userInfo's (OData.annotations).
- (nullable NSError *)vocabularyViolationOfObject:(NSManagedObject *)object;
// A condition as a predicate of an entity's objects; nil for an expression
// it cannot write.
- (nullable NSPredicate *)predicateForCondition:(id)condition entity:(NSEntityDescription *)entity;
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
