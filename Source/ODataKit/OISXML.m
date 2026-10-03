// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataXML.h"

@interface OISXMLNode ()
@property (nonatomic, readwrite) OISXMLNodeKind kind;
@property (nonatomic, readwrite, weak, nullable) OISXMLNode *parent;
@property (nonatomic, strong, nullable) NSMutableArray<OISXMLNode *> *childNodes;
@end

@implementation OISXMLNode {
  NSString *_value;
}

+ (instancetype)nodeOfKind:(OISXMLNodeKind)kind name:(NSString *)name value:(NSString *)value
{
  OISXMLNode *node = [[OISXMLNode alloc] init];
  node.kind = kind;
  node.name = name;
  node->_value = [value copy];
  return node;
}

+ (instancetype)attributeWithName:(NSString *)name stringValue:(NSString *)value
{
  return [self nodeOfKind:OISXMLAttributeKind name:name value:value];
}

+ (instancetype)namespaceWithName:(NSString *)name stringValue:(NSString *)value
{
  return [self nodeOfKind:OISXMLNamespaceKind name:name value:value];
}

+ (instancetype)textWithStringValue:(NSString *)value
{
  return [self nodeOfKind:OISXMLTextKind name:nil value:value];
}

- (NSString *)localName
{
  NSString *name = self.name;
  NSRange colon = [name rangeOfString:@":"];
  return colon.location == NSNotFound ? name : [name substringFromIndex:NSMaxRange(colon)];
}

- (NSArray<OISXMLNode *> *)children
{
  return self.childNodes ? [self.childNodes copy] : nil;
}

- (NSString *)stringValue
{
  if (self.kind == OISXMLAttributeKind || self.kind == OISXMLNamespaceKind || self.kind == OISXMLTextKind) return _value;
  NSMutableString *text = [NSMutableString string];
  for (OISXMLNode *child in self.childNodes) {
    if (child.kind == OISXMLTextKind || child.kind == OISXMLElementKind) [text appendString:child.stringValue ?: @""];
  }
  return text;
}

- (void)setStringValue:(NSString *)value
{
  if (self.kind == OISXMLAttributeKind || self.kind == OISXMLNamespaceKind || self.kind == OISXMLTextKind) {
    _value = [value copy];
    return;
  }
  self.childNodes = [NSMutableArray array];
  if (value.length) {
    OISXMLNode *text = [OISXMLNode textWithStringValue:value];
    text.parent = self;
    [self.childNodes addObject:text];
  }
}

@end

@implementation OISXMLElement {
  NSMutableArray<OISXMLNode *> *_attributes;
  NSMutableArray<OISXMLNode *> *_namespaces;
}

- (instancetype)initWithName:(NSString *)name
{
  return [self initWithName:name URI:nil];
}

- (instancetype)initWithName:(NSString *)name URI:(NSString *)URI
{
  self = [super init];
  if (!self) return nil;
  self.kind = OISXMLElementKind;
  self.name = name;
  _URI = [URI copy];
  self.childNodes = [NSMutableArray array];
  _attributes = [NSMutableArray array];
  _namespaces = [NSMutableArray array];
  return self;
}

- (void)addChild:(OISXMLNode *)child
{
  child.parent = self;
  [self.childNodes addObject:child];
}

- (void)addAttribute:(OISXMLNode *)attribute
{
  // One of a name: the new replaces the old, as NSXMLElement's does.
  for (NSUInteger i = 0; i < _attributes.count; i++) {
    if ([_attributes[i].name isEqualToString:attribute.name]) {
      attribute.parent = self;
      _attributes[i] = attribute;
      return;
    }
  }
  attribute.parent = self;
  [_attributes addObject:attribute];
}

- (void)addNamespace:(OISXMLNode *)aNamespace
{
  aNamespace.parent = self;
  [_namespaces addObject:aNamespace];
}

- (OISXMLNode *)attributeForName:(NSString *)name
{
  for (OISXMLNode *attribute in _attributes) {
    if ([attribute.name isEqualToString:name]) return attribute;
  }
  return nil;
}

- (NSArray<OISXMLElement *> *)elementsForName:(NSString *)name
{
  NSMutableArray *found = [NSMutableArray array];
  for (OISXMLNode *child in self.childNodes) {
    if (child.kind == OISXMLElementKind && [child.name isEqualToString:name]) [found addObject:child];
  }
  return found;
}

- (NSArray<OISXMLNode *> *)attributes
{
  return _attributes.count ? [_attributes copy] : nil;
}

- (NSArray<OISXMLNode *> *)namespaces
{
  return _namespaces.count ? [_namespaces copy] : nil;
}

@end

#pragma mark - Reading

// The tree, as NSXMLParser goes through the document (no namespace
// processing: names as written, xmlns declarations kept as namespaces).
@interface OISXMLReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) OISXMLElement *root;
@property (nonatomic, strong) NSMutableArray<OISXMLElement *> *open;
@end

@implementation OISXMLReader

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)URI qualifiedName:(NSString *)qualified
    attributes:(NSDictionary<NSString *, NSString *> *)attributes
{
  OISXMLElement *element = [[OISXMLElement alloc] initWithName:qualified ?: name];
  for (NSString *key in [attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([key isEqualToString:@"xmlns"]) {
      [element addNamespace:[OISXMLNode namespaceWithName:@"" stringValue:attributes[key]]];
    } else if ([key hasPrefix:@"xmlns:"]) {
      [element addNamespace:[OISXMLNode namespaceWithName:[key substringFromIndex:6] stringValue:attributes[key]]];
    } else {
      [element addAttribute:[OISXMLNode attributeWithName:key stringValue:attributes[key]]];
    }
  }
  if (self.open.lastObject) [self.open.lastObject addChild:element]; else self.root = element;
  [self.open addObject:element];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)URI qualifiedName:(NSString *)qualified
{
  [self.open removeLastObject];
}

- (void)appendText:(NSString *)string
{
  OISXMLElement *element = self.open.lastObject;
  if (!element || !string.length) return;
  OISXMLNode *last = element.childNodes.lastObject;
  if (last.kind == OISXMLTextKind) last.stringValue = [last.stringValue stringByAppendingString:string];
  else [element addChild:[OISXMLNode textWithStringValue:string]];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string
{
  [self appendText:string];
}

- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)block
{
  [self appendText:[[NSString alloc] initWithData:block encoding:NSUTF8StringEncoding]];
}

@end

#pragma mark - Writing

static NSString *OISEscaped(NSString *text, BOOL attribute)
{
  NSMutableString *out = [NSMutableString stringWithCapacity:text.length];
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    switch (c) {
      case '&': [out appendString:@"&amp;"]; break;
      case '<': [out appendString:@"&lt;"]; break;
      case '>': [out appendString:@"&gt;"]; break;
      case '"': [out appendString:attribute ? @"&quot;" : @"\""]; break;
      default: [out appendFormat:@"%C", c];
    }
  }
  return out;
}

static void OISWrite(OISXMLNode *node, NSMutableString *out, NSUInteger options, NSUInteger depth)
{
  BOOL pretty = (options & OISXMLNodePrettyPrint) != 0;
  if (node.kind == OISXMLTextKind) {
    [out appendString:OISEscaped(node.stringValue ?: @"", NO)];
    return;
  }
  if (node.kind != OISXMLElementKind) return;
  OISXMLElement *element = (OISXMLElement *)node;
  NSString *indent = pretty ? [@"" stringByPaddingToLength:depth * 4 withString:@" " startingAtIndex:0] : @"";
  [out appendFormat:@"%@<%@", indent, element.name];
  for (OISXMLNode *declaration in element.namespaces) {
    NSString *name = declaration.name.length ? [@"xmlns:" stringByAppendingString:declaration.name] : @"xmlns";
    [out appendFormat:@" %@=\"%@\"", name, OISEscaped(declaration.stringValue ?: @"", YES)];
  }
  for (OISXMLNode *attribute in element.attributes) {
    [out appendFormat:@" %@=\"%@\"", attribute.name, OISEscaped(attribute.stringValue ?: @"", YES)];
  }
  NSArray *children = element.childNodes;
  if (!children.count) {
    [out appendString:(options & OISXMLNodeCompactEmptyElement) ? @"/>" : [NSString stringWithFormat:@"></%@>", element.name]];
    if (pretty) [out appendString:@"\n"];
    return;
  }
  [out appendString:@">"];
  BOOL elementsOnly = YES;
  for (OISXMLNode *child in children) {
    if (child.kind == OISXMLTextKind && [child.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length) {
      elementsOnly = NO;
    }
  }
  if (pretty && elementsOnly) {
    [out appendString:@"\n"];
    for (OISXMLNode *child in children) {
      if (child.kind == OISXMLElementKind) OISWrite(child, out, options, depth + 1);
    }
    [out appendFormat:@"%@</%@>\n", indent, element.name];
    return;
  }
  for (OISXMLNode *child in children) OISWrite(child, out, options & ~(NSUInteger)OISXMLNodePrettyPrint, 0);
  [out appendFormat:@"</%@>", element.name];
  if (pretty) [out appendString:@"\n"];
}

@implementation OISXMLDocument

- (instancetype)initWithData:(NSData *)data options:(NSUInteger)options error:(NSError **)error
{
  self = [super init];
  if (!self) return nil;
  self.kind = OISXMLDocumentKind;
  NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
  parser.shouldProcessNamespaces = NO;
  parser.shouldReportNamespacePrefixes = NO;
  OISXMLReader *reader = [[OISXMLReader alloc] init];
  reader.open = [NSMutableArray array];
  parser.delegate = reader;
  if (![parser parse] || !reader.root) {
    if (error) {
      *error = parser.parserError ?: [NSError errorWithDomain:NSXMLParserErrorDomain code:NSXMLParserEmptyDocumentError userInfo:nil];
    }
    return nil;
  }
  self.childNodes = [NSMutableArray arrayWithObject:reader.root];
  reader.root.parent = self;
  return self;
}

- (instancetype)initWithRootElement:(OISXMLElement *)element
{
  self = [super init];
  if (!self) return nil;
  self.kind = OISXMLDocumentKind;
  self.childNodes = [NSMutableArray array];
  if (element) {
    element.parent = self;
    [self.childNodes addObject:element];
  }
  return self;
}

- (OISXMLElement *)rootElement
{
  for (OISXMLNode *child in self.childNodes) {
    if (child.kind == OISXMLElementKind) return (OISXMLElement *)child;
  }
  return nil;
}

- (NSString *)XMLStringWithOptions:(NSUInteger)options
{
  NSMutableString *out = [NSMutableString string];
  if (self.version || self.characterEncoding) {
    [out appendFormat:@"<?xml version=\"%@\"", self.version ?: @"1.0"];
    if (self.characterEncoding) [out appendFormat:@" encoding=\"%@\"", self.characterEncoding];
    if (self.standalone) [out appendString:@" standalone=\"yes\""];
    [out appendString:@"?>"];
    if (options & OISXMLNodePrettyPrint) [out appendString:@"\n"];
  }
  if (self.rootElement) OISWrite(self.rootElement, out, options, 0);
  return out;
}

- (NSData *)XMLDataWithOptions:(NSUInteger)options
{
  return [[self XMLStringWithOptions:options] dataUsingEncoding:NSUTF8StringEncoding];
}

@end
