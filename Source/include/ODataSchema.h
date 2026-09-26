// ODataIncrementalStore — the service's $metadata (CSDL XML).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// What the store needs of a service's schema (OData CSDL XML 4.0): entity
// types with their keys, properties, navigation properties and base types;
// enumeration types; entity sets. Complex types, functions, actions and
// annotations are read past. Type names are kept qualified by namespace;
// an alias ("Self.Person") resolves to its namespace.

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataSchemaProperty : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *type;          // qualified: Edm.String, NS.Color, Collection(Edm.String)
@property (nonatomic) BOOL nullable;
@property (nonatomic, readonly) BOOL isCollection;
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
@property (nonatomic, readonly) NSDictionary<NSString *, ODataSchemaEnumType *> *enumTypes;      // by qualified name
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *entitySets;                // name -> qualified type

// A qualified or alias-qualified name, as the schema's qualified name.
- (NSString *)qualifiedName:(NSString *)name;
- (nullable ODataSchemaEntityType *)entityTypeNamed:(NSString *)name;
- (nullable ODataSchemaEnumType *)enumTypeNamed:(NSString *)name;
// The entity type with this simple name, if exactly one has it.
- (nullable ODataSchemaEntityType *)entityTypeWithSimpleName:(NSString *)name;

// Through the base types.
- (NSArray<NSString *> *)keyOfEntityType:(ODataSchemaEntityType *)type;
- (nullable ODataSchemaProperty *)property:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type;
- (nullable ODataSchemaNavigationProperty *)navigationProperty:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type;
- (BOOL)entityType:(ODataSchemaEntityType *)type isOrDerivesFrom:(ODataSchemaEntityType *)ancestor;

// The entity set holding entities of this type: one declared for it, or
// for its nearest base type that has one.
- (nullable NSString *)entitySetForEntityType:(ODataSchemaEntityType *)type;

@end

NS_ASSUME_NONNULL_END
