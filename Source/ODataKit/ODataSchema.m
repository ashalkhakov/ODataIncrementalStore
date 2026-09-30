// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSchema.h"
#import "ODataCSDL.h"
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

@implementation ODataSchemaParameter
@end

@implementation ODataSchemaOperation
- (ODataSchemaParameter *)bindingParameter
{
  return self.isBound ? self.parameters.firstObject : nil;
}
- (NSArray *)callerParameters
{
  if (!self.isBound || !self.parameters.count) return self.parameters;
  return [self.parameters subarrayWithRange:NSMakeRange(1, self.parameters.count - 1)];
}
@end

@implementation ODataSchemaOperationImport
@end

@implementation ODataSchemaAuthorization
- (BOOL)usesBearerToken
{
  if ([self.kind isEqualToString:@"Http"]) return [self.scheme caseInsensitiveCompare:@"bearer"] == NSOrderedSame;
  return [self.kind isEqualToString:@"OpenIDConnect"] || [self.kind hasPrefix:@"OAuth2"];
}

- (NSString *)description
{
  NSMutableString *text = [NSMutableString stringWithString:self.kind];
  if (self.issuerURL) [text appendFormat:@" (issuer %@)", self.issuerURL.absoluteString];
  if (self.scheme) [text appendFormat:@" (%@)", self.scheme];
  if (self.keyName) [text appendFormat:@" (%@ in the %@)", self.keyName, self.location ?: @"Header"];
  if (self.requiredScopes.count) [text appendFormat:@", scopes %@", [self.requiredScopes componentsJoinedByString:@" "]];
  return text;
}
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
@property (nonatomic, strong) NSMutableDictionary *operations;        // qualified name -> NSMutableArray
@property (nonatomic, strong) NSMutableDictionary *operationImports;  // name -> import
@property (nonatomic, strong) NSMutableDictionary *aliases;  // alias -> namespace
// Each annotation as written: @[ target, term (Term#Qualifier, and
// Outer@Inner for one of an annotation), value ], qualified once every
// alias is known.
@property (nonatomic, strong) NSMutableArray<NSArray *> *annotations;
@property (nonatomic, copy) NSString *containerName;
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
  ODataSchemaOperation *_operation;
  NSMutableArray *_parameters;
  NSMutableArray *_memberNames;
  NSMutableDictionary *_memberValues;
  BOOL _inKey;
  BOOL _inContainer;
  NSString *_container;        // qualified
  NSString *_member;           // the property, set or enum member annotations inside it are of
  NSString *_annotationsTarget;  // <Annotations Target="...">
  NSMutableArray<NSMutableDictionary *> *_frames;  // an annotation's expression, being read
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
  _operations = [NSMutableDictionary dictionary];
  _operationImports = [NSMutableDictionary dictionary];
  _aliases = [NSMutableDictionary dictionary];
  _annotations = [NSMutableArray array];
  _frames = [NSMutableArray array];
  return self;
}

#pragma mark Annotations

// What an inline annotation is of: the element it is in.
- (NSString *)currentTarget
{
  if (_annotationsTarget) return _annotationsTarget;
  NSString *owner = _entityType.qualifiedName ?: _complexType.qualifiedName ?: _enumType.qualifiedName ?: (_inContainer ? _container : nil);
  if (!owner) return nil;
  return _member ? [NSString stringWithFormat:@"%@/%@", owner, _member] : owner;
}

static NSSet *OISConstantExpressions(void)
{
  static NSSet *names;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    names = [NSSet setWithObjects:@"String", @"Bool", @"Int", @"Decimal", @"Float", @"Date", @"DateTimeOffset", @"Duration",
                                  @"Guid", @"TimeOfDay", @"Binary", @"EnumMember", @"Path", @"PropertyPath",
                                  @"NavigationPropertyPath", @"AnnotationPath", @"ModelElementPath", @"UrlRef", @"Null", nil];
  });
  return names;
}

// A constant as JSON CSDL writes it: a string, a number, a Boolean, an
// enumeration's member names (Core.Permission/Read Core.Permission/Write
// is "Read,Write"), a path as {"$Path": ...}.
static id OISConstant(NSString *kind, NSString *text)
{
  if ([kind isEqualToString:@"Bool"]) return @([text isEqualToString:@"true"]);
  if ([kind isEqualToString:@"Int"]) return @([text longLongValue]);
  if ([kind isEqualToString:@"Decimal"]) return [NSDecimalNumber decimalNumberWithString:text];
  if ([kind isEqualToString:@"Float"]) return @([text doubleValue]);
  if ([kind isEqualToString:@"Null"]) return [NSNull null];
  if ([kind isEqualToString:@"EnumMember"]) {
    NSMutableArray *members = [NSMutableArray array];
    for (NSString *part in [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
      if (!part.length) continue;
      NSRange slash = [part rangeOfString:@"/" options:NSBackwardsSearch];
      [members addObject:slash.location == NSNotFound ? part : [part substringFromIndex:slash.location + 1]];
    }
    return [members componentsJoinedByString:@","];
  }
  if ([@[ @"Path", @"PropertyPath", @"NavigationPropertyPath", @"AnnotationPath", @"ModelElementPath", @"UrlRef" ] containsObject:kind]) {
    return @{ [@"$" stringByAppendingString:kind]: text };
  }
  return text;
}

// An annotation's or a property value's value given as an attribute.
static id OISInlineValue(NSDictionary *attributes)
{
  for (NSString *kind in OISConstantExpressions()) {
    NSString *text = attributes[kind];
    if (text) return OISConstant(kind, text);
  }
  return nil;
}

- (void)startAnnotationElement:(NSString *)element attributes:(NSDictionary *)attributes
{
  NSMutableDictionary *frame = [@{ @"element": element, @"attributes": attributes ?: @{},
                                   @"children": [NSMutableArray array], @"text": [NSMutableString string] } mutableCopy];
  [_frames addObject:frame];
}

// The value of a frame now closed.
- (id)valueOfFrame:(NSDictionary *)frame
{
  NSString *element = frame[@"element"];
  NSDictionary *attributes = frame[@"attributes"];
  NSArray *children = frame[@"children"];
  if ([OISConstantExpressions() containsObject:element]) {
    return OISConstant(element, [frame[@"text"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
  }
  if ([element isEqualToString:@"Collection"]) return [children copy];
  if ([element isEqualToString:@"Record"]) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    if (attributes[@"Type"]) record[@"@type"] = attributes[@"Type"];
    for (id child in children) {
      if ([child isKindOfClass:[NSArray class]] && [child count] == 2) record[child[0]] = child[1];
    }
    return record;
  }
  if ([element isEqualToString:@"PropertyValue"]) {
    id value = OISInlineValue(attributes) ?: children.firstObject ?: @YES;
    return @[ attributes[@"Property"] ?: @"", value ];
  }
  // A dynamic expression: If, Eq, Not, Apply, Cast, IsOf, ... with its
  // operands, and its attributes (Apply's Function, Cast's Type).
  NSMutableDictionary *dynamic = [NSMutableDictionary dictionaryWithObject:[children copy] forKey:[@"$" stringByAppendingString:element]];
  for (NSString *name in attributes) dynamic[[@"$" stringByAppendingString:name]] = attributes[name];
  return dynamic;
}

- (void)endAnnotationElement
{
  NSMutableDictionary *frame = _frames.lastObject;
  [_frames removeLastObject];
  if ([frame[@"element"] isEqualToString:@"Annotation"]) {
    NSDictionary *attributes = frame[@"attributes"];
    NSString *term = attributes[@"Term"];
    NSArray *children = frame[@"children"];
    id value = OISInlineValue(attributes) ?: children.firstObject ?: @YES;  // a tag is true
    NSString *keyed = term;
    if ([attributes[@"Qualifier"] length]) keyed = [NSString stringWithFormat:@"%@#%@", term, attributes[@"Qualifier"]];
    if (_frames.count) {
      // An annotation of the annotation: Outer@Inner, as JSON CSDL keys
      // it. One of a record inside it is read past.
      NSMutableDictionary *parent = _frames.lastObject;
      if (term && [parent[@"element"] isEqualToString:@"Annotation"] && parent[@"target"]) {
        if (!parent[@"nested"]) parent[@"nested"] = [NSMutableArray array];
        [parent[@"nested"] addObject:@[ keyed, value ]];
      }
      return;
    }
    NSString *target = frame[@"target"];
    if (!target || !term) return;
    [self.annotations addObject:@[ target, keyed, value ]];
    for (NSArray *nested in frame[@"nested"]) {
      [self.annotations addObject:@[ target, [NSString stringWithFormat:@"%@@%@", keyed, nested[0]], nested[1] ]];
    }
    return;
  }
  id value = [self valueOfFrame:frame];
  NSMutableDictionary *parent = _frames.lastObject;
  if (parent && value) [parent[@"children"] addObject:value];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
  NSMutableDictionary *frame = _frames.lastObject;
  if (frame) [frame[@"text"] appendString:string];
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
  if (_frames.count) {
    [self startAnnotationElement:element attributes:attributes];
    return;
  }
  if ([element isEqualToString:@"Annotation"]) {
    [self startAnnotationElement:element attributes:attributes];
    NSString *target = [self currentTarget];
    if (target) _frames.lastObject[@"target"] = target;
    return;
  }
  if ([element isEqualToString:@"Edmx"]) {
    self.version = attributes[@"Version"];
  } else if ([element isEqualToString:@"Include"]) {
    // <edmx:Reference><edmx:Include Namespace="Org.OData.Core.V1" Alias="Core"/>
    if (attributes[@"Alias"] && attributes[@"Namespace"]) _aliases[attributes[@"Alias"]] = attributes[@"Namespace"];
  } else if ([element isEqualToString:@"Annotations"]) {
    _annotationsTarget = attributes[@"Target"];
  } else if ([element isEqualToString:@"Schema"]) {
    _namespace = attributes[@"Namespace"];
    if (attributes[@"Alias"] && _namespace) _aliases[attributes[@"Alias"]] = _namespace;
  } else if ([element isEqualToString:@"EntityType"]) {
    _entityType = [[ODataSchemaEntityType alloc] init];
    _entityType.name = attributes[@"Name"] ?: @"";
    _entityType.qualifiedName = [self qualify:_entityType.name];
    _entityType.baseType = attributes[@"BaseType"];
    _entityType.isAbstract = [attributes[@"Abstract"] isEqualToString:@"true"];
    _entityType.hasStream = [attributes[@"HasStream"] isEqualToString:@"true"];
    _entityType.isOpen = [attributes[@"OpenType"] isEqualToString:@"true"];
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
    NSString *maxLength = attributes[@"MaxLength"];
    if (maxLength.length && ![maxLength isEqualToString:@"max"]) property.maxLength = @([maxLength longLongValue]);
    _properties[property.name] = property;
    _member = property.name;
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
    _member = navigation.name;
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
      _member = name;
    }
  } else if ([element isEqualToString:@"Function"] || [element isEqualToString:@"Action"]) {
    _operation = [[ODataSchemaOperation alloc] init];
    _operation.name = attributes[@"Name"] ?: @"";
    _operation.qualifiedName = [self qualify:_operation.name];
    _operation.isAction = [element isEqualToString:@"Action"];
    _operation.isBound = [attributes[@"IsBound"] isEqualToString:@"true"];
    _operation.isComposable = [attributes[@"IsComposable"] isEqualToString:@"true"];
    _parameters = [NSMutableArray array];
  } else if (_operation && [element isEqualToString:@"Parameter"]) {
    ODataSchemaParameter *parameter = [[ODataSchemaParameter alloc] init];
    parameter.name = attributes[@"Name"] ?: @"";
    parameter.type = attributes[@"Type"] ?: @"Edm.String";
    parameter.nullable = ![attributes[@"Nullable"] isEqualToString:@"false"];
    [_parameters addObject:parameter];
  } else if (_operation && [element isEqualToString:@"ReturnType"]) {
    _operation.returnType = attributes[@"Type"];
  } else if (_inContainer && ([element isEqualToString:@"FunctionImport"] || [element isEqualToString:@"ActionImport"])) {
    ODataSchemaOperationImport *import = [[ODataSchemaOperationImport alloc] init];
    import.name = attributes[@"Name"] ?: @"";
    import.isAction = [element isEqualToString:@"ActionImport"];
    import.operation = (import.isAction ? attributes[@"Action"] : attributes[@"Function"]) ?: @"";
    import.entitySet = attributes[@"EntitySet"];
    if (import.name.length) _operationImports[import.name] = import;
  } else if ([element isEqualToString:@"EntityContainer"]) {
    _inContainer = YES;
    _container = [self qualify:attributes[@"Name"] ?: @""];
    self.containerName = _container;
  } else if (_inContainer && [element isEqualToString:@"EntitySet"]) {
    if (attributes[@"Name"] && attributes[@"EntityType"]) _entitySets[attributes[@"Name"]] = attributes[@"EntityType"];
    _member = attributes[@"Name"];
  } else if (_inContainer && [element isEqualToString:@"Singleton"]) {
    _member = attributes[@"Name"];
  }
}

- (void)parser:(NSXMLParser *)parser
    didEndElement:(NSString *)elementName
     namespaceURI:(NSString *)namespaceURI
    qualifiedName:(NSString *)qName
{
  NSString *element = OISLocalName(elementName);
  if (_frames.count) {
    [self endAnnotationElement];
    return;
  }
  if ([@[ @"Property", @"NavigationProperty", @"EntitySet", @"Singleton", @"Member" ] containsObject:element]) {
    _member = nil;
  } else if ([element isEqualToString:@"Annotations"]) {
    _annotationsTarget = nil;
  }
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
  } else if (([element isEqualToString:@"Function"] || [element isEqualToString:@"Action"]) && _operation) {
    _operation.parameters = _parameters;
    NSMutableArray *overloads = _operations[_operation.qualifiedName];
    if (!overloads) _operations[_operation.qualifiedName] = overloads = [NSMutableArray array];
    [overloads addObject:_operation];
    _operation = nil;
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

// The standard vocabularies' namespaces, by the names they go by.
static NSDictionary<NSString *, NSString *> *OISStandardVocabularies(void)
{
  static NSDictionary *vocabularies;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    for (NSString *name in @[ @"Core", @"Capabilities", @"Validation", @"Authorization", @"Measures", @"Aggregation",
                              @"Temporal", @"JSON", @"Repeatability" ]) {
      all[name] = [NSString stringWithFormat:@"Org.OData.%@.V1", name];
    }
    vocabularies = all;
  });
  return vocabularies;
}

+ (instancetype)schemaWithData:(NSData *)csdl error:(NSError **)error
{
  // CSDL JSON (4.01) is read as the CSDL XML it says the same as.
  const char *bytes = csdl.bytes;
  NSUInteger at = 0;
  while (at < csdl.length && (bytes[at] == ' ' || bytes[at] == '\n' || bytes[at] == '\r' || bytes[at] == '\t')) at++;
  if (at < csdl.length && bytes[at] == '{') {
    csdl = [ODataCSDL XMLDataForJSONData:csdl error:error];
    if (!csdl) return nil;
  }
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
  // Parameters and return types are typed as properties are.
  NSString * (^qualifyType)(NSString *) = ^NSString *(NSString *type) {
    ODataSchemaProperty *p = [[ODataSchemaProperty alloc] init];
    p.type = type;
    qualify(p);
    return p.type;
  };
  NSMutableDictionary *operations = [NSMutableDictionary dictionary];
  for (NSString *name in reader.operations) {
    for (ODataSchemaOperation *operation in reader.operations[name]) {
      for (ODataSchemaParameter *parameter in operation.parameters) parameter.type = qualifyType(parameter.type);
      if (operation.returnType) operation.returnType = qualifyType(operation.returnType);
    }
    operations[name] = [reader.operations[name] copy];
  }
  for (ODataSchemaOperationImport *import in reader.operationImports.allValues) {
    import.operation = [schema qualifiedName:import.operation];
  }
  schema->_operations = [operations copy];
  schema->_operationImports = [reader.operationImports copy];
  schema->_entityTypes = [reader.entityTypes copy];
  schema->_complexTypes = [reader.complexTypes copy];
  schema->_enumTypes = [reader.enumTypes copy];
  schema->_entitySets = [sets copy];
  NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
  for (NSArray *annotation in reader.annotations) {
    NSString *target = [schema qualifiedTarget:annotation[0]];
    NSString *term = [schema qualifiedTerm:annotation[1]];
    NSMutableDictionary *terms = annotations[target];
    if (!terms) annotations[target] = terms = [NSMutableDictionary dictionary];
    terms[term] = annotation[2];
  }
  schema->_annotations = [annotations copy];
  schema->_containerName = [reader.containerName copy];
  schema->_authorizations = [schema readAuthorizations];
  // Capabilities.KeyAsSegmentSupported, on the container.
  for (NSString *target in annotations) {
    id value = annotations[target][@"Org.OData.Capabilities.V1.KeyAsSegmentSupported"];
    if ([value isEqual:@YES] && [target rangeOfString:@"/"].location == NSNotFound) schema->_keyAsSegmentSupported = YES;
  }
  schema->_version = [reader.version copy] ?: @"4.0";
  // Core.ODataVersions on the container, when there is one, is what the
  // service says it speaks (Part 1 section 13.3, item 16): its highest.
  id advertised = schema.containerName ? [schema annotation:@"Core.ODataVersions" forTarget:schema.containerName] : nil;
  if ([advertised isKindOfClass:[NSString class]]) {
    NSString *highest = nil;
    for (NSString *v in [advertised componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
      if (v.length && (!highest || [v compare:highest options:NSNumericSearch] == NSOrderedDescending)) highest = v;
    }
    if (highest) schema->_version = [highest copy];
  }
  return schema;
}

// A target: its first segment qualified (Self.Product/Name is
// NS.Product/Name).
- (NSString *)qualifiedTarget:(NSString *)target
{
  NSRange slash = [target rangeOfString:@"/"];
  NSString *head = slash.location == NSNotFound ? target : [target substringToIndex:slash.location];
  NSRange paren = [head rangeOfString:@"("];
  NSString *name = paren.location == NSNotFound ? head : [head substringToIndex:paren.location];
  NSString *qualified = [self qualifiedName:name];
  return [qualified stringByAppendingString:[target substringFromIndex:name.length]];
}

- (NSString *)qualifiedTerm:(NSString *)term
{
  if ([term rangeOfString:@"@"].location != NSNotFound) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *part in [term componentsSeparatedByString:@"@"]) [parts addObject:[self qualifiedTerm:part]];
    return [parts componentsJoinedByString:@"@"];
  }
  NSRange hash = [term rangeOfString:@"#"];
  NSString *name = hash.location == NSNotFound ? term : [term substringToIndex:hash.location];
  NSString *qualifier = hash.location == NSNotFound ? @"" : [term substringFromIndex:hash.location];
  NSString *qualified = [self qualifiedName:name];
  if ([qualified isEqualToString:name]) {
    NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
    NSString *vocabulary = dot.location == NSNotFound ? nil : OISStandardVocabularies()[[name substringToIndex:dot.location]];
    if (vocabulary) qualified = [vocabulary stringByAppendingString:[name substringFromIndex:dot.location]];
  }
  return [qualified stringByAppendingString:qualifier];
}

- (NSDictionary<NSString *, id> *)annotationsForTarget:(NSString *)target
{
  return self.annotations[[self qualifiedTarget:target]] ?: @{};
}

- (id)annotation:(NSString *)term forTarget:(NSString *)target
{
  return [self annotationsForTarget:target][[self qualifiedTerm:term]];
}

- (NSArray *)readAuthorizations
{
  if (!self.containerName) return @[];
  NSArray *declared = [self annotation:@"Authorization.Authorizations" forTarget:self.containerName];
  if (![declared isKindOfClass:[NSArray class]]) return @[];
  NSMutableDictionary *byName = [NSMutableDictionary dictionary];
  NSMutableArray *order = [NSMutableArray array];
  for (NSDictionary *record in declared) {
    if (![record isKindOfClass:[NSDictionary class]]) continue;
    ODataSchemaAuthorization *authorization = [[ODataSchemaAuthorization alloc] init];
    NSString *type = [record[@"@type"] isKindOfClass:[NSString class]] ? record[@"@type"] : @"";
    authorization.kind = [type componentsSeparatedByString:@"."].lastObject;
    authorization.name = [record[@"Name"] isKindOfClass:[NSString class]] ? record[@"Name"] : authorization.kind;
    authorization.text = [record[@"Description"] isKindOfClass:[NSString class]] ? record[@"Description"] : nil;
    NSURL * (^url)(NSString *) = ^NSURL *(NSString *key) {
      return [record[key] isKindOfClass:[NSString class]] ? [NSURL URLWithString:record[key]] : nil;
    };
    authorization.issuerURL = url(@"IssuerUrl");
    authorization.tokenURL = url(@"TokenUrl");
    authorization.authorizationURL = url(@"AuthorizationUrl");
    authorization.scheme = [record[@"Scheme"] isKindOfClass:[NSString class]] ? record[@"Scheme"] : nil;
    authorization.keyName = [record[@"KeyName"] isKindOfClass:[NSString class]] ? record[@"KeyName"] : nil;
    id location = record[@"Location"];
    if ([location isKindOfClass:[NSDictionary class]]) location = [[location[@"$EnumMember"] description] componentsSeparatedByString:@"/"].lastObject;
    authorization.location = [location isKindOfClass:[NSString class]] ? location : nil;
    authorization.requiredScopes = @[];
    byName[authorization.name] = authorization;
    [order addObject:authorization];
  }
  NSMutableArray *ordered = [NSMutableArray array];
  NSArray *schemes = [self annotation:@"Authorization.SecuritySchemes" forTarget:self.containerName];
  for (NSDictionary *scheme in [schemes isKindOfClass:[NSArray class]] ? schemes : @[]) {
    ODataSchemaAuthorization *authorization = [scheme isKindOfClass:[NSDictionary class]] ? byName[scheme[@"Authorization"]] : nil;
    if (!authorization || [ordered containsObject:authorization]) continue;
    id scopes = scheme[@"RequiredScopes"];
    authorization.requiredScopes = [scopes isKindOfClass:[NSArray class]] ? scopes : @[];
    [ordered addObject:authorization];
  }
  for (ODataSchemaAuthorization *authorization in order) {
    if (![ordered containsObject:authorization]) [ordered addObject:authorization];
  }
  return ordered;
}

- (id)capability:(NSString *)term forEntitySet:(NSString *)set
{
  if (!self.containerName) return nil;
  id value = set ? [self annotation:term forTarget:[NSString stringWithFormat:@"%@/%@", self.containerName, set]] : nil;
  return value ?: [self annotation:term forTarget:self.containerName];
}

- (id)annotation:(NSString *)term forProperty:(NSString *)name ofEntityType:(ODataSchemaEntityType *)type
{
  for (ODataSchemaEntityType *t = type; t; t = t.baseType ? [self entityTypeNamed:t.baseType] : nil) {
    id value = [self annotation:term forTarget:[NSString stringWithFormat:@"%@/%@", t.qualifiedName, name]];
    if (value) return value;
  }
  return nil;
}

- (NSString *)qualifiedName:(NSString *)name
{
  NSRange dot = [name rangeOfString:@"." options:NSBackwardsSearch];
  if (dot.location == NSNotFound) return name;
  NSString *prefix = [name substringToIndex:dot.location];
  NSString *namespace = _aliases[prefix];
  return namespace ? [NSString stringWithFormat:@"%@%@", namespace, [name substringFromIndex:dot.location]] : name;
}

NSString *ODataSchemaSpelling(NSString *name, id<NSFastEnumeration> _Nullable names)
{
  if (!name) return name;
  NSString *found = nil;
  for (NSString *candidate in names) {
    if ([candidate isEqualToString:name]) return name;
    if (!found && [candidate caseInsensitiveCompare:name] == NSOrderedSame) found = candidate;
  }
  return found ?: name;
}

- (ODataSchemaEntityType *)entityTypeNamed:(NSString *)name
{
  if (!name) return nil;
  return self.entityTypes[ODataSchemaSpelling([self qualifiedName:name], self.entityTypes)];
}

- (ODataSchemaComplexType *)complexTypeNamed:(NSString *)name
{
  if (!name) return nil;
  return self.complexTypes[ODataSchemaSpelling([self qualifiedName:name], self.complexTypes)];
}

- (ODataSchemaEnumType *)enumTypeNamed:(NSString *)name
{
  if (!name) return nil;
  return self.enumTypes[ODataSchemaSpelling([self qualifiedName:name], self.enumTypes)];
}

- (BOOL)entityTypeHasStream:(ODataSchemaEntityType *)type
{
  for (ODataSchemaEntityType *t = type; t; t = t.baseType ? [self entityTypeNamed:t.baseType] : nil) {
    if (t.hasStream) return YES;
  }
  return NO;
}

- (BOOL)entityTypeIsOpen:(ODataSchemaEntityType *)type
{
  for (ODataSchemaEntityType *t = type; t; t = t.baseType ? [self entityTypeNamed:t.baseType] : nil) {
    if (t.isOpen) return YES;
  }
  return NO;
}

- (NSArray<NSString *> *)streamPropertiesOfEntityType:(ODataSchemaEntityType *)type
{
  NSMutableArray *names = [NSMutableArray array];
  for (ODataSchemaEntityType *t = type; t; t = t.baseType ? [self entityTypeNamed:t.baseType] : nil) {
    for (NSString *name in t.declaredProperties) {
      if ([t.declaredProperties[name].type isEqualToString:@"Edm.Stream"]) [names addObject:name];
    }
  }
  return [names sortedArrayUsingSelector:@selector(compare:)];
}

- (ODataSchemaEntityType *)entityTypeWithSimpleName:(NSString *)name
{
  ODataSchemaEntityType *found = nil;
  for (ODataSchemaEntityType *type in self.entityTypes.allValues) {
    if (![type.name isEqualToString:name]) continue;
    if (found) return nil;  // two namespaces with one name: ambiguous
    found = type;
  }
  if (found) return found;
  // Product for PRODUCT, when that is the only one.
  for (ODataSchemaEntityType *type in self.entityTypes.allValues) {
    if ([type.name caseInsensitiveCompare:name] != NSOrderedSame) continue;
    if (found) return nil;
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

#pragma mark - Operations

// Whether an operation's binding parameter takes this entity type (it or
// a base of it) or, with collection, a collection of them.
- (BOOL)operation:(ODataSchemaOperation *)operation binds:(ODataSchemaEntityType *)type collection:(BOOL)collection
{
  ODataSchemaParameter *binding = operation.bindingParameter;
  if (!binding) return NO;
  BOOL isCollection = [binding.type hasPrefix:@"Collection("] && [binding.type hasSuffix:@")"];
  if (isCollection != collection) return NO;
  NSString *bound = isCollection ? [binding.type substringWithRange:NSMakeRange(11, binding.type.length - 12)] : binding.type;
  ODataSchemaEntityType *boundType = self.entityTypes[bound];
  return boundType && [self entityType:type isOrDerivesFrom:boundType];
}

- (NSArray *)operationsBoundToEntityType:(ODataSchemaEntityType *)type collection:(BOOL)collection
{
  NSMutableArray *found = [NSMutableArray array];
  for (NSString *name in [self.operations.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    for (ODataSchemaOperation *operation in self.operations[name]) {
      if ([self operation:operation binds:type collection:collection]) [found addObject:operation];
    }
  }
  return found;
}

- (ODataSchemaOperation *)operationNamed:(NSString *)name
                       boundToEntityType:(ODataSchemaEntityType *)type
                              collection:(BOOL)collection
                          parameterNames:(NSSet *)names
{
  NSMutableArray *candidates = [NSMutableArray array];
  if (!type) {
    ODataSchemaOperationImport *import = self.operationImports[name];
    NSString *qualified = import ? import.operation : [self qualifiedName:name];
    for (ODataSchemaOperation *operation in self.operations[qualified]) {
      if (!operation.isBound) [candidates addObject:operation];
    }
  } else {
    BOOL qualified = [name rangeOfString:@"."].location != NSNotFound;
    NSString *wanted = qualified ? [self qualifiedName:name] : name;
    for (NSString *key in self.operations) {
      for (ODataSchemaOperation *operation in self.operations[key]) {
        if (![(qualified ? operation.qualifiedName : operation.name) isEqualToString:wanted]) continue;
        if ([self operation:operation binds:type collection:collection]) [candidates addObject:operation];
      }
    }
  }
  if (candidates.count <= 1) return candidates.firstObject;
  // Overloads: the one whose parameters are the names given; else the one
  // bound most closely (a derived type's own before its base's).
  for (ODataSchemaOperation *operation in candidates) {
    NSSet *own = [NSSet setWithArray:[operation.callerParameters valueForKey:@"name"]];
    if (names && [own isEqualToSet:names]) return operation;
  }
  for (ODataSchemaOperation *operation in candidates) {
    NSString *bound = operation.bindingParameter.type;
    if ([bound isEqualToString:type.qualifiedName] || [bound isEqualToString:[NSString stringWithFormat:@"Collection(%@)", type.qualifiedName]]) {
      return operation;
    }
  }
  return candidates.firstObject;
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
