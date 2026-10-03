// OISXML, what ODataKit's client reads and writes XML with where Foundation
// has no NSXMLDocument (iOS), held to NSXML where both are.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import <ODataKit/ODataXML.h>
#import "OISCatalogModel.h"

@interface ODataXMLTests : XCTestCase
@end

@implementation ODataXMLTests

// A node's attributes or namespace declarations, by name.
static NSDictionary *OXTNamed(NSArray *nodes)
{
  NSMutableDictionary *named = [NSMutableDictionary dictionary];
  for (id node in nodes) named[[node name] ?: @""] = [node stringValue] ?: @"";
  return named;
}

static NSArray *OXTElements(id element)
{
  NSMutableArray *elements = [NSMutableArray array];
  for (id child in [element children]) {
    if ([child isKindOfClass:[NSXMLNode class]] && ((NSXMLNode *)child).kind == NSXMLElementKind) [elements addObject:child];
    else if ([child isKindOfClass:[OISXMLNode class]] && ((OISXMLNode *)child).kind == OISXMLElementKind) [elements addObject:child];
  }
  return elements;
}

// The same tree: names, attributes, declarations, child elements, and a
// leaf's text.
- (void)assertElement:(OISXMLElement *)ours sameAs:(NSXMLElement *)theirs path:(NSString *)path
{
  XCTAssertEqualObjects(ours.name, theirs.name, @"%@", path);
  XCTAssertEqualObjects(ours.localName, theirs.localName, @"%@", path);
  XCTAssertEqualObjects(OXTNamed(ours.attributes), OXTNamed(theirs.attributes), @"%@ attributes", path);
  XCTAssertEqualObjects(OXTNamed(ours.namespaces), OXTNamed(theirs.namespaces), @"%@ namespaces", path);
  NSArray *mine = OXTElements(ours), *other = OXTElements(theirs);
  XCTAssertEqual(mine.count, other.count, @"%@ children", path);
  if (!mine.count) XCTAssertEqualObjects(ours.stringValue, theirs.stringValue, @"%@ text", path);
  for (NSUInteger i = 0; i < MIN(mine.count, other.count); i++) {
    [self assertElement:mine[i] sameAs:other[i] path:[NSString stringWithFormat:@"%@/%@[%lu]", path, [mine[i] name], (unsigned long)i]];
  }
}

- (void)assertReadsAlike:(NSData *)data
{
  NSError *error = nil;
  OISXMLDocument *ours = [[OISXMLDocument alloc] initWithData:data options:0 error:&error];
  XCTAssertNotNil(ours, @"%@", error);
  NSXMLDocument *theirs = [[NSXMLDocument alloc] initWithData:data options:0 error:NULL];
  [self assertElement:ours.rootElement sameAs:theirs.rootElement path:ours.rootElement.name ?: @"?"];
}

- (NSData *)snapshotXML:(NSString *)path
{
  NSString *file = [OISSnapshotDirectory() stringByAppendingPathComponent:path];
  NSDictionary *snapshot = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:file] options:0 error:NULL];
  return [snapshot[@"response"][@"bodyXML"] dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)testReadsMetadataAsNSXMLDoes
{
  [self assertReadsAlike:[self snapshotXML:@"metadata.json"]];
  [self assertReadsAlike:[self snapshotXML:@"Zoo/metadata.json"]];
  NSString *crafted = @"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
                      @"<a:Root xmlns:a=\"urn:a\" xmlns=\"urn:default\" Version=\"4.01\">\n"
                      @"  <Item Name=\"x &amp; y\" Note=\"&quot;quoted&quot; &lt;tag&gt;\"/>\n"
                      @"  <Text>one &amp; two</Text>\n"
                      @"  <Data><![CDATA[<raw> & stuff]]></Data>\n"
                      @"  <Empty></Empty>\n"
                      @"  <a:Nested><Inner Value=\"1\"/><Inner Value=\"2\">text</Inner></a:Nested>\n"
                      @"</a:Root>";
  [self assertReadsAlike:[crafted dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)testRefusesWhatIsNotWellFormed
{
  NSError *error = nil;
  XCTAssertNil([[OISXMLDocument alloc] initWithData:[@"<a><b></a>" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:&error]);
  XCTAssertNotNil(error);
}

// The same document built with both, written, and read back by NSXML.
- (void)testWritesWhatNSXMLReadsAlike
{
  OISXMLElement *root = [[OISXMLElement alloc] initWithName:@"edmx:Edmx" URI:@"urn:edmx"];
  [root addNamespace:[OISXMLNode namespaceWithName:@"edmx" stringValue:@"urn:edmx"]];
  [root addAttribute:[OISXMLNode attributeWithName:@"Version" stringValue:@"4.01"]];
  OISXMLElement *schema = [[OISXMLElement alloc] initWithName:@"Schema"];
  [schema addNamespace:[OISXMLNode namespaceWithName:@"" stringValue:@"urn:edm"]];
  [schema addAttribute:[OISXMLNode attributeWithName:@"Namespace" stringValue:@"A & \"B\" <C>"]];
  OISXMLElement *string = [[OISXMLElement alloc] initWithName:@"String"];
  string.stringValue = @"x < y & z";
  [schema addChild:string];
  [schema addChild:[[OISXMLElement alloc] initWithName:@"Empty"]];
  [root addChild:schema];
  OISXMLDocument *ours = [[OISXMLDocument alloc] initWithRootElement:root];
  ours.version = @"1.0";
  ours.characterEncoding = @"utf-8";

  NSXMLElement *theirRoot = [[NSXMLElement alloc] initWithName:@"edmx:Edmx" URI:@"urn:edmx"];
  [theirRoot addNamespace:[NSXMLNode namespaceWithName:@"edmx" stringValue:@"urn:edmx"]];
  [theirRoot addAttribute:[NSXMLNode attributeWithName:@"Version" stringValue:@"4.01"]];
  NSXMLElement *theirSchema = [[NSXMLElement alloc] initWithName:@"Schema"];
  [theirSchema addNamespace:[NSXMLNode namespaceWithName:@"" stringValue:@"urn:edm"]];
  [theirSchema addAttribute:[NSXMLNode attributeWithName:@"Namespace" stringValue:@"A & \"B\" <C>"]];
  NSXMLElement *theirString = [[NSXMLElement alloc] initWithName:@"String"];
  theirString.stringValue = @"x < y & z";
  [theirSchema addChild:theirString];
  [theirSchema addChild:[[NSXMLElement alloc] initWithName:@"Empty"]];
  [theirRoot addChild:theirSchema];
  NSXMLDocument *theirs = [[NSXMLDocument alloc] initWithRootElement:theirRoot];

  NSUInteger choices[] = { OISXMLNodeCompactEmptyElement, OISXMLNodeCompactEmptyElement | OISXMLNodePrettyPrint };
  for (int i = 0; i < 2; i++) {
    NSUInteger options = choices[i];
    NSData *written = [ours XMLDataWithOptions:options];
    NSXMLDocument *read = [[NSXMLDocument alloc] initWithData:written options:0 error:NULL];
    XCTAssertNotNil(read, @"%@", [[NSString alloc] initWithData:written encoding:NSUTF8StringEncoding]);
    NSXMLDocument *expected = [[NSXMLDocument alloc] initWithData:[theirs XMLDataWithOptions:NSXMLNodeCompactEmptyElement] options:0 error:NULL];
    // Read back by OISXML too, against NSXML's reading of NSXML's writing.
    OISXMLDocument *again = [[OISXMLDocument alloc] initWithData:written options:0 error:NULL];
    [self assertElement:again.rootElement sameAs:expected.rootElement path:@"edmx:Edmx"];
    XCTAssertEqualObjects(read.rootElement.name, @"edmx:Edmx");
  }
  NSString *compact = [ours XMLStringWithOptions:OISXMLNodeCompactEmptyElement];
  XCTAssertTrue([compact hasPrefix:@"<?xml version=\"1.0\" encoding=\"utf-8\"?>"], @"%@", compact);
  XCTAssertTrue([compact rangeOfString:@"<Empty/>"].location != NSNotFound, @"%@", compact);
  XCTAssertTrue([compact rangeOfString:@"Namespace=\"A &amp; &quot;B&quot; &lt;C&gt;\""].location != NSNotFound, @"%@", compact);
  XCTAssertTrue([compact rangeOfString:@"<String>x &lt; y &amp; z</String>"].location != NSNotFound, @"%@", compact);
}

@end
