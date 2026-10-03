// XML documents where Foundation has no NSXMLDocument (iOS): the subset of
// NSXML ODataKit's client uses ($metadata read and written, a model file),
// over NSXMLParser.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Code writes ODataXMLDocument, ODataXMLElement and ODataXMLNode (and the
// ODataXML* constants): NSXML's classes where Foundation has them (macOS,
// GNUstep), OISXML's below elsewhere. OISXML is built everywhere, so that
// it is tested against NSXML where both are.

#pragma once
#import <Foundation/Foundation.h>
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, OISXMLNodeKind) {
  OISXMLInvalidKind = 0,
  OISXMLDocumentKind,
  OISXMLElementKind,
  OISXMLAttributeKind,
  OISXMLNamespaceKind,
  OISXMLTextKind,
};

typedef NS_OPTIONS(NSUInteger, OISXMLNodeOptions) {
  OISXMLNodeOptionsNone = 0,
  OISXMLNodePrettyPrint = 1 << 17,          // NSXMLNodePrettyPrint's bit
  OISXMLNodeCompactEmptyElement = 1 << 2,   // NSXMLNodeCompactEmptyElement's bit
};

@class OISXMLElement;

// A node: an element, an attribute, a namespace declaration, or text.
@interface OISXMLNode : NSObject
+ (instancetype)attributeWithName:(NSString *)name stringValue:(NSString *)value;
// A declaration: xmlns (name "") or xmlns:name.
+ (instancetype)namespaceWithName:(NSString *)name stringValue:(NSString *)value;
+ (instancetype)textWithStringValue:(NSString *)value;
@property (nonatomic, readonly) OISXMLNodeKind kind;
// As written (edmx:Edmx); without its prefix (Edmx).
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, readonly, nullable) NSString *localName;
// An attribute's or a text's value; an element's text, all of it (set: its
// children become that text).
@property (nonatomic, copy, nullable) NSString *stringValue;
@property (nonatomic, readonly, nullable) NSArray<OISXMLNode *> *children;
@property (nonatomic, readonly, weak, nullable) OISXMLNode *parent;
@end

@interface OISXMLElement : OISXMLNode
- (instancetype)initWithName:(NSString *)name;
// The namespace is the document's to declare (addNamespace:); kept as given.
- (instancetype)initWithName:(NSString *)name URI:(nullable NSString *)URI;
@property (nonatomic, readonly, nullable) NSString *URI;
- (void)addChild:(OISXMLNode *)child;
- (void)addAttribute:(OISXMLNode *)attribute;
- (void)addNamespace:(OISXMLNode *)aNamespace;
- (nullable OISXMLNode *)attributeForName:(NSString *)name;
// Its child elements of that name (as written).
- (NSArray<OISXMLElement *> *)elementsForName:(NSString *)name;
@property (nonatomic, readonly, nullable) NSArray<OISXMLNode *> *attributes;
@property (nonatomic, readonly, nullable) NSArray<OISXMLNode *> *namespaces;
@end

@interface OISXMLDocument : OISXMLNode
// Read: its elements, attributes, namespaces and text (whitespace kept);
// nil, with the parser's error, when it is not well-formed.
- (nullable instancetype)initWithData:(NSData *)data options:(NSUInteger)options error:(NSError **)error;
- (instancetype)initWithRootElement:(nullable OISXMLElement *)element;
@property (nonatomic, readonly, nullable) OISXMLElement *rootElement;
@property (nonatomic, copy, nullable) NSString *version;
@property (nonatomic, copy, nullable) NSString *characterEncoding;
@property (nonatomic, getter=isStandalone) BOOL standalone;
// Written, UTF-8: OISXMLNodeCompactEmptyElement (<a/>), OISXMLNodePrettyPrint.
- (NSData *)XMLDataWithOptions:(NSUInteger)options;
- (NSString *)XMLStringWithOptions:(NSUInteger)options;
@end

#if defined(__APPLE__) && TARGET_OS_IPHONE
@compatibility_alias ODataXMLNode OISXMLNode;
@compatibility_alias ODataXMLElement OISXMLElement;
@compatibility_alias ODataXMLDocument OISXMLDocument;
#define ODataXMLElementKind OISXMLElementKind
#define ODataXMLNodePrettyPrint OISXMLNodePrettyPrint
#define ODataXMLNodeCompactEmptyElement OISXMLNodeCompactEmptyElement
#else
@compatibility_alias ODataXMLNode NSXMLNode;
@compatibility_alias ODataXMLElement NSXMLElement;
@compatibility_alias ODataXMLDocument NSXMLDocument;
#define ODataXMLElementKind NSXMLElementKind
#define ODataXMLNodePrettyPrint NSXMLNodePrettyPrint
#define ODataXMLNodeCompactEmptyElement NSXMLNodeCompactEmptyElement
#endif

NS_ASSUME_NONNULL_END
