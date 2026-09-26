// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataModelBuilder.h"
#import "ODataPropertyMapper.h"
#import "ODataValue.h"
#import "ODataError.h"

NSString * const ODataUserInfoUnmapped = @"OData.unmapped";
NSString * const ODataModelVersionPrefix = @"odata:";

// The version identifier again, on every entity: FreeCoreData's momc before
// v0.4.1 does not carry a model's userDefinedModelVersionIdentifier into
// the compiled model, and an entity's userInfo survives any momc.
static NSString * const OISUserInfoModelVersion = @"OData.modelVersion";

#pragma mark - Names

// UserName is userName, ID is id, URLPath is urlPath.
static NSString *OISLowerCamel(NSString *name)
{
  NSUInteger n = 0;
  while (n < name.length && [[NSCharacterSet uppercaseLetterCharacterSet] characterIsMember:[name characterAtIndex:n]]) n++;
  if (n == 0) return name;
  if (n == name.length) return name.lowercaseString;
  NSUInteger lower = n == 1 ? 1 : n - 1;
  return [[[name substringToIndex:lower] lowercaseString] stringByAppendingString:[name substringFromIndex:lower]];
}

// Names NSManagedObject or NSObject already answer to.
static BOOL OISReserved(NSString *name)
{
  static NSSet *reserved;
  if (!reserved) {
    reserved = [NSSet setWithArray:@[ @"description", @"entity", @"objectID", @"managedObjectContext", @"class", @"hash",
                                      @"self", @"superclass", @"zone", @"isDeleted", @"isInserted", @"isUpdated", @"isFault",
                                      @"deleted", @"inserted", @"updated", @"fault", @"hasChanges", @"changedValues",
                                      @"faultingState", @"debugDescription" ]];
  }
  return [reserved containsObject:name];
}

// A property name for the model, unique within its entity and inherited
// names.
static NSString *OISPropertyName(NSString *wire, NSMutableSet *taken)
{
  NSString *name = OISLowerCamel(wire);
  if (!name.length) name = @"property";
  if (OISReserved(name)) name = [name stringByAppendingString:@"Value"];
  NSString *unique = name;
  for (NSUInteger i = 2; [taken containsObject:unique]; i++) unique = [NSString stringWithFormat:@"%@%lu", name, (unsigned long)i];
  [taken addObject:unique];
  return unique;
}

#pragma mark - Types

// The attribute type for an Edm type, and the OData.type to mark it with
// when its Core Data type alone would be read as another Edm type. NO for
// what has no attribute.
static BOOL OISAttributeType(NSString *edm, ODataSchema *schema, NSAttributeType *type, NSString **marked)
{
  *marked = nil;
  // A collection of what an attribute could hold, or a complex value:
  // Transformable, an NSArray or an NSDictionary (see ODataValue.h).
  if ([edm hasPrefix:@"Collection("] && [edm hasSuffix:@")"]) {
    NSString *element = [edm substringWithRange:NSMakeRange(11, edm.length - 12)];
    NSAttributeType elementType;
    NSString *elementMarked;
    if ([element hasPrefix:@"Collection("] || !OISAttributeType(element, schema, &elementType, &elementMarked)) return NO;
    *type = NSTransformableAttributeType;
    *marked = [NSString stringWithFormat:@"Collection(%@)", [schema qualifiedName:element]];
    return YES;
  }
  if ([schema complexTypeNamed:edm]) {
    *type = NSTransformableAttributeType;
    *marked = [schema qualifiedName:edm];
    return YES;
  }
  if ([schema enumTypeNamed:edm]) {
    *type = NSStringAttributeType;
    *marked = [schema qualifiedName:edm];
    return YES;
  }
  static NSDictionary *plain, *markedTypes;
  if (!plain) {
    plain = @{
      @"Edm.String": @(NSStringAttributeType), @"Edm.Boolean": @(NSBooleanAttributeType),
      @"Edm.Byte": @(NSInteger16AttributeType), @"Edm.SByte": @(NSInteger16AttributeType),
      @"Edm.Int16": @(NSInteger16AttributeType), @"Edm.Int32": @(NSInteger32AttributeType),
      @"Edm.Int64": @(NSInteger64AttributeType), @"Edm.Decimal": @(NSDecimalAttributeType),
      @"Edm.Double": @(NSDoubleAttributeType), @"Edm.Single": @(NSFloatAttributeType),
      @"Edm.DateTimeOffset": @(NSDateAttributeType), @"Edm.Binary": @(NSBinaryDataAttributeType),
    };
    markedTypes = @{
      @"Edm.Date": @(NSDateAttributeType), @"Edm.TimeOfDay": @(NSStringAttributeType),
      @"Edm.Duration": @(NSDoubleAttributeType), @"Edm.Guid": @(NSStringAttributeType),
    };
  }
  NSNumber *t = plain[edm];
  if (t) {
    *type = (NSAttributeType)t.unsignedIntegerValue;
    return YES;
  }
  t = markedTypes[edm];
  if (t) {
    *type = (NSAttributeType)t.unsignedIntegerValue;
    *marked = edm;
    return YES;
  }
  return NO;
}

static NSString *OISAttributeTypeName(NSAttributeType type)
{
  switch (type) {
    case NSInteger16AttributeType: return @"Integer 16";
    case NSInteger32AttributeType: return @"Integer 32";
    case NSInteger64AttributeType: return @"Integer 64";
    case NSDecimalAttributeType: return @"Decimal";
    case NSDoubleAttributeType: return @"Double";
    case NSFloatAttributeType: return @"Float";
    case NSStringAttributeType: return @"String";
    case NSBooleanAttributeType: return @"Boolean";
    case NSDateAttributeType: return @"Date";
    case NSBinaryDataAttributeType: return @"Binary";
    default: return type == NSUUIDAttributeType ? @"UUID" : @"Transformable";
  }
}

#pragma mark - The model

@implementation ODataModelBuilder

+ (NSString *)versionIdentifierForSchema:(ODataSchema *)schema
{
  // A canonical text of what the model is made from, hashed (FNV-1a, 64
  // bits: this identifies a version, it does not protect anything).
  NSMutableString *canonical = [NSMutableString string];
  for (NSString *name in [schema.entityTypes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaEntityType *type = schema.entityTypes[name];
    [canonical appendFormat:@"E %@ %@ %d %@\n", name, type.baseType ?: @"", type.isAbstract, [type.declaredKey componentsJoinedByString:@","]];
    for (NSString *p in [type.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *property = type.declaredProperties[p];
      [canonical appendFormat:@"P %@ %@ %d\n", p, property.type, property.nullable];
    }
    for (NSString *n in [type.declaredNavigationProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaNavigationProperty *navigation = type.declaredNavigationProperties[n];
      [canonical appendFormat:@"N %@ %@ %d %@\n", n, navigation.type, navigation.isCollection, navigation.partner ?: @""];
    }
  }
  for (NSString *name in [schema.complexTypes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaComplexType *type = schema.complexTypes[name];
    [canonical appendFormat:@"C %@ %@ %d %d\n", name, type.baseType ?: @"", type.isAbstract, type.isOpen];
    for (NSString *p in [type.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *property = type.declaredProperties[p];
      [canonical appendFormat:@"P %@ %@ %d\n", p, property.type, property.nullable];
    }
  }
  for (NSString *name in [schema.enumTypes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaEnumType *type = schema.enumTypes[name];
    [canonical appendFormat:@"M %@ %d", name, type.isFlags];
    for (NSString *member in type.memberNames) [canonical appendFormat:@" %@=%@", member, type.values[member]];
    [canonical appendString:@"\n"];
  }
  for (NSString *set in [schema.entitySets.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [canonical appendFormat:@"S %@ %@\n", set, schema.entitySets[set]];
  }
  NSData *bytes = [canonical dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *p = bytes.bytes;
  uint64_t hash = 14695981039346656037ULL;
  for (NSUInteger i = 0; i < bytes.length; i++) {
    hash ^= p[i];
    hash *= 1099511628211ULL;
  }
  return [NSString stringWithFormat:@"%@%016llx", ODataModelVersionPrefix, (unsigned long long)hash];
}

+ (NSString *)versionIdentifierOfModel:(NSManagedObjectModel *)model
{
  for (id identifier in model.versionIdentifiers) {
    if ([identifier isKindOfClass:[NSString class]] && [identifier hasPrefix:ODataModelVersionPrefix]) return identifier;
  }
  for (NSEntityDescription *entity in model.entities) {
    NSString *version = entity.userInfo[OISUserInfoModelVersion];
    if ([version isKindOfClass:[NSString class]] && [version hasPrefix:ODataModelVersionPrefix]) return version;
  }
  return nil;
}

+ (NSManagedObjectModel *)modelWithSchema:(ODataSchema *)schema
{
  NSString *version = [self versionIdentifierForSchema:schema];
  NSArray *typeNames = [schema.entityTypes.allKeys sortedArrayUsingSelector:@selector(compare:)];

  // Entity names: the type's name, unless two namespaces share it.
  NSMutableDictionary *entities = [NSMutableDictionary dictionary];  // qualified type -> entity
  NSCountedSet *simpleNames = [NSCountedSet set];
  for (NSString *qualified in typeNames) [simpleNames addObject:schema.entityTypes[qualified].name];
  for (NSString *qualified in typeNames) {
    ODataSchemaEntityType *type = schema.entityTypes[qualified];
    NSString *name = [simpleNames countForObject:type.name] > 1 ? [qualified stringByReplacingOccurrencesOfString:@"." withString:@"_"] : type.name;
    if (name.length) name = [[[name substringToIndex:1] uppercaseString] stringByAppendingString:[name substringFromIndex:1]];
    NSEntityDescription *entity = [[NSEntityDescription alloc] init];
    entity.name = name;
    entity.managedObjectClassName = @"NSManagedObject";
    entity.abstract = type.isAbstract;
    NSMutableDictionary *info = [@{ ODataUserInfoType: qualified, OISUserInfoModelVersion: version } mutableCopy];
    // Its own set: a derived type is found through its base's.
    NSMutableArray *sets = [NSMutableArray array];
    for (NSString *set in schema.entitySets) {
      if ([schema.entitySets[set] isEqualToString:qualified]) [sets addObject:set];
    }
    if (sets.count == 1) info[ODataUserInfoEntitySet] = sets.firstObject;
    entity.userInfo = info;
    entities[qualified] = entity;
  }

  // Attributes, and a place for relationships, entity by entity; base
  // types first, so a derived type knows the names it inherits.
  NSMutableDictionary *taken = [NSMutableDictionary dictionary];           // qualified type -> NSMutableSet of names
  NSMutableDictionary *relationships = [NSMutableDictionary dictionary];   // "Type/Nav" -> relationship
  NSMutableDictionary *properties = [NSMutableDictionary dictionary];      // qualified type -> NSMutableArray
  NSMutableArray *ordered = [NSMutableArray array];
  NSMutableSet *placed = [NSMutableSet set];
  while (ordered.count < typeNames.count) {
    NSUInteger before = ordered.count;
    for (NSString *qualified in typeNames) {
      if ([placed containsObject:qualified]) continue;
      NSString *base = schema.entityTypes[qualified].baseType;
      if (base && entities[base] && ![placed containsObject:base]) continue;
      [ordered addObject:qualified];
      [placed addObject:qualified];
    }
    if (ordered.count == before) break;  // a base type cycle: leave the rest out
  }
  for (NSString *qualified in ordered) {
    ODataSchemaEntityType *type = schema.entityTypes[qualified];
    NSString *base = type.baseType && entities[type.baseType] ? type.baseType : nil;
    NSMutableSet *names = base ? [taken[base] mutableCopy] : [NSMutableSet set];
    taken[qualified] = names;
    NSMutableArray *own = [NSMutableArray array];
    NSMutableArray *unmapped = [NSMutableArray array];
    NSSet *key = [NSSet setWithArray:type.declaredKey];
    for (NSString *wire in [type.declaredProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaProperty *property = type.declaredProperties[wire];
      NSAttributeType attributeType;
      NSString *marked = nil;
      if (!OISAttributeType(property.type, schema, &attributeType, &marked)) {
        [unmapped addObject:wire];
        continue;
      }
      NSAttributeDescription *attr = [[NSAttributeDescription alloc] init];
      attr.name = OISPropertyName(wire, names);
      attr.attributeType = attributeType;
      attr.optional = property.nullable && ![key containsObject:wire];
      NSMutableDictionary *info = [@{ ODataUserInfoProperty: wire } mutableCopy];
      if ([key containsObject:wire]) info[ODataUserInfoKey] = @"YES";
      if (marked) info[ODataUserInfoType] = marked;
      attr.userInfo = info;
      if (attributeType == NSTransformableAttributeType) {
        attr.valueTransformerName = @"NSSecureUnarchiveFromData";
        attr.attributeValueClassName = property.isCollection ? @"NSArray" : @"NSDictionary";
      }
      [own addObject:attr];
    }
    for (NSString *wire in [type.declaredNavigationProperties.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataSchemaNavigationProperty *navigation = type.declaredNavigationProperties[wire];
      NSEntityDescription *destination = entities[navigation.type];
      if (!destination) {
        [unmapped addObject:wire];
        continue;
      }
      NSRelationshipDescription *rel = [[NSRelationshipDescription alloc] init];
      rel.name = OISPropertyName(wire, names);
      rel.destinationEntity = destination;
      rel.minCount = 0;
      rel.maxCount = navigation.isCollection ? 0 : 1;
      rel.optional = YES;
      rel.deleteRule = NSNullifyDeleteRule;
      rel.userInfo = @{ ODataUserInfoProperty: wire };
      relationships[[NSString stringWithFormat:@"%@/%@", qualified, wire]] = rel;
      [own addObject:rel];
    }
    if (unmapped.count) {
      NSEntityDescription *entity = entities[qualified];
      NSMutableDictionary *info = [entity.userInfo mutableCopy];
      info[ODataUserInfoUnmapped] = [unmapped componentsJoinedByString:@","];
      entity.userInfo = info;
    }
    properties[qualified] = own;
  }

  // Partners are inverses.
  for (NSString *qualified in ordered) {
    ODataSchemaEntityType *type = schema.entityTypes[qualified];
    for (NSString *wire in type.declaredNavigationProperties) {
      ODataSchemaNavigationProperty *navigation = type.declaredNavigationProperties[wire];
      NSRelationshipDescription *rel = relationships[[NSString stringWithFormat:@"%@/%@", qualified, wire]];
      if (!rel || !navigation.partner) continue;
      NSRelationshipDescription *partner = nil;
      for (ODataSchemaEntityType *t = schema.entityTypes[navigation.type]; t && !partner; t = t.baseType ? schema.entityTypes[t.baseType] : nil) {
        partner = relationships[[NSString stringWithFormat:@"%@/%@", t.qualifiedName, navigation.partner]];
      }
      if (partner) {
        rel.inverseRelationship = partner;
        partner.inverseRelationship = rel;
      }
    }
  }

  NSMutableArray *all = [NSMutableArray array];
  for (NSString *qualified in ordered) {
    NSEntityDescription *entity = entities[qualified];
    entity.properties = properties[qualified];
    [all addObject:entity];
  }
  for (NSString *qualified in ordered) {
    NSMutableArray *children = [NSMutableArray array];
    for (NSString *other in ordered) {
      if ([schema.entityTypes[other].baseType isEqualToString:qualified]) [children addObject:entities[other]];
    }
    if (children.count) [entities[qualified] setSubentities:children];
  }
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = all;
  model.versionIdentifiers = [NSSet setWithObject:version];
  return model;
}

#pragma mark - Writing a model

static NSString *OISEscape(NSString *s)
{
  NSMutableString *out = [s mutableCopy];
  [out replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, out.length)];
  [out replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, out.length)];
  [out replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, out.length)];
  [out replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, out.length)];
  return out;
}

static void OISAppendUserInfo(NSMutableString *xml, NSDictionary *info, NSString *indent)
{
  if (!info.count) return;
  [xml appendFormat:@"%@<userInfo>\n", indent];
  for (NSString *key in [info.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [xml appendFormat:@"%@    <entry key=\"%@\" value=\"%@\"/>\n", indent, OISEscape(key), OISEscape([info[key] description])];
  }
  [xml appendFormat:@"%@</userInfo>\n", indent];
}

+ (NSData *)modelDocumentForModel:(NSManagedObjectModel *)model
{
  NSString *version = [self versionIdentifierOfModel:model];
  NSMutableString *xml = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"];
  [xml appendFormat:@"<model type=\"com.apple.IDECoreDataModeler.DataModel\" documentVersion=\"1.0\" lastSavedToolsVersion=\"1\" "
                    @"systemVersion=\"1\" minimumToolsVersion=\"Automatic\" sourceLanguage=\"Objective-C\" "
                    @"userDefinedModelVersionIdentifier=\"%@\">\n", OISEscape(version ?: @"")];
  NSArray *entities = [model.entities sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [[a name] compare:[b name]];
  }];
  for (NSEntityDescription *entity in entities) {
    [xml appendFormat:@"    <entity name=\"%@\"", OISEscape(entity.name)];
    if (entity.superentity) [xml appendFormat:@" parentEntity=\"%@\"", OISEscape(entity.superentity.name)];
    if (entity.isAbstract) [xml appendString:@" isAbstract=\"YES\""];
    [xml appendString:@" syncable=\"YES\">\n"];
    NSDictionary *inherited = entity.superentity.propertiesByName ?: @{};
    NSArray *names = [entity.propertiesByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
      if (inherited[name]) continue;
      NSPropertyDescription *property = entity.propertiesByName[name];
      if ([property isKindOfClass:[NSAttributeDescription class]]) {
        NSAttributeDescription *attr = (NSAttributeDescription *)property;
        [xml appendFormat:@"        <attribute name=\"%@\" optional=\"%@\" attributeType=\"%@\"", OISEscape(name),
                          attr.isOptional ? @"YES" : @"NO", OISAttributeTypeName(attr.attributeType)];
        if (attr.valueTransformerName.length) [xml appendFormat:@" valueTransformerName=\"%@\"", OISEscape(attr.valueTransformerName)];
        if (attr.attributeValueClassName.length) [xml appendFormat:@" customClassName=\"%@\"", OISEscape(attr.attributeValueClassName)];
        if (attr.attributeType == NSInteger16AttributeType || attr.attributeType == NSInteger32AttributeType ||
            attr.attributeType == NSInteger64AttributeType || attr.attributeType == NSDoubleAttributeType ||
            attr.attributeType == NSFloatAttributeType || attr.attributeType == NSBooleanAttributeType ||
            attr.attributeType == NSDateAttributeType) {
          [xml appendString:@" usesScalarValueType=\"NO\""];
        }
      } else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
        NSRelationshipDescription *rel = (NSRelationshipDescription *)property;
        [xml appendFormat:@"        <relationship name=\"%@\" optional=\"YES\"", OISEscape(name)];
        if (rel.isToMany) [xml appendString:@" toMany=\"YES\""];
        else [xml appendString:@" maxCount=\"1\""];
        [xml appendFormat:@" deletionRule=\"Nullify\" destinationEntity=\"%@\"", OISEscape(rel.destinationEntity.name ?: @"")];
        if (rel.inverseRelationship) {
          [xml appendFormat:@" inverseName=\"%@\" inverseEntity=\"%@\"", OISEscape(rel.inverseRelationship.name),
                            OISEscape(rel.inverseRelationship.entity.name ?: @"")];
        }
      } else {
        continue;
      }
      if (property.userInfo.count) {
        [xml appendString:@">\n"];
        OISAppendUserInfo(xml, property.userInfo, @"            ");
        [xml appendString:[property isKindOfClass:[NSAttributeDescription class]] ? @"        </attribute>\n" : @"        </relationship>\n"];
      } else {
        [xml appendString:@"/>\n"];
      }
    }
    OISAppendUserInfo(xml, entity.userInfo, @"        ");
    [xml appendString:@"    </entity>\n"];
  }
  [xml appendString:@"</model>\n"];
  return [xml dataUsingEncoding:NSUTF8StringEncoding];
}

// The userDefinedModelVersionIdentifier of a model document, or of the
// first entity's OData.modelVersion entry.
static NSString *OISDocumentVersion(NSData *document)
{
  NSString *xml = [[NSString alloc] initWithData:document encoding:NSUTF8StringEncoding];
  for (NSString *marker in @[ @"userDefinedModelVersionIdentifier=\"", @"key=\"OData.modelVersion\" value=\"" ]) {
    NSRange start = [xml rangeOfString:marker];
    if (start.location == NSNotFound) continue;
    NSUInteger from = NSMaxRange(start);
    NSRange end = [xml rangeOfString:@"\"" options:0 range:NSMakeRange(from, xml.length - from)];
    NSString *value = end.location == NSNotFound ? nil : [xml substringWithRange:NSMakeRange(from, end.location - from)];
    if (value.length) return value;
  }
  return nil;
}

+ (NSString *)writeModel:(NSManagedObjectModel *)model toPackage:(NSString *)path changed:(BOOL *)changed error:(NSError **)error
{
  NSFileManager *fm = [NSFileManager defaultManager];
  NSString *name = path.lastPathComponent.stringByDeletingPathExtension;
  NSString *currentFile = [path stringByAppendingPathComponent:@".xccurrentversion"];
  NSData *document = [self modelDocumentForModel:model];
  NSString *version = [self versionIdentifierOfModel:model];
  if (changed) *changed = NO;

  NSDictionary *current = [NSDictionary dictionaryWithContentsOfFile:currentFile];
  NSString *currentName = current[@"_XCCurrentVersionName"];
  NSMutableSet *existing = [NSMutableSet set];
  for (NSString *entry in [fm contentsOfDirectoryAtPath:path error:NULL] ?: @[]) {
    if ([entry.pathExtension isEqualToString:@"xcdatamodel"]) [existing addObject:entry];
  }
  if (!currentName && existing.count == 1) currentName = existing.anyObject;
  if (currentName) {
    NSData *old = [NSData dataWithContentsOfFile:[[path stringByAppendingPathComponent:currentName] stringByAppendingPathComponent:@"contents"]];
    if (version && [OISDocumentVersion(old) isEqualToString:version]) return currentName.stringByDeletingPathExtension;
  }

  // A new version: "Zoo", then "Zoo 2", "Zoo 3", ...
  NSString *versionName = [name stringByAppendingPathExtension:@"xcdatamodel"];
  for (NSUInteger i = 2; [existing containsObject:versionName]; i++) {
    versionName = [[NSString stringWithFormat:@"%@ %lu", name, (unsigned long)i] stringByAppendingPathExtension:@"xcdatamodel"];
  }
  NSString *directory = [path stringByAppendingPathComponent:versionName];
  if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
  if (![document writeToFile:[directory stringByAppendingPathComponent:@"contents"] options:NSDataWritingAtomic error:error]) return nil;
  NSData *plist = [NSPropertyListSerialization dataWithPropertyList:@{ @"_XCCurrentVersionName": versionName }
                                                             format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
  if (!plist || ![plist writeToFile:currentFile options:NSDataWritingAtomic error:error]) return nil;
  if (changed) *changed = YES;
  return versionName.stringByDeletingPathExtension;
}

@end
