// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataCSDL.h"
#import "ODataXML.h"
#import "ODataError.h"

static NSString * const OISEdmxNS = @"http://docs.oasis-open.org/odata/ns/edmx";
static NSString * const OISEdmNS = @"http://docs.oasis-open.org/odata/ns/edm";

// The expression elements with a value in an attribute of the same name
// (<Annotation Term="T" String="x"/>) or as their text.
static NSArray *OISConstants(void)
{
  return @[ @"String", @"Int", @"Float", @"Decimal", @"Bool", @"Date", @"DateTimeOffset", @"Duration",
            @"Guid", @"TimeOfDay", @"Binary", @"EnumMember" ];
}

static NSArray *OISPaths(void)
{
  return @[ @"Path", @"PropertyPath", @"NavigationPropertyPath", @"AnnotationPath", @"ModelElementPath" ];
}

static NSString *OISLocal(ODataXMLNode *node)
{
  NSString *name = node.localName ?: node.name;
  NSRange colon = [name rangeOfString:@":"];
  return colon.location == NSNotFound ? name : [name substringFromIndex:NSMaxRange(colon)];
}

static NSString *OISAttr(ODataXMLElement *e, NSString *name)
{
  return [e attributeForName:name].stringValue;
}

static NSArray<ODataXMLElement *> *OISChildren(ODataXMLElement *e)
{
  NSMutableArray *out = [NSMutableArray array];
  for (ODataXMLNode *child in e.children) if (child.kind == ODataXMLElementKind) [out addObject:child];
  return out;
}

static id OISNumber(NSString *text)
{
  if (!text) return nil;
  NSDecimalNumber *n = [NSDecimalNumber decimalNumberWithString:text];
  return [n isEqualToNumber:[NSDecimalNumber notANumber]] ? text : n;
}

@implementation ODataCSDL

#pragma mark - XML to JSON

// A constant as JSON has it: numbers and booleans as themselves, the rest
// as strings, an enumeration's members as their names ("Read,Write").
+ (id)constant:(NSString *)kind text:(NSString *)text
{
  if ([kind isEqualToString:@"Bool"]) return @([text isEqualToString:@"true"]);
  if ([kind isEqualToString:@"Int"] || [kind isEqualToString:@"Decimal"]) return OISNumber(text) ?: text;
  if ([kind isEqualToString:@"Float"]) {
    if ([@[ @"INF", @"-INF", @"NaN" ] containsObject:text]) return text;
    return @([text doubleValue]);
  }
  if ([kind isEqualToString:@"EnumMember"]) {
    NSMutableArray *members = [NSMutableArray array];
    for (NSString *member in [text componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
      if (!member.length) continue;
      NSRange slash = [member rangeOfString:@"/" options:NSBackwardsSearch];
      [members addObject:slash.location == NSNotFound ? member : [member substringFromIndex:NSMaxRange(slash)]];
    }
    return [members componentsJoinedByString:@","];
  }
  return text ?: @"";
}

+ (id)expression:(ODataXMLElement *)e
{
  NSString *kind = OISLocal(e);
  if ([kind isEqualToString:@"Null"]) return [NSNull null];
  if ([OISConstants() containsObject:kind]) return [self constant:kind text:e.stringValue];
  if ([OISPaths() containsObject:kind]) return @{ [@"$" stringByAppendingString:kind]: e.stringValue ?: @"" };
  if ([kind isEqualToString:@"Collection"]) {
    NSMutableArray *items = [NSMutableArray array];
    for (ODataXMLElement *child in OISChildren(e)) [items addObject:[self expression:child]];
    return items;
  }
  if ([kind isEqualToString:@"Record"]) {
    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    if (OISAttr(e, @"Type")) record[@"@type"] = [@"#" stringByAppendingString:OISAttr(e, @"Type")];
    for (ODataXMLElement *child in OISChildren(e)) {
      if ([OISLocal(child) isEqualToString:@"Annotation"]) {
        [self annotation:child into:record prefix:@""];
        continue;
      }
      NSString *property = OISAttr(child, @"Property");
      if (!property) continue;
      record[property] = [self annotationValue:child];
      for (ODataXMLElement *inner in OISChildren(child)) {
        if ([OISLocal(inner) isEqualToString:@"Annotation"]) [self annotation:inner into:record prefix:property];
      }
    }
    return record;
  }
  // A dynamic expression: $Kind with its operands, its attributes as $Attr.
  NSMutableDictionary *dynamic = [NSMutableDictionary dictionary];
  for (ODataXMLNode *attribute in e.attributes) dynamic[[@"$" stringByAppendingString:OISLocal(attribute)]] = attribute.stringValue;
  NSMutableArray *operands = [NSMutableArray array];
  for (ODataXMLElement *child in OISChildren(e)) {
    if ([OISLocal(child) isEqualToString:@"Annotation"]) [self annotation:child into:dynamic prefix:@""];
    else [operands addObject:[self expression:child]];
  }
  BOOL single = [@[ @"Not", @"Cast", @"IsOf", @"LabeledElement", @"UrlRef", @"Neg" ] containsObject:kind];
  if (!operands.count && e.stringValue.length) {
    dynamic[[@"$" stringByAppendingString:kind]] = e.stringValue;  // LabeledElementReference
  } else {
    dynamic[[@"$" stringByAppendingString:kind]] = single && operands.count == 1 ? operands.firstObject : operands;
  }
  // Apply's Function, Cast's Type: $Function, $Type.
  return dynamic;
}

// An annotation's (or a property value's) value: an attribute, or its one
// expression, or true for a tag.
+ (id)annotationValue:(ODataXMLElement *)e
{
  for (NSString *kind in OISConstants()) {
    NSString *text = OISAttr(e, kind);
    if (text) return [self constant:kind text:text];
  }
  for (NSString *kind in OISPaths()) {
    NSString *text = OISAttr(e, kind);
    if (text) return @{ [@"$" stringByAppendingString:kind]: text };
  }
  if (OISAttr(e, @"UrlRef")) return @{ @"$UrlRef": OISAttr(e, @"UrlRef") };
  for (ODataXMLElement *child in OISChildren(e)) {
    if (![OISLocal(child) isEqualToString:@"Annotation"]) return [self expression:child];
  }
  return @YES;
}

+ (void)annotation:(ODataXMLElement *)e into:(NSMutableDictionary *)into prefix:(NSString *)prefix
{
  NSString *key = [NSString stringWithFormat:@"%@@%@", prefix, OISAttr(e, @"Term")];
  if (OISAttr(e, @"Qualifier")) key = [NSString stringWithFormat:@"%@#%@", key, OISAttr(e, @"Qualifier")];
  into[key] = [self annotationValue:e];
  for (ODataXMLElement *inner in OISChildren(e)) {
    if ([OISLocal(inner) isEqualToString:@"Annotation"]) [self annotation:inner into:into prefix:key];
  }
}

+ (void)annotationsOf:(ODataXMLElement *)e into:(NSMutableDictionary *)into
{
  for (ODataXMLElement *child in OISChildren(e)) {
    if ([OISLocal(child) isEqualToString:@"Annotation"]) [self annotation:child into:into prefix:@""];
  }
}

// Type="Collection(NS.T)" Nullable= MaxLength= ...: $Type, $Collection,
// $Nullable (true only, the default being false), and the facets.
+ (void)typeOf:(ODataXMLElement *)e into:(NSMutableDictionary *)into nullableDefault:(BOOL)xmlDefault
{
  NSString *type = OISAttr(e, @"Type");
  if ([type hasPrefix:@"Collection("] && [type hasSuffix:@")"]) {
    into[@"$Collection"] = @YES;
    type = [type substringWithRange:NSMakeRange(11, type.length - 12)];
  }
  if (type && ![type isEqualToString:@"Edm.String"]) into[@"$Type"] = type;
  NSString *nullable = OISAttr(e, @"Nullable");
  BOOL isNullable = nullable ? [nullable isEqualToString:@"true"] : xmlDefault;
  if (isNullable) into[@"$Nullable"] = @YES;
  for (NSString *facet in @[ @"MaxLength", @"Precision", @"Scale", @"SRID" ]) {
    NSString *value = OISAttr(e, facet);
    if (value) into[[@"$" stringByAppendingString:facet]] = OISNumber(value) ?: value;
  }
  if ([OISAttr(e, @"Unicode") isEqualToString:@"false"]) into[@"$Unicode"] = @NO;
  if (OISAttr(e, @"DefaultValue")) into[@"$DefaultValue"] = OISAttr(e, @"DefaultValue");
}

+ (NSDictionary *)structured:(ODataXMLElement *)e kind:(NSString *)kind
{
  NSMutableDictionary *type = [NSMutableDictionary dictionaryWithObject:kind forKey:@"$Kind"];
  if (OISAttr(e, @"BaseType")) type[@"$BaseType"] = OISAttr(e, @"BaseType");
  for (NSString *flag in @[ @"Abstract", @"OpenType", @"HasStream" ]) {
    if ([OISAttr(e, flag) isEqualToString:@"true"]) type[[@"$" stringByAppendingString:flag]] = @YES;
  }
  for (ODataXMLElement *child in OISChildren(e)) {
    NSString *name = OISLocal(child);
    if ([name isEqualToString:@"Key"]) {
      NSMutableArray *key = [NSMutableArray array];
      for (ODataXMLElement *ref in OISChildren(child)) {
        NSString *alias = OISAttr(ref, @"Alias");
        [key addObject:alias ? @{ alias: OISAttr(ref, @"Name") } : OISAttr(ref, @"Name")];
      }
      type[@"$Key"] = key;
    } else if ([name isEqualToString:@"Property"]) {
      NSMutableDictionary *property = [NSMutableDictionary dictionary];
      [self typeOf:child into:property nullableDefault:YES];
      [self annotationsOf:child into:property];
      type[OISAttr(child, @"Name")] = property;
    } else if ([name isEqualToString:@"NavigationProperty"]) {
      NSMutableDictionary *navigation = [NSMutableDictionary dictionaryWithObject:@"NavigationProperty" forKey:@"$Kind"];
      NSString *navigationType = OISAttr(child, @"Type");
      BOOL collection = [navigationType hasPrefix:@"Collection("];
      [self typeOf:child into:navigation nullableDefault:!collection];
      if (OISAttr(child, @"Partner")) navigation[@"$Partner"] = OISAttr(child, @"Partner");
      if ([OISAttr(child, @"ContainsTarget") isEqualToString:@"true"]) navigation[@"$ContainsTarget"] = @YES;
      NSMutableDictionary *constraints = [NSMutableDictionary dictionary];
      for (ODataXMLElement *inner in OISChildren(child)) {
        if ([OISLocal(inner) isEqualToString:@"ReferentialConstraint"]) constraints[OISAttr(inner, @"Property")] = OISAttr(inner, @"ReferencedProperty");
        if ([OISLocal(inner) isEqualToString:@"OnDelete"]) navigation[@"$OnDelete"] = OISAttr(inner, @"Action");
      }
      if (constraints.count) navigation[@"$ReferentialConstraint"] = constraints;
      [self annotationsOf:child into:navigation];
      type[OISAttr(child, @"Name")] = navigation;
    } else if ([name isEqualToString:@"Annotation"]) {
      [self annotation:child into:type prefix:@""];
    }
  }
  return type;
}

+ (NSDictionary *)operation:(ODataXMLElement *)e kind:(NSString *)kind
{
  NSMutableDictionary *operation = [NSMutableDictionary dictionaryWithObject:kind forKey:@"$Kind"];
  for (NSString *flag in @[ @"IsBound", @"IsComposable" ]) {
    if ([OISAttr(e, flag) isEqualToString:@"true"]) operation[[@"$" stringByAppendingString:flag]] = @YES;
  }
  if (OISAttr(e, @"EntitySetPath")) operation[@"$EntitySetPath"] = OISAttr(e, @"EntitySetPath");
  NSMutableArray *parameters = [NSMutableArray array];
  for (ODataXMLElement *child in OISChildren(e)) {
    NSString *name = OISLocal(child);
    if ([name isEqualToString:@"Parameter"]) {
      NSMutableDictionary *parameter = [NSMutableDictionary dictionaryWithObject:OISAttr(child, @"Name") forKey:@"$Name"];
      [self typeOf:child into:parameter nullableDefault:YES];
      [self annotationsOf:child into:parameter];
      [parameters addObject:parameter];
    } else if ([name isEqualToString:@"ReturnType"]) {
      NSMutableDictionary *returns = [NSMutableDictionary dictionary];
      [self typeOf:child into:returns nullableDefault:YES];
      [self annotationsOf:child into:returns];
      operation[@"$ReturnType"] = returns;
    } else if ([name isEqualToString:@"Annotation"]) {
      [self annotation:child into:operation prefix:@""];
    }
  }
  if (parameters.count) operation[@"$Parameter"] = parameters;
  return operation;
}

+ (NSDictionary *)container:(ODataXMLElement *)e
{
  NSMutableDictionary *container = [NSMutableDictionary dictionaryWithObject:@"EntityContainer" forKey:@"$Kind"];
  if (OISAttr(e, @"Extends")) container[@"$Extends"] = OISAttr(e, @"Extends");
  for (ODataXMLElement *child in OISChildren(e)) {
    NSString *name = OISLocal(child);
    if ([name isEqualToString:@"Annotation"]) {
      [self annotation:child into:container prefix:@""];
      continue;
    }
    NSMutableDictionary *member = [NSMutableDictionary dictionary];
    if ([name isEqualToString:@"EntitySet"]) {
      member[@"$Collection"] = @YES;
      member[@"$Type"] = OISAttr(child, @"EntityType");
      if ([OISAttr(child, @"IncludeInServiceDocument") isEqualToString:@"false"]) member[@"$IncludeInServiceDocument"] = @NO;
    } else if ([name isEqualToString:@"Singleton"]) {
      member[@"$Type"] = OISAttr(child, @"Type");
      if ([OISAttr(child, @"Nullable") isEqualToString:@"true"]) member[@"$Nullable"] = @YES;
    } else if ([name isEqualToString:@"ActionImport"] || [name isEqualToString:@"FunctionImport"]) {
      NSString *what = [name isEqualToString:@"ActionImport"] ? @"Action" : @"Function";
      member[[@"$" stringByAppendingString:what]] = OISAttr(child, what);
      if (OISAttr(child, @"EntitySet")) member[@"$EntitySet"] = OISAttr(child, @"EntitySet");
      if ([OISAttr(child, @"IncludeInServiceDocument") isEqualToString:@"true"]) member[@"$IncludeInServiceDocument"] = @YES;
    } else {
      continue;
    }
    NSMutableDictionary *bindings = [NSMutableDictionary dictionary];
    for (ODataXMLElement *inner in OISChildren(child)) {
      if ([OISLocal(inner) isEqualToString:@"NavigationPropertyBinding"]) bindings[OISAttr(inner, @"Path")] = OISAttr(inner, @"Target");
      else if ([OISLocal(inner) isEqualToString:@"Annotation"]) [self annotation:inner into:member prefix:@""];
    }
    if (bindings.count) member[@"$NavigationPropertyBinding"] = bindings;
    container[OISAttr(child, @"Name")] = member;
  }
  return container;
}

+ (NSData *)JSONDataForXMLData:(NSData *)xml error:(NSError **)error
{
  ODataXMLDocument *document = [[ODataXMLDocument alloc] initWithData:xml options:0 error:error];
  if (!document) return nil;
  ODataXMLElement *root = document.rootElement;
  NSMutableDictionary *json = [NSMutableDictionary dictionary];
  json[@"$Version"] = OISAttr(root, @"Version") ?: @"4.01";
  NSMutableDictionary *references = [NSMutableDictionary dictionary];
  for (ODataXMLElement *child in OISChildren(root)) {
    if ([OISLocal(child) isEqualToString:@"Reference"]) {
      NSMutableDictionary *reference = [NSMutableDictionary dictionary];
      for (ODataXMLElement *inner in OISChildren(child)) {
        NSString *kind = OISLocal(inner);
        if ([kind isEqualToString:@"Annotation"]) {
          [self annotation:inner into:reference prefix:@""];
          continue;
        }
        NSString *list = [kind isEqualToString:@"Include"] ? @"$Include" : [kind isEqualToString:@"IncludeAnnotations"] ? @"$IncludeAnnotations" : nil;
        if (!list) continue;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        for (ODataXMLNode *attribute in inner.attributes) entry[[@"$" stringByAppendingString:OISLocal(attribute)]] = attribute.stringValue;
        if (!reference[list]) reference[list] = [NSMutableArray array];
        [reference[list] addObject:entry];
      }
      references[OISAttr(child, @"Uri") ?: @""] = reference;
    }
    if (![OISLocal(child) isEqualToString:@"DataServices"]) continue;
    for (ODataXMLElement *schema in OISChildren(child)) {
      NSString *ns = OISAttr(schema, @"Namespace");
      NSMutableDictionary *body = [NSMutableDictionary dictionary];
      if (OISAttr(schema, @"Alias")) body[@"$Alias"] = OISAttr(schema, @"Alias");
      NSMutableDictionary *targeted = [NSMutableDictionary dictionary];
      for (ODataXMLElement *element in OISChildren(schema)) {
        NSString *kind = OISLocal(element);
        NSString *name = OISAttr(element, @"Name");
        if ([kind isEqualToString:@"EntityType"] || [kind isEqualToString:@"ComplexType"]) {
          body[name] = [self structured:element kind:kind];
        } else if ([kind isEqualToString:@"EnumType"]) {
          NSMutableDictionary *type = [NSMutableDictionary dictionaryWithObject:@"EnumType" forKey:@"$Kind"];
          if (OISAttr(element, @"UnderlyingType") && ![OISAttr(element, @"UnderlyingType") isEqualToString:@"Edm.Int32"]) type[@"$UnderlyingType"] = OISAttr(element, @"UnderlyingType");
          if ([OISAttr(element, @"IsFlags") isEqualToString:@"true"]) type[@"$IsFlags"] = @YES;
          long long next = 0;
          for (ODataXMLElement *member in OISChildren(element)) {
            if ([OISLocal(member) isEqualToString:@"Annotation"]) {
              [self annotation:member into:type prefix:@""];
              continue;
            }
            NSString *value = OISAttr(member, @"Value");
            long long v = value ? value.longLongValue : next;
            next = v + 1;
            type[OISAttr(member, @"Name")] = @(v);
            for (ODataXMLElement *inner in OISChildren(member)) {
              if ([OISLocal(inner) isEqualToString:@"Annotation"]) [self annotation:inner into:type prefix:OISAttr(member, @"Name")];
            }
          }
          body[name] = type;
        } else if ([kind isEqualToString:@"TypeDefinition"]) {
          NSMutableDictionary *type = [NSMutableDictionary dictionaryWithObject:@"TypeDefinition" forKey:@"$Kind"];
          type[@"$UnderlyingType"] = OISAttr(element, @"UnderlyingType") ?: @"Edm.String";
          for (NSString *facet in @[ @"MaxLength", @"Precision", @"Scale", @"SRID" ]) {
            if (OISAttr(element, facet)) type[[@"$" stringByAppendingString:facet]] = OISNumber(OISAttr(element, facet)) ?: OISAttr(element, facet);
          }
          [self annotationsOf:element into:type];
          body[name] = type;
        } else if ([kind isEqualToString:@"Term"]) {
          NSMutableDictionary *term = [NSMutableDictionary dictionaryWithObject:@"Term" forKey:@"$Kind"];
          [self typeOf:element into:term nullableDefault:YES];
          if (OISAttr(element, @"AppliesTo")) term[@"$AppliesTo"] = [OISAttr(element, @"AppliesTo") componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
          if (OISAttr(element, @"BaseTerm")) term[@"$BaseTerm"] = OISAttr(element, @"BaseTerm");
          [self annotationsOf:element into:term];
          body[name] = term;
        } else if ([kind isEqualToString:@"Action"] || [kind isEqualToString:@"Function"]) {
          if (![body[name] isKindOfClass:[NSMutableArray class]]) body[name] = [NSMutableArray array];
          [body[name] addObject:[self operation:element kind:kind]];
        } else if ([kind isEqualToString:@"EntityContainer"]) {
          body[name] = [self container:element];
          json[@"$EntityContainer"] = [NSString stringWithFormat:@"%@.%@", ns, name];
        } else if ([kind isEqualToString:@"Annotations"]) {
          NSString *target = OISAttr(element, @"Target");
          NSMutableDictionary *annotations = targeted[target] ?: [NSMutableDictionary dictionary];
          NSString *qualifier = OISAttr(element, @"Qualifier");
          for (ODataXMLElement *annotation in OISChildren(element)) {
            if (qualifier && !OISAttr(annotation, @"Qualifier")) [annotation addAttribute:[ODataXMLNode attributeWithName:@"Qualifier" stringValue:qualifier]];
            [self annotation:annotation into:annotations prefix:@""];
          }
          targeted[target] = annotations;
        } else if ([kind isEqualToString:@"Annotation"]) {
          [self annotation:element into:body prefix:@""];
        }
      }
      if (targeted.count) body[@"$Annotations"] = targeted;
      json[ns] = body;
    }
  }
  if (references.count) json[@"$Reference"] = references;
  return [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:error];
}

#pragma mark - JSON to XML

static ODataXMLElement *OISEl(NSString *name)
{
  return [[ODataXMLElement alloc] initWithName:name];
}

// JSON's true and false, as NSJSONSerialization reads them: the class of @YES.
static BOOL OISIsBool(id value)
{
  return [value isKindOfClass:[@YES class]];
}

static void OISSet(ODataXMLElement *e, NSString *name, id value)
{
  if (!value || value == [NSNull null]) return;
  NSString *text = OISIsBool(value) ? ([value boolValue] ? @"true" : @"false") : [value description];
  [e addAttribute:[ODataXMLNode attributeWithName:name stringValue:text]];
}

+ (ODataXMLElement *)expressionElement:(id)value
{
  if (!value || value == [NSNull null]) return OISEl(@"Null");
  if (OISIsBool(value)) {
    ODataXMLElement *e = OISEl(@"Bool");
    e.stringValue = [value boolValue] ? @"true" : @"false";
    return e;
  }
  if ([value isKindOfClass:[NSNumber class]]) {
    NSNumber *n = value;
    BOOL whole = [n isKindOfClass:[NSDecimalNumber class]] ? [[(NSDecimalNumber *)n stringValue] rangeOfString:@"."].location == NSNotFound
                                                           : n.doubleValue == floor(n.doubleValue);
    ODataXMLElement *e = OISEl(whole ? @"Int" : @"Decimal");
    e.stringValue = [n isKindOfClass:[NSDecimalNumber class]] ? [(NSDecimalNumber *)n stringValue] : n.stringValue;
    return e;
  }
  if ([value isKindOfClass:[NSString class]]) {
    ODataXMLElement *e = OISEl(@"String");
    e.stringValue = value;
    return e;
  }
  if ([value isKindOfClass:[NSArray class]]) {
    ODataXMLElement *e = OISEl(@"Collection");
    for (id item in value) [e addChild:[self expressionElement:item]];
    return e;
  }
  NSDictionary *dictionary = value;
  for (NSString *kind in [OISPaths() arrayByAddingObject:@"LabeledElementReference"]) {
    NSString *key = [@"$" stringByAppendingString:kind];
    if (dictionary[key]) {
      ODataXMLElement *e = OISEl(kind);
      e.stringValue = [dictionary[key] description];
      return e;
    }
  }
  // A dynamic expression: the $ member whose value is its operands.
  NSString *expression = nil;
  for (NSString *key in [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (![key hasPrefix:@"$"]) continue;
    if ([@[ @"$Type", @"$Function", @"$Name", @"$MaxLength", @"$Precision", @"$Scale", @"$SRID" ] containsObject:key]) continue;
    expression = key;
    break;
  }
  if (expression) {
    ODataXMLElement *e = OISEl([expression substringFromIndex:1]);
    for (NSString *key in [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if ([key hasPrefix:@"$"] && ![key isEqualToString:expression]) OISSet(e, [key substringFromIndex:1], dictionary[key]);
    }
    id operands = dictionary[expression];
    for (id operand in [operands isKindOfClass:[NSArray class]] ? operands : @[ operands ]) [e addChild:[self expressionElement:operand]];
    [self addAnnotations:dictionary to:e prefix:@""];
    return e;
  }
  ODataXMLElement *record = OISEl(@"Record");
  NSString *type = dictionary[@"@type"] ?: dictionary[@"@odata.type"];
  if (type) OISSet(record, @"Type", [type hasPrefix:@"#"] ? [type substringFromIndex:1] : type);
  for (NSString *key in [dictionary.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([key rangeOfString:@"@"].location != NSNotFound) continue;
    ODataXMLElement *propertyValue = OISEl(@"PropertyValue");
    OISSet(propertyValue, @"Property", key);
    [propertyValue addChild:[self expressionElement:dictionary[key]]];
    [self addAnnotations:dictionary to:propertyValue prefix:key];
    [record addChild:propertyValue];
  }
  [self addAnnotations:dictionary to:record prefix:@""];
  return record;
}

// The members prefix@Term(#Qualifier) of a JSON object, as Annotation
// elements, with their own (prefix@Term@Inner) inside.
+ (void)addAnnotations:(NSDictionary *)object to:(ODataXMLElement *)element prefix:(NSString *)prefix
{
  NSString *start = [prefix stringByAppendingString:@"@"];
  for (NSString *key in [object.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if (![key hasPrefix:start] || [key isEqualToString:@"@type"] || [key isEqualToString:@"@odata.type"]) continue;
    NSString *rest = [key substringFromIndex:start.length];
    if ([rest rangeOfString:@"@"].location != NSNotFound) continue;  // an annotation's annotation, inside it
    NSRange hash = [rest rangeOfString:@"#"];
    ODataXMLElement *annotation = OISEl(@"Annotation");
    OISSet(annotation, @"Term", hash.location == NSNotFound ? rest : [rest substringToIndex:hash.location]);
    if (hash.location != NSNotFound) OISSet(annotation, @"Qualifier", [rest substringFromIndex:NSMaxRange(hash)]);
    id value = object[key];
    if (!OISIsBool(value) || ![value boolValue]) [annotation addChild:[self expressionElement:value]];
    [self addAnnotations:object to:annotation prefix:key];
    [element addChild:annotation];
  }
}

+ (void)setType:(NSDictionary *)json on:(ODataXMLElement *)e nullableDefault:(BOOL)xmlDefault
{
  NSString *type = json[@"$Type"] ?: @"Edm.String";
  if ([json[@"$Collection"] boolValue]) type = [NSString stringWithFormat:@"Collection(%@)", type];
  OISSet(e, @"Type", type);
  BOOL nullable = [json[@"$Nullable"] boolValue];
  if (nullable != xmlDefault) OISSet(e, @"Nullable", nullable ? @"true" : @"false");
  for (NSString *facet in @[ @"MaxLength", @"Precision", @"Scale", @"SRID", @"DefaultValue" ]) OISSet(e, facet, json[[@"$" stringByAppendingString:facet]]);
  if (json[@"$Unicode"] && ![json[@"$Unicode"] boolValue]) OISSet(e, @"Unicode", @"false");
}

+ (ODataXMLElement *)structuredElement:(NSDictionary *)json name:(NSString *)name
{
  ODataXMLElement *e = OISEl(json[@"$Kind"]);
  OISSet(e, @"Name", name);
  OISSet(e, @"BaseType", json[@"$BaseType"]);
  for (NSString *flag in @[ @"Abstract", @"OpenType", @"HasStream" ]) {
    if ([json[[@"$" stringByAppendingString:flag]] boolValue]) OISSet(e, flag, @"true");
  }
  if ([json[@"$Key"] isKindOfClass:[NSArray class]]) {
    ODataXMLElement *key = OISEl(@"Key");
    for (id part in json[@"$Key"]) {
      ODataXMLElement *ref = OISEl(@"PropertyRef");
      if ([part isKindOfClass:[NSDictionary class]]) {
        NSString *alias = [part allKeys].firstObject;
        OISSet(ref, @"Name", part[alias]);
        OISSet(ref, @"Alias", alias);
      } else {
        OISSet(ref, @"Name", part);
      }
      [key addChild:ref];
    }
    [e addChild:key];
  }
  for (NSString *member in [json.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([member hasPrefix:@"$"] || [member rangeOfString:@"@"].location != NSNotFound) continue;
    NSDictionary *property = json[member];
    if (![property isKindOfClass:[NSDictionary class]]) continue;
    BOOL navigation = [property[@"$Kind"] isEqualToString:@"NavigationProperty"];
    ODataXMLElement *p = OISEl(navigation ? @"NavigationProperty" : @"Property");
    OISSet(p, @"Name", member);
    [self setType:property on:p nullableDefault:navigation ? ![property[@"$Collection"] boolValue] : YES];
    if (navigation) {
      OISSet(p, @"Partner", property[@"$Partner"]);
      if ([property[@"$ContainsTarget"] boolValue]) OISSet(p, @"ContainsTarget", @"true");
      NSDictionary *constraints = property[@"$ReferentialConstraint"];
      for (NSString *from in [constraints.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([from rangeOfString:@"@"].location != NSNotFound) continue;
        ODataXMLElement *constraint = OISEl(@"ReferentialConstraint");
        OISSet(constraint, @"Property", from);
        OISSet(constraint, @"ReferencedProperty", constraints[from]);
        [p addChild:constraint];
      }
      if (property[@"$OnDelete"]) {
        ODataXMLElement *onDelete = OISEl(@"OnDelete");
        OISSet(onDelete, @"Action", property[@"$OnDelete"]);
        [p addChild:onDelete];
      }
    }
    [self addAnnotations:property to:p prefix:@""];
    [e addChild:p];
  }
  [self addAnnotations:json to:e prefix:@""];
  return e;
}

+ (ODataXMLElement *)operationElement:(NSDictionary *)json name:(NSString *)name
{
  ODataXMLElement *e = OISEl(json[@"$Kind"]);
  OISSet(e, @"Name", name);
  for (NSString *flag in @[ @"IsBound", @"IsComposable" ]) {
    if ([json[[@"$" stringByAppendingString:flag]] boolValue]) OISSet(e, flag, @"true");
  }
  OISSet(e, @"EntitySetPath", json[@"$EntitySetPath"]);
  for (NSDictionary *parameter in json[@"$Parameter"] ?: @[]) {
    ODataXMLElement *p = OISEl(@"Parameter");
    OISSet(p, @"Name", parameter[@"$Name"]);
    [self setType:parameter on:p nullableDefault:YES];
    [self addAnnotations:parameter to:p prefix:@""];
    [e addChild:p];
  }
  if ([json[@"$ReturnType"] isKindOfClass:[NSDictionary class]]) {
    ODataXMLElement *returns = OISEl(@"ReturnType");
    [self setType:json[@"$ReturnType"] on:returns nullableDefault:YES];
    [self addAnnotations:json[@"$ReturnType"] to:returns prefix:@""];
    [e addChild:returns];
  }
  [self addAnnotations:json to:e prefix:@""];
  return e;
}

+ (ODataXMLElement *)containerElement:(NSDictionary *)json name:(NSString *)name
{
  ODataXMLElement *e = OISEl(@"EntityContainer");
  OISSet(e, @"Name", name);
  OISSet(e, @"Extends", json[@"$Extends"]);
  for (NSString *member in [json.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([member hasPrefix:@"$"] || [member rangeOfString:@"@"].location != NSNotFound) continue;
    NSDictionary *m = json[member];
    ODataXMLElement *child;
    if (m[@"$Action"] || m[@"$Function"]) {
      NSString *what = m[@"$Action"] ? @"Action" : @"Function";
      child = OISEl([what stringByAppendingString:@"Import"]);
      OISSet(child, @"Name", member);
      OISSet(child, what, m[[@"$" stringByAppendingString:what]]);
      OISSet(child, @"EntitySet", m[@"$EntitySet"]);
      if ([m[@"$IncludeInServiceDocument"] boolValue]) OISSet(child, @"IncludeInServiceDocument", @"true");
    } else if ([m[@"$Collection"] boolValue]) {
      child = OISEl(@"EntitySet");
      OISSet(child, @"Name", member);
      OISSet(child, @"EntityType", m[@"$Type"]);
      if (m[@"$IncludeInServiceDocument"] && ![m[@"$IncludeInServiceDocument"] boolValue]) OISSet(child, @"IncludeInServiceDocument", @"false");
    } else {
      child = OISEl(@"Singleton");
      OISSet(child, @"Name", member);
      OISSet(child, @"Type", m[@"$Type"]);
      if ([m[@"$Nullable"] boolValue]) OISSet(child, @"Nullable", @"true");
    }
    NSDictionary *bindings = m[@"$NavigationPropertyBinding"];
    for (NSString *path in [bindings.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataXMLElement *binding = OISEl(@"NavigationPropertyBinding");
      OISSet(binding, @"Path", path);
      OISSet(binding, @"Target", bindings[path]);
      [child addChild:binding];
    }
    [self addAnnotations:m to:child prefix:@""];
    [e addChild:child];
  }
  [self addAnnotations:json to:e prefix:@""];
  return e;
}

+ (NSData *)XMLDataForJSONData:(NSData *)data error:(NSError **)error
{
  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
  if (![json isKindOfClass:[NSDictionary class]] || !json[@"$Version"]) {
    if (error && json) *error = OISError(ODataIncrementalStoreErrorDecoding, @"Not CSDL JSON: no $Version");
    return nil;
  }
  ODataXMLElement *edmx = [[ODataXMLElement alloc] initWithName:@"edmx:Edmx" URI:OISEdmxNS];
  [edmx addNamespace:[ODataXMLNode namespaceWithName:@"edmx" stringValue:OISEdmxNS]];
  OISSet(edmx, @"Version", json[@"$Version"]);
  NSDictionary *references = json[@"$Reference"];
  for (NSString *uri in [references.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataXMLElement *reference = [[ODataXMLElement alloc] initWithName:@"edmx:Reference" URI:OISEdmxNS];
    OISSet(reference, @"Uri", uri);
    for (NSString *list in @[ @"$Include", @"$IncludeAnnotations" ]) {
      for (NSDictionary *entry in references[uri][list] ?: @[]) {
        ODataXMLElement *include = [[ODataXMLElement alloc] initWithName:[@"edmx:" stringByAppendingString:[list substringFromIndex:1]] URI:OISEdmxNS];
        for (NSString *key in [entry.allKeys sortedArrayUsingSelector:@selector(compare:)]) OISSet(include, [key substringFromIndex:1], entry[key]);
        [reference addChild:include];
      }
    }
    [edmx addChild:reference];
  }
  ODataXMLElement *services = [[ODataXMLElement alloc] initWithName:@"edmx:DataServices" URI:OISEdmxNS];
  for (NSString *ns in [json.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([ns hasPrefix:@"$"] || ![json[ns] isKindOfClass:[NSDictionary class]]) continue;
    NSDictionary *body = json[ns];
    ODataXMLElement *schema = OISEl(@"Schema");
    [schema addNamespace:[ODataXMLNode namespaceWithName:@"" stringValue:OISEdmNS]];
    OISSet(schema, @"Namespace", ns);
    OISSet(schema, @"Alias", body[@"$Alias"]);
    for (NSString *name in [body.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if ([name hasPrefix:@"$"] || [name hasPrefix:@"@"]) continue;
      id element = body[name];
      if ([element isKindOfClass:[NSArray class]]) {
        for (NSDictionary *overload in element) [schema addChild:[self operationElement:overload name:name]];
        continue;
      }
      NSString *kind = element[@"$Kind"];
      if ([kind isEqualToString:@"EntityType"] || [kind isEqualToString:@"ComplexType"]) {
        [schema addChild:[self structuredElement:element name:name]];
      } else if ([kind isEqualToString:@"EnumType"]) {
        ODataXMLElement *e = OISEl(@"EnumType");
        OISSet(e, @"Name", name);
        OISSet(e, @"UnderlyingType", element[@"$UnderlyingType"]);
        if ([element[@"$IsFlags"] boolValue]) OISSet(e, @"IsFlags", @"true");
        NSArray *members = [[element allKeys] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *key, NSDictionary *bindings) {
          return ![key hasPrefix:@"$"] && [key rangeOfString:@"@"].location == NSNotFound;
        }]];
        members = [members sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
          return [element[a] compare:element[b]];
        }];
        for (NSString *member in members) {
          ODataXMLElement *m = OISEl(@"Member");
          OISSet(m, @"Name", member);
          OISSet(m, @"Value", element[member]);
          [self addAnnotations:element to:m prefix:member];
          [e addChild:m];
        }
        [self addAnnotations:element to:e prefix:@""];
        [schema addChild:e];
      } else if ([kind isEqualToString:@"TypeDefinition"]) {
        ODataXMLElement *e = OISEl(@"TypeDefinition");
        OISSet(e, @"Name", name);
        OISSet(e, @"UnderlyingType", element[@"$UnderlyingType"]);
        for (NSString *facet in @[ @"MaxLength", @"Precision", @"Scale", @"SRID" ]) OISSet(e, facet, element[[@"$" stringByAppendingString:facet]]);
        [self addAnnotations:element to:e prefix:@""];
        [schema addChild:e];
      } else if ([kind isEqualToString:@"Term"]) {
        ODataXMLElement *e = OISEl(@"Term");
        OISSet(e, @"Name", name);
        [self setType:element on:e nullableDefault:YES];
        if ([element[@"$AppliesTo"] isKindOfClass:[NSArray class]]) OISSet(e, @"AppliesTo", [element[@"$AppliesTo"] componentsJoinedByString:@" "]);
        OISSet(e, @"BaseTerm", element[@"$BaseTerm"]);
        [self addAnnotations:element to:e prefix:@""];
        [schema addChild:e];
      } else if ([kind isEqualToString:@"EntityContainer"]) {
        [schema addChild:[self containerElement:element name:name]];
      }
    }
    NSDictionary *targeted = body[@"$Annotations"];
    for (NSString *target in [targeted.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataXMLElement *annotations = OISEl(@"Annotations");
      OISSet(annotations, @"Target", target);
      [self addAnnotations:targeted[target] to:annotations prefix:@""];
      [schema addChild:annotations];
    }
    [self addAnnotations:body to:schema prefix:@""];
    [services addChild:schema];
  }
  [edmx addChild:services];
  ODataXMLDocument *document = [[ODataXMLDocument alloc] initWithRootElement:edmx];
  document.version = @"1.0";
  document.characterEncoding = @"utf-8";
  return [document XMLDataWithOptions:ODataXMLNodeCompactEmptyElement];
}

@end
