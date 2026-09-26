// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSchema.h"
#import "ODataError.h"

@implementation ODataSchemaProperty
- (BOOL)isCollection
{
  return [self.type hasPrefix:@"Collection("] && [self.type hasSuffix:@")"];
}
- (NSString *)elementType
{
  return self.isCollection ? [self.type substringWithRange:NSMakeRange(11, self.type.length - 12)] : self.type;
}
@end

@implementation ODataSchemaComplexType
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
@property (nonatomic, strong) NSMutableDictionary *complexTypes;
@property (nonatomic, strong) NSMutableDictionary *enumTypes;
@property (nonatomic, strong) NSMutableDictionary *typeDefinitions;  // qualified name -> underlying type
@property (nonatomic, strong) NSMutableDictionary *entitySets;
@property (nonatomic, strong) NSMutableDictionary *aliases;  // alias -> namespace
@property (nonatomic) BOOL keyAsSegmentSupported;
@property (nonatomic, copy) NSString *version;
@end

@implementation OISSchemaReader {
  NSString *_namespace;
  ODataSchemaEntityType *_entityType;
  ODataSchemaComplexType *_complexType;
  NSMutableArray *_key;
  NSMutableDictionary *_properties;
  NSMutableDictionary *_navigation;
  ODataSchemaEnumType *_enumType;
  NSMutableArray *_memberNames;
  NSMutableDictionary *_memberValues;
  BOOL _inKey;
  BOOL _inContainer;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _entityTypes = [NSMutableDictionary dictionary];
  _complexTypes = [NSMutableDictionary dictionary];
  _enumTypes = [NSMutableDictionary dictionary];
  _typeDefinitions = [NSMutableDictionary dictionary];
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
  if ([element isEqualToString:@"Edmx"]) {
    self.version = attributes[@"Version"];
  } else if ([element isEqualToString:@"Schema"]) {
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
    _complexType = [[ODataSchemaComplexType alloc] init];
    _complexType.name = attributes[@"Name"] ?: @"";
    _complexType.qualifiedName = [self qualify:_complexType.name];
    _complexType.baseType = attributes[@"BaseType"];
    _complexType.isAbstract = [attributes[@"Abstract"] isEqualToString:@"true"];
    _complexType.isOpen = [attributes[@"OpenType"] isEqualToString:@"true"];
    _properties = [NSMutableDictionary dictionary];
  } else if ([element isEqualToString:@"TypeDefinition"]) {
    if (attributes[@"Name"] && attributes[@"UnderlyingType"]) {
      _typeDefinitions[[self qualify:attributes[@"Name"]]] = attributes[@"UnderlyingType"];
    }
  } else if (_entityType && [element isEqualToString:@"Key"]) {
    _inKey = YES;
  } else if (_entityType && _inKey && [element isEqualToString:@"PropertyRef"]) {
    // A key in a complex property (Name="Address/Zip" Alias="Zip") is not
    // an attribute of its own; such a key is kept by its path.
    if (attributes[@"Name"]) [_key addObject:attributes[@"Name"]];
  } else if ((_entityType || _complexType) && [element isEqualToString:@"Property"]) {
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
  } else if ([element isEqualToString:@"Annotation"]) {
    // On the container, or in <Annotations Target="NS.Container">; the
    // term under any alias of Org.OData.Capabilities.V1. A tag: true
    // unless it says Bool="false".
    NSString *term = attributes[@"Term"] ?: @"";
    if ([term hasSuffix:@".KeyAsSegmentSupported"] && ![attributes[@"Bool"] isEqualToString:@"false"]) {
      self.keyAsSegmentSupported = YES;
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
  if ([element isEqualToString:@"ComplexType"] && _complexType) {
    _complexType.declaredProperties = _properties;
    _complexTypes[_complexType.qualifiedName] = _complexType;
    _complexType = nil;
  } else if ([element isEqualToString:@"EntityType"] && _entityType) {
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
  NSMutableDictionary *definitions = [NSMutableDictionary dictionary];
  for (NSString *name in reader.typeDefinitions) {
    definitions[[schema qualifiedName:name]] = [schema qualifiedName:reader.typeDefinitions[name]];
  }
  // Qualified, and a type definition as its underlying type.
  void (^qualify)(ODataSchemaProperty *) = ^(ODataSchemaProperty *property) {
    NSString *element = [schema qualifiedName:property.elementType];
    element = definitions[element] ?: element;
    property.type = property.isCollection ? [NSString stringWithFormat:@"Collection(%@)", element] : element;
  };
  for (ODataSchemaEntityType *type in reader.entityTypes.allValues) {
    if (type.baseType) type.baseType = [schema qualifiedName:type.baseType];
    for (ODataSchemaNavigationProperty *navigation in type.declaredNavigationProperties.allValues) {
      navigation.type = [schema qualifiedName:navigation.type];
    }
    for (ODataSchemaProperty *property in type.declaredProperties.allValues) qualify(property);
  }
  for (ODataSchemaComplexType *type in reader.complexTypes.allValues) {
    if (type.baseType) type.baseType = [schema qualifiedName:type.baseType];
    for (ODataSchemaProperty *property in type.declaredProperties.allValues) qualify(property);
  }
  schema->_entityTypes = [reader.entityTypes copy];
  schema->_complexTypes = [reader.complexTypes copy];
  schema->_enumTypes = [reader.enumTypes copy];
  schema->_entitySets = [sets copy];
  schema->_keyAsSegmentSupported = reader.keyAsSegmentSupported;
  schema->_version = [reader.version copy] ?: @"4.0";
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

- (ODataSchemaComplexType *)complexTypeNamed:(NSString *)name
{
  if (!name) return nil;
  return self.complexTypes[[self qualifiedName:name]];
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

- (ODataSchemaProperty *)property:(NSString *)name ofComplexType:(ODataSchemaComplexType *)type
{
  NSUInteger depth = 0;  // a base type cycle ends somewhere
  for (ODataSchemaComplexType *t = type; t && depth < 64; t = t.baseType ? self.complexTypes[t.baseType] : nil, depth++) {
    ODataSchemaProperty *property = t.declaredProperties[name];
    if (property) return property;
  }
  return nil;
}

- (NSDictionary *)propertiesOfComplexType:(ODataSchemaComplexType *)type
{
  NSMutableArray *chain = [NSMutableArray array];
  for (ODataSchemaComplexType *t = type; t && chain.count < 64; t = t.baseType ? self.complexTypes[t.baseType] : nil) {
    [chain insertObject:t atIndex:0];
  }
  NSMutableDictionary *all = [NSMutableDictionary dictionary];
  for (ODataSchemaComplexType *t in chain) [all addEntriesFromDictionary:t.declaredProperties];
  return all;
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
