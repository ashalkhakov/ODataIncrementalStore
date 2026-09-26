// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataPropertyMapper.h"

NSString * const ODataUserInfoEntitySet = @"OData.entitySet";
NSString * const ODataUserInfoProperty = @"OData.property";
NSString * const ODataUserInfoKey = @"OData.key";

@implementation ODataPropertyMapper

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _naming = ODataPropertyNamingPascalCase;
  _values = [[ODataValueCoder alloc] init];
  return self;
}

- (void)setSchema:(ODataSchema *)schema
{
  _schema = schema;
  _values.schema = schema;
  __weak ODataPropertyMapper *weakSelf = self;
  _values.declaredTypeForAttribute = schema ? ^NSString *(NSAttributeDescription *attribute) {
    return [weakSelf declaredTypeForAttribute:attribute];
  } : nil;
}

#pragma mark - Types and sets

- (ODataSchemaEntityType *)entityTypeForEntity:(NSEntityDescription *)entity
{
  if (!self.schema || !entity) return nil;
  NSString *declared = entity.userInfo[ODataUserInfoType];
  if ([declared isKindOfClass:[NSString class]]) return [self.schema entityTypeNamed:declared];
  return [self.schema entityTypeWithSimpleName:entity.name ?: @""];
}

- (NSString *)qualifiedTypeForEntity:(NSEntityDescription *)entity
{
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  if (type) return type.qualifiedName;
  NSString *declared = entity.userInfo[ODataUserInfoType];
  return [declared isKindOfClass:[NSString class]] ? declared : nil;
}

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity
{
  NSString *override = entity.userInfo[ODataUserInfoEntitySet];
  if ([override isKindOfClass:[NSString class]]) return override;
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  NSString *set = type ? [self.schema entitySetForEntityType:type] : nil;
  if (set) return set;
  // A sub-entity lives in its super-entity's set.
  if (entity.superentity) return [self entitySetForEntity:entity.superentity];
  NSString *name = entity.name ?: @"Entity";
  if ([name hasSuffix:@"s"]) return name;
  if ([name hasSuffix:@"y"] && name.length > 1) {
    return [[name substringToIndex:name.length - 1] stringByAppendingString:@"ies"];
  }
  return [name stringByAppendingString:@"s"];
}

- (BOOL)entityIsDerivedInItsSet:(NSEntityDescription *)entity
{
  NSString *qualified = [self qualifiedTypeForEntity:entity];
  if (!qualified) return NO;
  NSString *setType = self.schema.entitySets[[self entitySetForEntity:entity]];
  if (setType) return ![setType isEqualToString:qualified];
  // No schema: a sub-entity that names its type is derived.
  return entity.superentity != nil;
}

- (NSString *)collectionPathForEntity:(NSEntityDescription *)entity
{
  NSString *set = [self entitySetForEntity:entity];
  if (![self entityIsDerivedInItsSet:entity]) return set;
  return [NSString stringWithFormat:@"%@/%@", set, [self qualifiedTypeForEntity:entity]];
}

- (NSEntityDescription *)entity:(NSEntityDescription *)entity forTypeName:(NSString *)typeName
{
  if (![typeName isKindOfClass:[NSString class]] || !typeName.length) return entity;
  NSString *name = [typeName hasPrefix:@"#"] ? [typeName substringFromIndex:1] : typeName;
  if (self.schema) name = [self.schema qualifiedName:name];
  NSMutableArray *queue = [NSMutableArray arrayWithObject:entity];
  while (queue.count) {
    NSEntityDescription *candidate = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([[self qualifiedTypeForEntity:candidate] isEqualToString:name]) return candidate;
    [queue addObjectsFromArray:candidate.subentities];
  }
  return entity;
}

#pragma mark - Names

// The schema's name for a property when it differs from ours only in case
// (Id against ID): a name made from the attribute's is a guess.
- (NSString *)schemaName:(NSString *)guess inEntity:(NSEntityDescription *)entity navigation:(BOOL)navigation
{
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  if (!type) return guess;
  BOOL exists = navigation ? [self.schema navigationProperty:guess ofEntityType:type] != nil
                           : [self.schema property:guess ofEntityType:type] != nil;
  if (exists) return guess;
  for (ODataSchemaEntityType *t = type; t; t = t.baseType ? [self.schema entityTypeNamed:t.baseType] : nil) {
    NSArray *names = navigation ? t.declaredNavigationProperties.allKeys : t.declaredProperties.allKeys;
    for (NSString *name in names) {
      if ([name caseInsensitiveCompare:guess] == NSOrderedSame) return name;
    }
  }
  return guess;
}

- (NSString *)propertyForAttribute:(NSAttributeDescription *)attribute
{
  NSString *override = attribute.userInfo[ODataUserInfoProperty];
  if ([override isKindOfClass:[NSString class]]) return override;
  return [self schemaName:[self wireName:attribute.name] inEntity:attribute.entity navigation:NO];
}

- (NSString *)propertyForRelationship:(NSRelationshipDescription *)relationship
{
  NSString *override = relationship.userInfo[ODataUserInfoProperty];
  if ([override isKindOfClass:[NSString class]]) return override;
  return [self schemaName:[self wireName:relationship.name] inEntity:relationship.entity navigation:YES];
}

- (NSString *)declaredTypeForAttribute:(NSAttributeDescription *)attribute
{
  ODataSchemaEntityType *type = [self entityTypeForEntity:attribute.entity];
  if (!type) return nil;
  return [self.schema property:[self propertyForAttribute:attribute] ofEntityType:type].type;
}

#pragma mark - Keys

- (NSArray *)keyAttributesForEntity:(NSEntityDescription *)entity
{
  NSMutableArray *flagged = [NSMutableArray array];
  [entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    // gnustep-base types this block (id, id, BOOL *): no generics to narrow it.
    NSAttributeDescription *attr = obj;
    (void)key;
    id flag = attr.userInfo[ODataUserInfoKey];
    if ([flag isEqual:@"YES"] || [flag isEqual:@YES]) [flagged addObject:attr];
  }];
  if (flagged.count) return flagged;

  // The schema's key, where every part of it is an attribute.
  ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
  NSArray *schemaKey = type ? [self.schema keyOfEntityType:type] : @[];
  if (schemaKey.count) {
    NSMutableArray *found = [NSMutableArray array];
    for (NSString *wire in schemaKey) {
      for (NSAttributeDescription *attr in entity.attributesByName.allValues) {
        if ([[self propertyForAttribute:attr] isEqualToString:wire]) {
          [found addObject:attr];
          break;
        }
      }
    }
    if (found.count == schemaKey.count) return found;
  }

  NSArray *candidates = @[ @"id", @"ID", @"Id", [NSString stringWithFormat:@"%@ID", entity.name ?: @""] ];
  for (NSString *c in candidates) {
    NSAttributeDescription *attr = entity.attributesByName[c];
    if (attr) return @[ attr ];
  }
  return @[];
}

- (NSString *)propertyPathForKeyPath:(NSString *)keyPath entity:(NSEntityDescription *)entity
{
  NSEntityDescription *current = entity;
  NSMutableArray *mapped = [NSMutableArray array];
  for (NSString *part in [keyPath componentsSeparatedByString:@"."]) {
    NSAttributeDescription *attr = current.attributesByName[part];
    NSRelationshipDescription *rel = attr ? nil : current.relationshipsByName[part];
    if (attr) {
      [mapped addObject:[self propertyForAttribute:attr]];
      current = nil;
    } else if (rel) {
      [mapped addObject:[self propertyForRelationship:rel]];
      current = rel.destinationEntity;
    } else {
      [mapped addObject:[self wireName:part]];
      current = nil;
    }
  }
  return [mapped componentsJoinedByString:@"/"];
}

- (NSString *)wireName:(NSString *)coreDataName
{
  if (self.naming == ODataPropertyNamingAsIs || coreDataName.length == 0) return coreDataName;
  NSString *first = [[coreDataName substringToIndex:1] uppercaseString];
  return [first stringByAppendingString:[coreDataName substringFromIndex:1]];
}

#pragma mark - Checking a model

// Whether an attribute of this Core Data type can hold a property of this
// Edm type.
static BOOL OISCanHold(NSAttributeType core, NSString *edm, ODataSchema *schema)
{
  if ([schema enumTypeNamed:edm]) {
    return core == NSStringAttributeType || core == NSInteger16AttributeType ||
           core == NSInteger32AttributeType || core == NSInteger64AttributeType;
  }
  NSArray *integers = @[ @(NSInteger16AttributeType), @(NSInteger32AttributeType), @(NSInteger64AttributeType) ];
  NSDictionary *holders = @{
    @"Edm.String": @[ @(NSStringAttributeType) ],
    @"Edm.Boolean": @[ @(NSBooleanAttributeType) ],
    @"Edm.Byte": integers,
    @"Edm.SByte": integers,
    @"Edm.Int16": integers,
    @"Edm.Int32": @[ @(NSInteger32AttributeType), @(NSInteger64AttributeType) ],
    @"Edm.Int64": @[ @(NSInteger64AttributeType) ],
    @"Edm.Decimal": @[ @(NSDecimalAttributeType), @(NSDoubleAttributeType) ],
    @"Edm.Double": @[ @(NSDoubleAttributeType), @(NSDecimalAttributeType) ],
    @"Edm.Single": @[ @(NSFloatAttributeType), @(NSDoubleAttributeType), @(NSDecimalAttributeType) ],
    @"Edm.DateTimeOffset": @[ @(NSDateAttributeType) ],
    @"Edm.Date": @[ @(NSDateAttributeType) ],
    @"Edm.TimeOfDay": @[ @(NSStringAttributeType) ],
    @"Edm.Duration": @[ @(NSDoubleAttributeType) ],
    @"Edm.Guid": @[ @(NSUUIDAttributeType), @(NSStringAttributeType) ],
    @"Edm.Binary": @[ @(NSBinaryDataAttributeType) ],
  };
  NSArray *allowed = holders[edm];
  return allowed ? [allowed containsObject:@(core)] : NO;
}

static NSString *OISJoinedSorted(NSSet *names)
{
  return [[names.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","];
}

- (NSArray *)problemsWithModel:(NSManagedObjectModel *)model
{
  if (!self.schema) return @[];
  NSMutableArray *problems = [NSMutableArray array];
  NSArray *entities = [model.entities sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [[a name] compare:[b name]];
  }];
  for (NSEntityDescription *entity in entities) {
    ODataSchemaEntityType *type = [self entityTypeForEntity:entity];
    if (!type) {
      [problems addObject:[NSString stringWithFormat:@"%@: no entity type %@ in $metadata", entity.name,
                                                     [self qualifiedTypeForEntity:entity] ?: entity.name]];
      continue;
    }
    NSString *set = [self entitySetForEntity:entity];
    ODataSchemaEntityType *setType = [self.schema entityTypeNamed:self.schema.entitySets[set] ?: @""];
    if (!setType) {
      // A contained entity has no set; its container's navigation reaches it.
      if (![self.schema entityTypeIsContained:type]) {
        [problems addObject:[NSString stringWithFormat:@"%@: no entity set %@", entity.name, set]];
      }
    } else if (![self.schema entityType:type isOrDerivesFrom:setType]) {
      [problems addObject:[NSString stringWithFormat:@"%@: entity set %@ holds %@, not %@", entity.name, set,
                                                     setType.qualifiedName, type.qualifiedName]];
    }

    // What a sub-entity inherits is checked where it is declared.
    NSEntityDescription *parent = entity.superentity;
    for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      NSAttributeDescription *attr = entity.attributesByName[name];
      if (attr.isTransient || parent.attributesByName[name]) continue;
      NSString *wire = [self propertyForAttribute:attr];
      ODataSchemaProperty *property = [self.schema property:wire ofEntityType:type];
      if (!property) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: no property %@ in %@", entity.name, name, wire, type.qualifiedName]];
      } else if (![attr.userInfo[ODataUserInfoType] isKindOfClass:[NSString class]] &&
                 !OISCanHold(attr.attributeType, property.type, self.schema)) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: %@ is %@, which this attribute cannot hold",
                                                       entity.name, name, wire, property.type]];
      }
    }

    NSMutableSet *ours = [NSMutableSet set];
    for (NSAttributeDescription *attr in [self keyAttributesForEntity:entity]) [ours addObject:[self propertyForAttribute:attr]];
    NSSet *theirs = [NSSet setWithArray:[self.schema keyOfEntityType:type]];
    if (theirs.count && ![ours isEqualToSet:theirs]) {
      [problems addObject:[NSString stringWithFormat:@"%@: key %@, but %@ is keyed by %@", entity.name,
                                                     OISJoinedSorted(ours), type.qualifiedName, OISJoinedSorted(theirs)]];
    }

    for (NSString *name in [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      NSRelationshipDescription *rel = entity.relationshipsByName[name];
      if (parent.relationshipsByName[name]) continue;
      NSString *wire = [self propertyForRelationship:rel];
      ODataSchemaNavigationProperty *navigation = [self.schema navigationProperty:wire ofEntityType:type];
      if (!navigation) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: no navigation property %@ in %@", entity.name, name, wire, type.qualifiedName]];
      } else if (navigation.isCollection != rel.isToMany) {
        [problems addObject:[NSString stringWithFormat:@"%@.%@: %@ is %@, the relationship %@", entity.name, name, wire,
                                                       navigation.isCollection ? @"a collection" : @"single-valued",
                                                       rel.isToMany ? @"to-many" : @"to-one"]];
      }
    }
  }
  return problems;
}

@end
