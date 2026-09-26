// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSchema.h"
#import "ODataError.h"

@implementation ODataSchemaProperty
- (BOOL)isCollection
{
  return [self.type hasPrefix:@"Collection("];
}
@end

@implementation ODataSchemaNavigationProperty
@end

@implementation ODataSchemaEntityType
@end

@implementation ODataSchemaEnumType
@end

// Reads CSDL XML into the schema's dictionaries. Element names are taken
// without their prefix (edmx:Edmx, Edmx), so a document is read the same
// with or without namespace prefixes.
@interface OISSchemaReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableDictionary *entityTypes;
@property (nonatomic, strong) NSMutableDictionary *enumTypes;
@property (nonatomic, strong) NSMutableDictionary *entitySets;
@property (nonatomic, strong) NSMutableDictionary *aliases;  // alias -> namespace
@end

@implementation OISSchemaReader {
  NSString *_namespace;
  ODataSchemaEntityType *_entityType;
  NSMutableArray *_key;
  NSMutableDictionary *_properties;
  NSMutableDictionary *_navigation;
  ODataSchemaEnumType *_enumType;
  NSMutableArray *_memberNames;
  NSMutableDictionary *_memberValues;
  BOOL _inKey;
  BOOL _inContainer;
  NSInteger _complexDepth;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _entityTypes = [NSMutableDictionary dictionary];
  _enumTypes = [NSMutableDictionary dictionary];
  _entitySets = [NSMutableDictionary dictionary];
  _aliases = [NSMutableDictionary dictionary];
  return self;
}

static NSString *OISLocalName(NSString *name)
{
  NSRange colon = [name rangeOfString:@":" options:NSBackwardsSearch];
  return colon.location == NSNotFound ? name : [name substringFromIndex:colon.location + 1];
}

- (NSString *)qualify:(NSString *)name
{
  return name.length ? [NSString stringWithFormat:@"%@.%@", _namespace ?: @"", name] : name;
}

- (void)parser:(NSXMLParser *)parser
    didStartElement:(NSString *)elementName
       namespaceURI:(NSString *)namespaceURI
      qualifiedName:(NSString *)qName
         attributes:(NSDictionary *)attributes
{
  NSString *element = OISLocalName(elementName);
  if (_complexDepth) {
    _complexDepth++;
    return;
  }
  if ([element isEqualToString:@"Schema"]) {
    _namespace = attributes[@"Namespace"];
    if (attributes[@"Alias"] && _namespace) _aliases[attributes[@"Alias"]] = _namespace;
  } else if ([element isEqualToString:@"EntityType"]) {
    _entityType = [[ODataSchemaEntityType alloc] init];
    _entityType.name = attributes[@"Name"] ?: @"";
    _entityType.qualifiedName = [self qualify:_entityType.name];
    _entityType.baseType = attributes[@"BaseType"];
    _entityType.isAbstract = [attributes[@"Abstract"] isEqualToString:@"true"];
    _key = [NSMutableArray array];
    _properties = [NSMutableDictionary dictionary];
    _navigation = [NSMutableDictionary dictionary];
  } else if ([element isEqualToString:@"ComplexType"]) {
    _complexDepth = 1;  // not mapped: read past it
  } else if (_entityType && [element isEqualToString:@"Key"]) {
    _inKey = YES;
  } else if (_entityType && _inKey && [element isEqualToString:@"PropertyRef"]) {
    // Alias is for a key in a complex property, which is not mapped.
    if (attributes[@"Name"]) [_key addObject:attributes[@"Name"]];
  } else if (_entityType && [element isEqualToString:@"Property"]) {
    ODataSchemaProperty *property = [[ODataSchemaProperty alloc] init];
    property.name = attributes[@"Name"] ?: @"";
    property.type = attributes[@"Type"] ?: @"Edm.String";
    property.nullable = ![attributes[@"Nullable"] isEqualToString:@"false"];
    _properties[property.name] = property;
  } else if (_entityType && [element isEqualToString:@"NavigationProperty"]) {
    ODataSchemaNavigationProperty *navigation = [[ODataSchemaNavigationProperty alloc] init];
    navigation.name = attributes[@"Name"] ?: @"";
    NSString *type = attributes[@"Type"] ?: @"";
    if ([type hasPrefix:@"Collection("] && [type hasSuffix:@")"]) {
      navigation.isCollection = YES;
      type = [type substringWithRange:NSMakeRange(11, type.length - 12)];
    }
    navigation.type = type;
    navigation.containsTarget = [attributes[@"ContainsTarget"] isEqualToString:@"true"];
    navigation.partner = attributes[@"Partner"];
    _navigation[navigation.name] = navigation;
  } else if ([element isEqualToString:@"EnumType"]) {
    _enumType = [[ODataSchemaEnumType alloc] init];
    _enumType.name = attributes[@"Name"] ?: @"";
    _enumType.qualifiedName = [self qualify:_enumType.name];
    _enumType.isFlags = [attributes[@"IsFlags"] isEqualToString:@"true"];
    _memberNames = [NSMutableArray array];
    _memberValues = [NSMutableDictionary dictionary];
  } else if (_enumType && [element isEqualToString:@"Member"]) {
    NSString *name = attributes[@"Name"];
    if (name) {
      // Without Value, members count up from 0 (CSDL section 10.2.2).
      NSNumber *value = attributes[@"Value"] ? @([attributes[@"Value"] longLongValue]) : @(_memberNames.count);
      [_memberNames addObject:name];
      _memberValues[name] = value;
    }
  } else if ([element isEqualToString:@"EntityContainer"]) {
    _inContainer = YES;
  } else if (_inContainer && [element isEqualToString:@"EntitySet"]) {
    if (attributes[@"Name"] && attributes[@"EntityType"]) _entitySets[attributes[@"Name"]] = attributes[@"EntityType"];
  }
}

- (void)parser:(NSXMLParser *)parser
    didEndElement:(NSString *)elementName
     namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qName
{
  NSString *element = OISLocalName(elementName);
  if (_complexDepth) {
    _complexDepth--;
    return;
  }
  if ([element isEqualToString:@"EntityType"] && _entityType) {
    _entityType.declaredKey = _key;
    _entityType.declaredProperties = _properties;
    _entityType.declaredNavigationProperties = _navigation;
    _entityTypes[_entityType.qualifiedName] = _entityType;
    _entityType = nil;
  } else if ([element isEqualToString:@"Key"]) {
    _inKey = NO;
  } else if ([element isEqualToString:@"EnumType"] && _enumType) {
    _enumType.memberNames = _memberNames;
    _enumType.values = _memberValues;
    _enumTypes[_enumType.qualifiedName] = _enumType;
    _enumType = nil;
  } else if ([element isEqualToString:@"EntityContainer"]) {
    _inContainer = NO;
  }
}

@end

@implementation ODataSchema {
  NSDictionary *_aliases;
}

+ (instancetype)schemaWithData:(NSData *)csdl error:(NSError **)error
{
  OISSchemaReader *reader = [[OISSchemaReader alloc] init];
  NSXMLParser *parser = [[NSXMLParser alloc] initWithData:csdl];
  parser.delegate = reader;
  parser.shouldProcessNamespaces = NO;
  BOOL parsed = [parser parse];
  if (!parsed || (!reader.entityTypes.count && !reader.entitySets.count)) {
    if (error) {
      NSString *why = parser.parserError.localizedDescription ?: @"no entity types or entity sets in it";
      *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"$metadata could not be read: %@", why]);
    }
    return nil;
  }
  ODataSchema *schema = [[ODataSchema alloc] init];
  schema->_aliases = [reader.aliases copy];
  // Base types, set types and the like may be written with an alias.
  NSMutableDictionary *sets = [NSMutableDictionary dictionary];
  for (NSString *set in reader.entitySets) sets[set] = [schema qualifiedName:reader.entitySets[set]];
  for (ODataSchemaEntityType *type in reader.entityTypes.allValues) {
    if (type.baseType) type.baseType = [schema qualifiedName:type.baseType];
    for (ODataSchemaNavigationProperty *navigation in type.declaredNavigationProperties.allValues) {
      navigation.type = [schema qualifiedName:navigation.type];
    }
    for (ODataSchemaProperty *property in type.declaredProperties.allValues) {
      if ([property.type hasPrefix:@"Collection("]) continue;
      property.type = [schema qualifiedName:property.type];
    }
  }
  schema->_entityTypes = [reader.entityTypes copy];
  schema->_enumTypes = [reader.enumTypes copy];
  schema->_entitySets = [sets copy];
  return schema;
}

- (NSString *)qualifiedName:(NSString *)name
{
  NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
  if (dot.location == NSNotFound) return name;
  NSString *prefix = [name substringToIndex:dot.location];
  NSString *namespace = _aliases[prefix];
  return namespace ? [NSString stringWithFormat:@"%@%@", namespace, [name substringFromIndex:dot.location]] : name;
}

- (ODataSchemaEntityType *)entityTypeNamed:(NSString *)name
{
  if (!name) return nil;
  return self.entityTypes[[self qualifiedName:name]];
}

- (ODataSchemaEnumType *)enumTypeNamed:(NSString *)name
{
  if (!name) return nil;
  return self.enumTypes[[self qualifiedName:name]];
}

- (ODataSchemaEntityType *)entityTypeWithSimpleName:(NSString *)name
{
  ODataSchemaEntityType *found = nil;
  for (ODataSchemaEntityType *type in self.entityTypes.allValues) {
    if (![type.name isEqualToString:name]) continue;
    if (found) return nil;  // two namespaces with one name: ambiguous
    found = type;
  }
  return found;
}

- (ODataSchemaEntityType *)baseOf:(ODataSchemaEntityType *)type
{
  return type.baseType ? self.entityTypes[type.baseType] : nil;
}

- (NSArray *)keyOfEntityType:(ODataSchemaEntityType *)type
{
  for (ODataSchemaEntityType *t = type; t; t = [self baseOf:t]) {
    if (t.declaredKey.count) return t.declaredKey;
  }
  return @[];
}

- (ODataSchemaProperty *)property:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type
{
  for (ODataSchemaEntityType *t = type; t; t = [self baseOf:t]) {
    ODataSchemaProperty *property = t.declaredProperties[name];
    if (property) return property;
  }
  return nil;
}

- (ODataSchemaNavigationProperty *)navigationProperty:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type
{
  for (ODataSchemaEntityType *t = type; t; t = [self baseOf:t]) {
    ODataSchemaNavigationProperty *navigation = t.declaredNavigationProperties[name];
    if (navigation) return navigation;
  }
  return nil;
}

- (BOOL)entityType:(ODataSchemaEntityType *)type isOrDerivesFrom:(ODataSchemaEntityType *)ancestor
{
  for (ODataSchemaEntityType *t = type; t; t = [self baseOf:t]) {
    if ([t.qualifiedName isEqualToString:ancestor.qualifiedName]) return YES;
  }
  return NO;
}

- (BOOL)entityTypeIsContained:(ODataSchemaEntityType *)type
{
  for (ODataSchemaEntityType *container in self.entityTypes.allValues) {
    for (ODataSchemaNavigationProperty *navigation in container.declaredNavigationProperties.allValues) {
      if (!navigation.containsTarget) continue;
      ODataSchemaEntityType *target = self.entityTypes[navigation.type];
      if (target && [self entityType:type isOrDerivesFrom:target]) return YES;
    }
  }
  return NO;
}

- (NSString *)entitySetForEntityType:(ODataSchemaEntityType *)type
{
  for (ODataSchemaEntityType *t = type; t; t = [self baseOf:t]) {
    NSMutableArray *sets = [NSMutableArray array];
    for (NSString *set in self.entitySets) {
      if ([self.entitySets[set] isEqualToString:t.qualifiedName]) [sets addObject:set];
    }
    // Two sets of one type: neither is the answer.
    if (sets.count == 1) return sets.firstObject;
    if (sets.count > 1) return nil;
  }
  return nil;
}

@end
