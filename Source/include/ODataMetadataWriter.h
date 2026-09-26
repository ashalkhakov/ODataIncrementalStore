// ODataIncrementalStore — a Core Data model as CSDL.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// $metadata for a service over a Core Data model (OData 4.01 CSDL XML):
// an entity type per entity, derived types for sub-entities, a key from the
// mapper (userInfo OData.key, else id), properties typed as ODataValueCoder
// reads and writes them, navigation properties with their partners, and an
// entity set per root entity, bound to each other through the
// relationships. Names come from the same ODataPropertyMapper the client
// uses, so one model file describes both ends.
//
// A Core Data model has no complex types or enumerations. An attribute
// whose userInfo OData.type names one is written when the mapper's schema
// defines it (as it does for a model built from a service's $metadata by
// ODataModelBuilder); the definitions are copied from there.

#pragma once
#import "OISCoreData.h"
#import "ODataPropertyMapper.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataMetadataWriter : NSObject

- (instancetype)initWithModel:(NSManagedObjectModel *)model mapper:(ODataPropertyMapper *)mapper NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSManagedObjectModel *model;
@property (nonatomic, readonly) ODataPropertyMapper *mapper;
// The schema's namespace, for entities whose userInfo names no type of
// their own. Default: Default.
@property (nonatomic, copy) NSString *namespaceName;
@property (nonatomic, copy) NSString *containerName;  // Default: Container
// The attribute each entity's ETag is made of, when it has one
// (Core.OptimisticConcurrency). Set by the service.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, NSAttributeDescription *> *concurrencyAttributes;

// The document, in the CSDL of this OData-Version: 4.0 or 4.01.
- (NSString *)XMLStringForVersion:(NSString *)version;

// The qualified Edm type an attribute is written as; nil when it has none
// (a transformable value with no OData.type, a transient attribute).
- (nullable NSString *)typeNameForAttribute:(NSAttributeDescription *)attribute;
// An entity's qualified entity type name.
- (NSString *)typeNameForEntity:(NSEntityDescription *)entity;
// The entities the document has an entity type for: every entity with a key
// (or with a super-entity that has one).
@property (nonatomic, readonly) NSArray<NSEntityDescription *> *entities;
// What the document had to leave out, one sentence each.
@property (nonatomic, readonly) NSArray<NSString *> *problems;

@end

NS_ASSUME_NONNULL_END
