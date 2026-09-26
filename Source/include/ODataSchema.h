// ODataIncrementalStore — the service's $metadata (CSDL XML).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What the store needs of a service's schema (OData CSDL XML 4.0): entity
// types with their keys, properties, navigation properties and base types;
// complex types with their properties and base types; enumeration types;
// entity sets. A property typed by a type definition takes its underlying
// type. Functions, actions and annotations are read past. Type names are
// kept qualified by namespace; an alias ("Self.Person") resolves to its
// namespace, in a collection's element type too.

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataSchemaProperty : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;          // qualified: Edm.String, NS.Color, Collection(Edm.String)
@property (nonatomic) BOOL nullable;
@property (nonatomic, readonly) BOOL isCollection;
@property (nonatomic, readonly) NSString *elementType;  // the type, without Collection()
@end

@interface ODataSchemaNavigationProperty : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;          // the target entity type, qualified, without Collection()
@property (nonatomic) BOOL isCollection;
@property (nonatomic) BOOL containsTarget;
@property (nonatomic, copy, nullable) NSString *partner;
@end

@interface ODataSchemaEntityType : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qualifiedName;
@property (nonatomic, copy, nullable) NSString *baseType;  // qualified
@property (nonatomic) BOOL isAbstract;
@property (nonatomic, copy) NSArray<NSString *> *declaredKey;  // empty on a derived type
@property (nonatomic, copy) NSDictionary<NSString *, ODataSchemaProperty *> *declaredProperties;
@property (nonatomic, copy) NSDictionary<NSString *, ODataSchemaNavigationProperty *> *declaredNavigationProperties;
@end

// A structured value without identity (CSDL section 9). Navigation
// properties of complex types are read past.
@interface ODataSchemaComplexType : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qualifiedName;
@property (nonatomic, copy, nullable) NSString *baseType;  // qualified
@property (nonatomic) BOOL isAbstract;
@property (nonatomic) BOOL isOpen;
@property (nonatomic, copy) NSDictionary<NSString *, ODataSchemaProperty *> *declaredProperties;
@end

@interface ODataSchemaEnumType : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *qualifiedName;
@property (nonatomic) BOOL isFlags;
@property (nonatomic, copy) NSArray<NSString *> *memberNames;       // in declaration order
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *values;
@end

@interface ODataSchema : NSObject

+ (nullable instancetype)schemaWithData:(NSData *)csdl error:(NSError **)error;

@property (nonatomic, readonly) NSDictionary<NSString *, ODataSchemaEntityType *> *entityTypes;  // by qualified name
@property (nonatomic, readonly) NSDictionary<NSString *, ODataSchemaComplexType *> *complexTypes;  // by qualified name
@property (nonatomic, readonly) NSDictionary<NSString *, ODataSchemaEnumType *> *enumTypes;      // by qualified name
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *entitySets;                // name -> qualified type
// The OData version the service speaks: <edmx:Edmx Version="4.01">.
@property (nonatomic, readonly, copy) NSString *version;
// The entity container is annotated Org.OData.Capabilities.V1.KeyAsSegmentSupported.
@property (nonatomic, readonly) BOOL keyAsSegmentSupported;

// A qualified or alias-qualified name, as the schema's qualified name.
- (NSString *)qualifiedName:(NSString *)name;
- (nullable ODataSchemaEntityType *)entityTypeNamed:(NSString *)name;
- (nullable ODataSchemaComplexType *)complexTypeNamed:(NSString *)name;
- (nullable ODataSchemaEnumType *)enumTypeNamed:(NSString *)name;
// The entity type with this simple name, if exactly one has it.
- (nullable ODataSchemaEntityType *)entityTypeWithSimpleName:(NSString *)name;

// Through the base types.
- (NSArray<NSString *> *)keyOfEntityType:(ODataSchemaEntityType *)type;
- (nullable ODataSchemaProperty *)property:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type;
- (nullable ODataSchemaNavigationProperty *)navigationProperty:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type;
- (BOOL)entityType:(ODataSchemaEntityType *)type isOrDerivesFrom:(ODataSchemaEntityType *)ancestor;
- (nullable ODataSchemaProperty *)property:(NSString *)name ofComplexType:(ODataSchemaComplexType *)type;
// Its properties and its base types', by name.
- (NSDictionary<NSString *, ODataSchemaProperty *> *)propertiesOfComplexType:(ODataSchemaComplexType *)type;

// The entity set holding entities of this type: one declared for it, or
// for its nearest base type that has one.
- (nullable NSString *)entitySetForEntityType:(ODataSchemaEntityType *)type;

// Whether entities of this type are contained in others (a navigation
// property with ContainsTarget reaches this type or a base of it): such
// entities have no entity set, and are reached through their container.
- (BOOL)entityTypeIsContained:(ODataSchemaEntityType *)type;

@end

NS_ASSUME_NONNULL_END
