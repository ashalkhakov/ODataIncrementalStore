// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataMetadataWriter.h"

static NSString *OISXML(NSString *text)
{
  NSMutableString *s = [text mutableCopy] ?: [NSMutableString string];
  [s replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, s.length)];
  [s replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, s.length)];
  [s replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, s.length)];
  [s replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, s.length)];
  return s;
}

static NSString *OISNamespaceOf(NSString *qualified)
{
  NSRange dot = [qualified rangeOfString:@"." options:NSBackwardsSearch];
  return dot.location == NSNotFound ? @"" : [qualified substringToIndex:dot.location];
}

static NSString *OISSimpleNameOf(NSString *qualified)
{
  NSRange dot = [qualified rangeOfString:@"." options:NSBackwardsSearch];
  return dot.location == NSNotFound ? qualified : [qualified substringFromIndex:dot.location + 1];
}

static NSString *OISElementTypeOf(NSString *type)
{
  if ([type hasPrefix:@"Collection("] && [type hasSuffix:@")"]) {
    return [type substringWithRange:NSMakeRange(11, type.length - 12)];
  }
  return type;
}

@implementation ODataMetadataWriter {
  NSMutableArray<NSString *> *_problems;
}

- (instancetype)initWithModel:(NSManagedObjectModel *)model mapper:(ODataPropertyMapper *)mapper
{
  self = [super init];
  if (!self) return nil;
  _model = model;
  _mapper = mapper;
  _namespaceName = @"Default";
  _containerName = @"Container";
  return self;
}

- (NSArray *)problems
{
  if (!_problems) [self XMLStringForVersion:@"4.01"];
  return [_problems copy];
}

#pragma mark - Types

- (NSString *)typeNameForAttribute:(NSAttributeDescription *)attribute
{
  if (attribute.isTransient) return nil;
  NSString *declared = attribute.userInfo[ODataUserInfoType];
  if ([declared isKindOfClass:[NSString class]] && declared.length) return declared;
  switch (attribute.attributeType) {
    case NSInteger16AttributeType: return @"Edm.Int16";
    case NSInteger32AttributeType: return @"Edm.Int32";
    case NSInteger64AttributeType: return @"Edm.Int64";
    case NSDecimalAttributeType: return @"Edm.Decimal";
    case NSDoubleAttributeType: return @"Edm.Double";
    case NSFloatAttributeType: return @"Edm.Single";
    case NSStringAttributeType: return @"Edm.String";
    case NSBooleanAttributeType: return @"Edm.Boolean";
    case NSDateAttributeType: return @"Edm.DateTimeOffset";
    case NSBinaryDataAttributeType: return @"Edm.Binary";
    default: break;
  }
  if (attribute.attributeType == NSUUIDAttributeType) return @"Edm.Guid";
  if (attribute.attributeType == NSURIAttributeType) return @"Edm.String";
  return nil;
}

- (NSString *)typeNameForEntity:(NSEntityDescription *)entity
{
  return [self.mapper qualifiedTypeForEntity:entity] ?: [NSString stringWithFormat:@"%@.%@", self.namespaceName, entity.name];
}

- (NSEntityDescription *)rootOf:(NSEntityDescription *)entity
{
  while (entity.superentity) entity = entity.superentity;
  return entity;
}

- (NSArray *)entities
{
  NSMutableArray *entities = [NSMutableArray array];
  for (NSEntityDescription *entity in self.model.entities) {
    if ([self.mapper keyAttributesForEntity:[self rootOf:entity]].count) [entities addObject:entity];
  }
  return entities;
}

// The properties an entity declares itself, not those it inherits.
- (NSArray<NSPropertyDescription *> *)declaredProperties:(NSEntityDescription *)entity
{
  NSDictionary *inherited = entity.superentity.propertiesByName ?: @{};
  NSMutableArray *declared = [NSMutableArray array];
  for (NSPropertyDescription *property in entity.properties) {
    if (!inherited[property.name]) [declared addObject:property];
  }
  return declared;
}

#pragma mark - Writing

- (void)append:(NSString *)xml toNamespace:(NSString *)ns in:(NSMutableDictionary<NSString *, NSMutableString *> *)schemas
{
  NSMutableString *schema = schemas[ns];
  if (!schema) {
    schema = [NSMutableString string];
    schemas[ns] = schema;
  }
  [schema appendString:xml];
}

- (NSString *)propertyXML:(NSString *)name type:(NSString *)type nullable:(BOOL)nullable
{
  NSMutableString *xml = [NSMutableString stringWithFormat:@"<Property Name=\"%@\" Type=\"%@\"", OISXML(name), OISXML(type)];
  if (!nullable) [xml appendString:@" Nullable=\"false\""];
  if ([OISElementTypeOf(type) isEqualToString:@"Edm.Decimal"]) [xml appendString:@" Scale=\"variable\""];
  [xml appendString:@"/>"];
  return xml;
}

- (void)writeEntity:(NSEntityDescription *)entity into:(NSMutableDictionary *)schemas used:(NSMutableSet *)usedTypes
{
  NSString *qualified = [self typeNameForEntity:entity];
  NSMutableString *xml = [NSMutableString stringWithFormat:@"<EntityType Name=\"%@\"", OISXML(OISSimpleNameOf(qualified))];
  if (entity.superentity) [xml appendFormat:@" BaseType=\"%@\"", OISXML([self typeNameForEntity:entity.superentity])];
  if (entity.isAbstract) [xml appendString:@" Abstract=\"true\""];
  [xml appendString:@">"];

  NSArray *key = entity.superentity ? @[] : [self.mapper keyAttributesForEntity:entity];
  if (key.count) {
    [xml appendString:@"<Key>"];
    for (NSAttributeDescription *attr in key) {
      [xml appendFormat:@"<PropertyRef Name=\"%@\"/>", OISXML([self.mapper propertyForAttribute:attr])];
    }
    [xml appendString:@"</Key>"];
  }
  for (NSPropertyDescription *property in [self declaredProperties:entity]) {
    if ([property isKindOfClass:[NSAttributeDescription class]]) {
      NSAttributeDescription *attr = (NSAttributeDescription *)property;
      NSString *type = [self typeNameForAttribute:attr];
      if (!type) {
        if (!attr.isTransient) {
          [_problems addObject:[NSString stringWithFormat:@"%@.%@ has no Edm type: give it an OData.type", entity.name, attr.name]];
        }
        continue;
      }
      NSString *element = OISElementTypeOf(type);
      if (![element hasPrefix:@"Edm."]) {
        if (!self.mapper.schema.complexTypes[element] && !self.mapper.schema.enumTypes[element]) {
          [_problems addObject:[NSString stringWithFormat:@"%@.%@ is a %@, which no schema defines", entity.name, attr.name, element]];
          continue;
        }
        [usedTypes addObject:element];
      }
      BOOL nullable = attr.isOptional && ![key containsObject:attr];
      [xml appendString:[self propertyXML:[self.mapper propertyForAttribute:attr] type:type nullable:nullable]];
    } else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
      NSRelationshipDescription *rel = (NSRelationshipDescription *)property;
      NSEntityDescription *target = rel.destinationEntity;
      if (!target || ![self.mapper keyAttributesForEntity:[self rootOf:target]].count) continue;
      NSString *targetType = [self typeNameForEntity:target];
      NSString *type = rel.isToMany ? [NSString stringWithFormat:@"Collection(%@)", targetType] : targetType;
      [xml appendFormat:@"<NavigationProperty Name=\"%@\" Type=\"%@\"", OISXML([self.mapper propertyForRelationship:rel]), OISXML(type)];
      if (!rel.isToMany && !rel.isOptional) [xml appendString:@" Nullable=\"false\""];
      if (rel.inverseRelationship) {
        [xml appendFormat:@" Partner=\"%@\"", OISXML([self.mapper propertyForRelationship:rel.inverseRelationship])];
      }
      [xml appendString:@"/>"];
    }
  }
  [xml appendString:@"</EntityType>"];
  [self append:xml toNamespace:OISNamespaceOf(qualified) in:schemas];
}

// Complex types and enumerations the entities use, copied from the
// mapper's schema, with the types they use in turn.
- (void)writeSchemaTypes:(NSMutableSet *)used into:(NSMutableDictionary *)schemas
{
  ODataSchema *schema = self.mapper.schema;
  NSMutableSet *written = [NSMutableSet set];
  NSMutableArray *queue = [[used allObjects] mutableCopy];
  [queue sortUsingSelector:@selector(compare:)];
  while (queue.count) {
    NSString *name = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([written containsObject:name]) continue;
    [written addObject:name];
    ODataSchemaEnumType *enumType = schema.enumTypes[name];
    if (enumType) {
      NSMutableString *xml = [NSMutableString stringWithFormat:@"<EnumType Name=\"%@\"", OISXML(enumType.name)];
      if (enumType.isFlags) [xml appendString:@" IsFlags=\"true\""];
      [xml appendString:@">"];
      for (NSString *member in enumType.memberNames) {
        [xml appendFormat:@"<Member Name=\"%@\" Value=\"%@\"/>", OISXML(member), enumType.values[member]];
      }
      [xml appendString:@"</EnumType>"];
      [self append:xml toNamespace:OISNamespaceOf(name) in:schemas];
      continue;
    }
    ODataSchemaComplexType *complex = schema.complexTypes[name];
    if (!complex) continue;
    NSMutableString *xml = [NSMutableString stringWithFormat:@"<ComplexType Name=\"%@\"", OISXML(complex.name)];
    if (complex.baseType) {
      [xml appendFormat:@" BaseType=\"%@\"", OISXML(complex.baseType)];
      [queue addObject:complex.baseType];
    }
    if (complex.isAbstract) [xml appendString:@" Abstract=\"true\""];
    if (complex.isOpen) [xml appendString:@" OpenType=\"true\""];
    [xml appendString:@">"];
    for (NSString *propertyName in [complex.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *p = complex.declaredProperties[propertyName];
      [xml appendString:[self propertyXML:p.name type:p.type nullable:p.nullable]];
      if (![p.elementType hasPrefix:@"Edm."]) [queue addObject:p.elementType];
    }
    [xml appendString:@"</ComplexType>"];
    [self append:xml toNamespace:OISNamespaceOf(name) in:schemas];
  }
}

- (NSString *)containerXML
{
  NSMutableString *xml = [NSMutableString stringWithFormat:@"<EntityContainer Name=\"%@\">", OISXML(self.containerName)];
  NSArray *entities = self.entities;
  for (NSEntityDescription *entity in entities) {
    if (entity.superentity) continue;
    [xml appendFormat:@"<EntitySet Name=\"%@\" EntityType=\"%@\">",
     OISXML([self.mapper entitySetForEntity:entity]), OISXML([self typeNameForEntity:entity])];
    // Its own relationships, and those of its derived types by a cast.
    for (NSEntityDescription *member in entities) {
      if ([self rootOf:member] != entity) continue;
      NSString *cast = member == entity ? @"" : [[self typeNameForEntity:member] stringByAppendingString:@"/"];
      for (NSPropertyDescription *property in [self declaredProperties:member]) {
        if (![property isKindOfClass:[NSRelationshipDescription class]]) continue;
        NSRelationshipDescription *rel = (NSRelationshipDescription *)property;
        if (!rel.destinationEntity || ![entities containsObject:rel.destinationEntity]) continue;
        [xml appendFormat:@"<NavigationPropertyBinding Path=\"%@%@\" Target=\"%@\"/>",
         OISXML(cast), OISXML([self.mapper propertyForRelationship:rel]),
         OISXML([self.mapper entitySetForEntity:[self rootOf:rel.destinationEntity]])];
      }
    }
    NSAttributeDescription *concurrency = self.concurrencyAttributes[entity.name];
    if (concurrency) {
      [xml appendFormat:@"<Annotation Term=\"Org.OData.Core.V1.OptimisticConcurrency\"><Collection>"
                        @"<PropertyPath>%@</PropertyPath></Collection></Annotation>",
       OISXML([self.mapper propertyForAttribute:concurrency])];
    }
    [xml appendString:@"</EntitySet>"];
  }
  [xml appendString:@"</EntityContainer>"];
  return xml;
}

- (NSString *)XMLStringForVersion:(NSString *)version
{
  _problems = [NSMutableArray array];
  NSMutableDictionary<NSString *, NSMutableString *> *schemas = [NSMutableDictionary dictionary];
  NSMutableSet *usedTypes = [NSMutableSet set];
  for (NSEntityDescription *entity in self.model.entities) {
    if (![self.entities containsObject:entity]) {
      [_problems addObject:[NSString stringWithFormat:@"%@ has no key: give an attribute OData.key, or name it id", entity.name]];
      continue;
    }
    [self writeEntity:entity into:schemas used:usedTypes];
  }
  [self writeSchemaTypes:usedTypes into:schemas];
  [self append:[self containerXML] toNamespace:self.namespaceName in:schemas];

  NSMutableString *xml = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"];
  [xml appendFormat:@"<edmx:Edmx Version=\"%@\" xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\">", OISXML(version)];
  if (self.concurrencyAttributes.count) {
    [xml appendString:@"<edmx:Reference Uri=\"https://oasis-tcs.github.io/odata-vocabularies/vocabularies/Org.OData.Core.V1.xml\">"
                      @"<edmx:Include Namespace=\"Org.OData.Core.V1\" Alias=\"Core\"/></edmx:Reference>"];
  }
  [xml appendString:@"<edmx:DataServices>"];
  for (NSString *ns in [schemas.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [xml appendFormat:@"<Schema Namespace=\"%@\" xmlns=\"http://docs.oasis-open.org/odata/ns/edm\">%@</Schema>", OISXML(ns), schemas[ns]];
  }
  [xml appendString:@"</edmx:DataServices></edmx:Edmx>"];
  return xml;
}

@end
