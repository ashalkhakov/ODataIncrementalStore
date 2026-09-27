// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataMetadataWriter.h"
#import "ODataValue.h"

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

@interface ODataMetadataWriter ()
// The vocabularies the document's annotations use, to reference.
@property (nonatomic, strong) NSMutableSet<NSString *> *vocabularies;
@end

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

#pragma mark - Annotations


static NSString * const OISCore = @"Org.OData.Core.V1";
static NSString * const OISValidation = @"Org.OData.Validation.V1";

static BOOL OISIsTrue(id value)
{
  return [value respondsToSelector:@selector(boolValue)] && [value boolValue];
}

// A JSON CSDL value as a CSDL XML expression.
- (NSString *)expressionXML:(id)value
{
  if (!value || value == [NSNull null]) return @"<Null/>";
  if ([value isKindOfClass:[@YES class]]) return [value boolValue] ? @"<Bool>true</Bool>" : @"<Bool>false</Bool>";
  if ([value isKindOfClass:[NSDecimalNumber class]]) return [NSString stringWithFormat:@"<Decimal>%@</Decimal>", [value stringValue]];
  if ([value isKindOfClass:[NSNumber class]]) {
    const char *type = [value objCType];
    BOOL real = type && (type[0] == 'd' || type[0] == 'f');
    return real ? [NSString stringWithFormat:@"<Float>%.17g</Float>", [value doubleValue]]
                : [NSString stringWithFormat:@"<Int>%lld</Int>", [value longLongValue]];
  }
  if ([value isKindOfClass:[NSDate class]]) {
    return [NSString stringWithFormat:@"<DateTimeOffset>%@</DateTimeOffset>", ODataDateTimeOffsetString(value)];
  }
  if ([value isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"<String>%@</String>", OISXML(value)];
  if ([value isKindOfClass:[NSArray class]]) {
    NSMutableString *xml = [NSMutableString stringWithString:@"<Collection>"];
    for (id item in value) [xml appendString:[self expressionXML:item]];
    [xml appendString:@"</Collection>"];
    return xml;
  }
  if ([value isKindOfClass:[NSDictionary class]]) {
    NSDictionary *dictionary = value;
    // {"$Path": "..."}, {"$EnumMember": "..."}, {"$If": [...]}: an
    // expression, its other $ members its attributes.
    NSString *expression = nil;
    for (NSString *key in dictionary) {
      if ([key hasPrefix:@"$"] && ([dictionary[key] isKindOfClass:[NSArray class]] || [dictionary[key] isKindOfClass:[NSString class]])) {
        if (!expression || [dictionary[key] isKindOfClass:[NSArray class]]) expression = key;
      }
    }
    if (expression) {
      NSString *element = [expression substringFromIndex:1];
      id operand = dictionary[expression];
      NSMutableString *xml = [NSMutableString stringWithFormat:@"<%@", element];
      for (NSString *key in [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([key isEqualToString:expression] || ![key hasPrefix:@"$"]) continue;
        [xml appendFormat:@" %@=\"%@\"", [key substringFromIndex:1], OISXML([dictionary[key] description])];
      }
      [xml appendString:@">"];
      if ([operand isKindOfClass:[NSArray class]]) {
        for (id item in operand) [xml appendString:[self expressionXML:item]];
      } else {
        [xml appendString:OISXML(operand)];
      }
      [xml appendFormat:@"</%@>", element];
      return xml;
    }
    NSMutableString *xml = [NSMutableString stringWithString:@"<Record"];
    if ([dictionary[@"@type"] isKindOfClass:[NSString class]]) {
      [xml appendFormat:@" Type=\"%@\"", OISXML(dictionary[@"@type"])];
      [self useTerm:dictionary[@"@type"]];
    }
    [xml appendString:@">"];
    for (NSString *key in [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if ([key hasPrefix:@"@"]) continue;
      [xml appendFormat:@"<PropertyValue Property=\"%@\">%@</PropertyValue>", OISXML(key), [self expressionXML:dictionary[key]]];
    }
    [xml appendString:@"</Record>"];
    return xml;
  }
  return [NSString stringWithFormat:@"<String>%@</String>", OISXML([value description])];
}

// A term's vocabulary, to reference.
- (void)useTerm:(NSString *)term
{
  NSRange dot = [term rangeOfString:@"." options:NSBackwardsSearch];
  if (dot.location != NSNotFound) [self.vocabularies addObject:[term substringToIndex:dot.location]];
}

// Annotations as XML: by term (Term#Qualifier), a term's own annotations
// after it (Term@Term), as JSON CSDL keys them.
- (NSString *)annotationsXML:(NSDictionary<NSString *, id> *)annotations
{
  NSMutableString *xml = [NSMutableString string];
  for (NSString *key in [annotations.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([key rangeOfString:@"@"].location != NSNotFound) continue;
    NSRange hash = [key rangeOfString:@"#"];
    NSString *term = hash.location == NSNotFound ? key : [key substringToIndex:hash.location];
    [self useTerm:term];
    [xml appendFormat:@"<Annotation Term=\"%@\"", OISXML(term)];
    if (hash.location != NSNotFound) [xml appendFormat:@" Qualifier=\"%@\"", OISXML([key substringFromIndex:hash.location + 1])];
    [xml appendString:@">"];
    [xml appendString:[self expressionXML:annotations[key]]];
    NSString *prefix = [key stringByAppendingString:@"@"];
    NSMutableDictionary *nested = [NSMutableDictionary dictionary];
    for (NSString *other in annotations) {
      if ([other hasPrefix:prefix]) nested[[other substringFromIndex:prefix.length]] = annotations[other];
    }
    if (nested.count) [xml appendString:[self annotationsXML:nested]];
    [xml appendString:@"</Annotation>"];
  }
  return xml;
}

// What userInfo says of an entity or a property: Core's description and
// flags, and anything in OData.annotations (a dictionary, or JSON of one).
- (NSMutableDictionary *)annotationsFromUserInfo:(NSDictionary *)userInfo
{
  NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
  NSString *description = userInfo[ODataUserInfoDescription];
  if ([description isKindOfClass:[NSString class]]) annotations[[OISCore stringByAppendingString:@".Description"]] = description;
  NSString *longDescription = userInfo[ODataUserInfoLongDescription];
  if ([longDescription isKindOfClass:[NSString class]]) annotations[[OISCore stringByAppendingString:@".LongDescription"]] = longDescription;
  if (OISIsTrue(userInfo[ODataUserInfoComputed])) annotations[[OISCore stringByAppendingString:@".Computed"]] = @YES;
  if (OISIsTrue(userInfo[ODataUserInfoImmutable])) annotations[[OISCore stringByAppendingString:@".Immutable"]] = @YES;
  NSString *permissions = userInfo[ODataUserInfoPermissions];
  if ([permissions isKindOfClass:[NSString class]]) {
    annotations[[OISCore stringByAppendingString:@".Permissions"]] = @{ @"$EnumMember": [NSString stringWithFormat:@"Org.OData.Core.V1.Permission/%@", permissions] };
  }
  id more = userInfo[ODataUserInfoAnnotations];
  if ([more isKindOfClass:[NSString class]]) {
    more = [NSJSONSerialization JSONObjectWithData:[more dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
  }
  if ([more isKindOfClass:[NSDictionary class]]) {
    for (NSString *term in more) annotations[[self fullTerm:term]] = more[term];
  }
  return annotations;
}

// Core.Description as Org.OData.Core.V1.Description; a term of a namespace
// of its own as it is.
- (NSString *)fullTerm:(NSString *)term
{
  return [[self class] fullTerm:term];
}

+ (NSString *)fullTerm:(NSString *)term
{
  NSArray *parts = [term componentsSeparatedByString:@"@"];
  NSMutableArray *full = [NSMutableArray array];
  for (NSString *part in parts) {
    NSRange dot = [part rangeOfString:@"."];
    NSString *head = dot.location == NSNotFound ? nil : [part substringToIndex:dot.location];
    BOOL standard = head && [@[ @"Core", @"Validation", @"Capabilities", @"Authorization", @"Measures" ] containsObject:head] &&
                    [[part substringFromIndex:dot.location + 1] rangeOfString:@"."].location == NSNotFound;
    [full addObject:standard ? [NSString stringWithFormat:@"Org.OData.%@.V1%@", head, [part substringFromIndex:dot.location]] : part];
  }
  return [full componentsJoinedByString:@"@"];
}

// An attribute's: Computed for a derived one, or the version the service
// increments; Validation from the model's own validation predicates (as
// Xcode and FreeCoreData's momc write a minimum, a maximum, a length, a
// pattern: SELF >= 1, length <= 50, SELF MATCHES "..."); then userInfo.
// The length is the property's MaxLength, not an annotation.
- (NSMutableDictionary *)annotationsOfAttribute:(NSAttributeDescription *)attribute maxLength:(NSNumber **)maxLength
{
  NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
  Class derived = NSClassFromString(@"NSDerivedAttributeDescription");
  BOOL version = [[self.concurrencyAttributes allValues] containsObject:attribute];
  if ((derived && [attribute isKindOfClass:derived]) || version) annotations[[OISCore stringByAppendingString:@".Computed"]] = @YES;
  NSString *minimum = [OISValidation stringByAppendingString:@".Minimum"];
  NSString *maximum = [OISValidation stringByAppendingString:@".Maximum"];
  NSString *exclusive = [OISValidation stringByAppendingString:@".Exclusive"];
  for (NSPredicate *predicate in attribute.validationPredicates) {
    if (![predicate isKindOfClass:[NSComparisonPredicate class]]) continue;
    NSComparisonPredicate *comparison = (NSComparisonPredicate *)predicate;
    NSExpression *left = comparison.leftExpression, *right = comparison.rightExpression;
    if (right.expressionType != NSConstantValueExpressionType) continue;
    id constant = right.constantValue;
    NSString *keyPath = left.expressionType == NSKeyPathExpressionType ? left.keyPath : nil;
    BOOL itself = left.expressionType == NSEvaluatedObjectExpressionType || [keyPath isEqualToString:@"self"] || [keyPath isEqualToString:@"SELF"];
    if ([keyPath isEqualToString:@"timeIntervalSinceReferenceDate"] && [constant isKindOfClass:[NSNumber class]]) {
      itself = YES;
      constant = [NSDate dateWithTimeIntervalSinceReferenceDate:[constant doubleValue]];
    }
    NSPredicateOperatorType type = comparison.predicateOperatorType;
    if ([keyPath isEqualToString:@"length"] && [constant isKindOfClass:[NSNumber class]]) {
      if (type == NSLessThanOrEqualToPredicateOperatorType && maxLength) *maxLength = constant;
      if (type == NSLessThanPredicateOperatorType && maxLength) *maxLength = @([constant longLongValue] - 1);
      continue;
    }
    if (!itself) continue;
    switch (type) {
      case NSGreaterThanOrEqualToPredicateOperatorType: annotations[minimum] = constant; break;
      case NSGreaterThanPredicateOperatorType:
        annotations[minimum] = constant;
        annotations[[NSString stringWithFormat:@"%@@%@", minimum, exclusive]] = @YES;
        break;
      case NSLessThanOrEqualToPredicateOperatorType: annotations[maximum] = constant; break;
      case NSLessThanPredicateOperatorType:
        annotations[maximum] = constant;
        annotations[[NSString stringWithFormat:@"%@@%@", maximum, exclusive]] = @YES;
        break;
      case NSMatchesPredicateOperatorType:
        // MATCHES is of the whole string.
        if ([constant isKindOfClass:[NSString class]]) {
          annotations[[OISValidation stringByAppendingString:@".Pattern"]] = [NSString stringWithFormat:@"^(?:%@)$", constant];
        }
        break;
      case NSInPredicateOperatorType: {
        id values = [constant isKindOfClass:[NSSet class]] ? [constant allObjects] : constant;
        if (![values isKindOfClass:[NSArray class]]) break;
        NSMutableArray *allowed = [NSMutableArray array];
        for (id value in values) [allowed addObject:@{ @"Value": value }];
        annotations[[OISValidation stringByAppendingString:@".AllowedValues"]] = allowed;
        break;
      }
      default:
        break;
    }
  }
  [annotations addEntriesFromDictionary:[self annotationsFromUserInfo:attribute.userInfo]];
  return annotations;
}

- (NSMutableDictionary *)annotationsOfRelationship:(NSRelationshipDescription *)relationship
{
  NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
  if (relationship.isToMany && relationship.minCount > 0) annotations[[OISValidation stringByAppendingString:@".MinItems"]] = @(relationship.minCount);
  if (relationship.isToMany && relationship.maxCount > 0) annotations[[OISValidation stringByAppendingString:@".MaxItems"]] = @(relationship.maxCount);
  [annotations addEntriesFromDictionary:[self annotationsFromUserInfo:relationship.userInfo]];
  return annotations;
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
  return [self propertyXML:name type:type nullable:nullable maxLength:nil annotations:nil];
}

- (NSString *)propertyXML:(NSString *)name type:(NSString *)type nullable:(BOOL)nullable
                maxLength:(NSNumber *)maxLength annotations:(NSDictionary *)annotations
{
  NSMutableString *xml = [NSMutableString stringWithFormat:@"<Property Name=\"%@\" Type=\"%@\"", OISXML(name), OISXML(type)];
  if (!nullable) [xml appendString:@" Nullable=\"false\""];
  if ([OISElementTypeOf(type) isEqualToString:@"Edm.Decimal"]) [xml appendString:@" Scale=\"variable\""];
  if (maxLength && [OISElementTypeOf(type) isEqualToString:@"Edm.String"]) [xml appendFormat:@" MaxLength=\"%lld\"", maxLength.longLongValue];
  if (!annotations.count) {
    [xml appendString:@"/>"];
    return xml;
  }
  [xml appendFormat:@">%@</Property>", [self annotationsXML:annotations]];
  return xml;
}

- (void)writeEntity:(NSEntityDescription *)entity into:(NSMutableDictionary *)schemas used:(NSMutableSet *)usedTypes
{
  NSString *qualified = [self typeNameForEntity:entity];
  NSMutableString *xml = [NSMutableString stringWithFormat:@"<EntityType Name=\"%@\"", OISXML(OISSimpleNameOf(qualified))];
  if (entity.superentity) [xml appendFormat:@" BaseType=\"%@\"", OISXML([self typeNameForEntity:entity.superentity])];
  if (entity.isAbstract) [xml appendString:@" Abstract=\"true\""];
  [xml appendString:@">"];
  [xml appendString:[self annotationsXML:[self annotationsFromUserInfo:entity.userInfo]]];

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
      NSNumber *maxLength = nil;
      NSDictionary *annotations = [self annotationsOfAttribute:attr maxLength:&maxLength];
      [xml appendString:[self propertyXML:[self.mapper propertyForAttribute:attr] type:type nullable:nullable
                                maxLength:maxLength annotations:annotations]];
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
      NSDictionary *annotations = [self annotationsOfRelationship:rel];
      if (annotations.count) {
        [xml appendFormat:@">%@</NavigationProperty>", [self annotationsXML:annotations]];
      } else {
        [xml appendString:@"/>"];
      }
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
    NSString *setName = [self.mapper entitySetForEntity:entity];
    NSMutableDictionary *annotations = [NSMutableDictionary dictionary];
    for (NSString *restriction in @[ @"Insert", @"Update", @"Delete" ]) {
      if (![self.restrictions[setName] containsObject:restriction]) continue;
      NSString *property = [@{ @"Insert": @"Insertable", @"Update": @"Updatable", @"Delete": @"Deletable" } objectForKey:restriction];
      annotations[[NSString stringWithFormat:@"Org.OData.Capabilities.V1.%@Restrictions", restriction]] = @{ property: @NO };
    }
    NSAttributeDescription *concurrency = self.concurrencyAttributes[entity.name];
    if (concurrency) {
      annotations[@"Org.OData.Core.V1.OptimisticConcurrency"] = @[ @{ @"$PropertyPath": [self.mapper propertyForAttribute:concurrency] } ];
    }
    [annotations addEntriesFromDictionary:self.entitySetAnnotations[setName] ?: @{}];
    [xml appendString:[self annotationsXML:annotations]];
    [xml appendString:@"</EntitySet>"];
  }
  if (self.additionalContainerXML) [xml appendString:self.additionalContainerXML];
  NSMutableDictionary *containerAnnotations = [NSMutableDictionary dictionary];
  // The versions the service speaks, which is how a 4.01 client learns it
  // may send 4.01 payloads (Part 1 section 13.3, item 16).
  containerAnnotations[[OISCore stringByAppendingString:@".ODataVersions"]] = @"4.0 4.01";
  for (NSString *term in self.containerAnnotations) containerAnnotations[[self fullTerm:term]] = self.containerAnnotations[term];
  [xml appendString:[self annotationsXML:containerAnnotations]];
  [xml appendString:@"</EntityContainer>"];
  return xml;
}

- (NSString *)XMLStringForVersion:(NSString *)version
{
  _problems = [NSMutableArray array];
  self.vocabularies = [NSMutableSet set];
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
  if (self.additionalSchemaXML) [self append:self.additionalSchemaXML toNamespace:self.namespaceName in:schemas];
  [self append:[self containerXML] toNamespace:self.namespaceName in:schemas];

  NSMutableString *xml = [NSMutableString stringWithString:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"];
  [xml appendFormat:@"<edmx:Edmx Version=\"%@\" xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\">", OISXML(version)];
  // The standard vocabularies used, each where OASIS publishes it.
  for (NSString *vocabulary in [self.vocabularies.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
    if (![vocabulary hasPrefix:@"Org.OData."] || ![vocabulary hasSuffix:@".V1"]) continue;
    NSString *alias = [[vocabulary substringFromIndex:10] stringByDeletingPathExtension];
    [xml appendFormat:@"<edmx:Reference Uri=\"https://oasis-tcs.github.io/odata-vocabularies/vocabularies/%@.xml\">"
                      @"<edmx:Include Namespace=\"%@\" Alias=\"%@\"/></edmx:Reference>", vocabulary, vocabulary, alias];
  }
  [xml appendString:@"<edmx:DataServices>"];
  for (NSString *ns in [schemas.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [xml appendFormat:@"<Schema Namespace=\"%@\" xmlns=\"http://docs.oasis-open.org/odata/ns/edm\">%@</Schema>", OISXML(ns), schemas[ns]];
  }
  [xml appendString:@"</edmx:DataServices></edmx:Edmx>"];
  return xml;
}

@end
