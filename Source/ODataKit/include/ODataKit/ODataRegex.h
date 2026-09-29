// ODataKit — regular expressions as trees, read from and written in the
// dialects that meet in a request.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A pattern passes between three dialects that look alike and differ in
// what they match: OData's matchesPattern and Validation.Pattern take
// ECMAScript's (Part 2 section 5.1.1.5.4), NSPredicate's MATCHES takes
// ICU's under its own flags, and LIKE has wildcards of its own. Each is
// read into one tree whose every node says exactly what it matches ("."
// is spelled out as which characters, ^ as the start of the text or of a
// line, \d as ASCII or Unicode digits), transformed as a tree, and
// written in another dialect, which refuses (with why) what it cannot say
// exactly rather than say something close:
//
//   ODataRegex *r = [ODataRegex regexWithString:@"^\\d+$" dialect:ODataRegexECMAScript error:&error];
//   NSString *icu = [[r anywhere] stringInDialect:ODataRegexMatches error:&error];
//   // (?:[^\r]|\r)*(?:\A[0-9]+\z)(?:[^\r]|\r)*
//
// Written for MATCHES, a pattern keeps to the part of ICU's syntax a SQL
// store can translate where it can (FreeCoreData's): literal characters,
// sets of characters and ranges, ".", \A and \z, groups, lookahead,
// repeats; anything else only where nothing in that part says it.

#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ODataRegexDialect) {
  // ECMAScript, with no flags, as OData reads a pattern: ^ and $ the ends
  // of the text, "." any character but \n \r    , \d and \w
  // ASCII, \s ECMAScript's white space.
  ODataRegexECMAScript,
  // ICU, as NSPredicate's MATCHES reads it: of the whole string, "." any
  // character (a \r\n as one), \d \w \s Unicode, and ^ and $ at each line
  // where the platform's MATCHES has them so (Apple's, and gnustep-base's
  // with the predicate-matches-line-anchors fix), else at the ends.
  ODataRegexMatches,
  // NSPredicate's LIKE: * any run of characters, ? any one, a backslash
  // the next character itself, and every other character itself.
  ODataRegexLike
};

typedef NS_ENUM(NSInteger, ODataRegexKind) {
  ODataRegexSequence,     // parts, one after another (none: the empty string)
  ODataRegexAlternation,  // parts, one of them
  ODataRegexLiteral,      // character
  ODataRegexAny,          // one character of those `any` says
  ODataRegexSet,          // one character in members (or, negated, not)
  ODataRegexAnchor,       // a position: anchor
  ODataRegexGroup,        // part, capturing or not
  ODataRegexLook,         // part: ahead or behind, found or (negated) not
  ODataRegexRepeat        // part, minimum to maximum times (NSNotFound: no maximum), lazy or not
};

// Which characters "." stands for.
typedef NS_ENUM(NSInteger, ODataRegexAnyKind) {
  ODataRegexAnyCharacter,          // ICU's with DOTALL: any, a \r\n as one
  ODataRegexAnyButLineTerminator,  // ECMAScript's: any but \n \r
  ODataRegexAnyCodePoint           // any one, a \r of a \r\n on its own
};

typedef NS_ENUM(NSInteger, ODataRegexAnchorKind) {
  ODataRegexStartOfText,        // ^ in ECMAScript, \A
  ODataRegexEndOfText,          // $ in ECMAScript, \z
  ODataRegexEndOfTextOrLine,    // \Z: the end, or before a line terminator that ends the text
  ODataRegexStartOfLine,        // ^ at each line
  ODataRegexEndOfLine,          // $ at each line
  ODataRegexWordBoundary,       // \b (unicode: of Unicode word characters, else ASCII)
  ODataRegexNotWordBoundary     // \B
};

typedef NS_ENUM(NSInteger, ODataRegexClassKind) {
  ODataRegexDigits,             // ASCII: 0-9; Unicode: \p{Nd}
  ODataRegexWordCharacters,     // ASCII: A-Za-z0-9_; Unicode: ICU's \w
  ODataRegexSpaces              // ASCII: ECMAScript's white space and line terminators; Unicode: ICU's \s
};

// A member of a set: a range of characters (first to last), or a class.
@interface ODataRegexMember : NSObject
+ (instancetype)rangeFrom:(UTF32Char)first to:(UTF32Char)last;
+ (instancetype)classOf:(ODataRegexClassKind)kind unicode:(BOOL)unicode negated:(BOOL)negated;
@property (nonatomic, readonly) BOOL isClass;
@property (nonatomic, readonly) UTF32Char first;
@property (nonatomic, readonly) UTF32Char last;
@property (nonatomic, readonly) ODataRegexClassKind classKind;
@property (nonatomic, readonly) BOOL unicode;
@property (nonatomic, readonly) BOOL negated;
@end

@interface ODataRegex : NSObject

// Read; nil, and why (ODataIncrementalStoreErrorSyntax for what is no
// pattern, ODataIncrementalStoreErrorUnsupportedExpression for what is one
// but not read here: back references, inline flags, \p{...}...).
+ (nullable instancetype)regexWithString:(NSString *)pattern dialect:(ODataRegexDialect)dialect error:(NSError **)error;
// Written; nil, and why (ODataIncrementalStoreErrorUnsupportedExpression),
// where the dialect cannot say it exactly.
- (nullable NSString *)stringInDialect:(ODataRegexDialect)dialect error:(NSError **)error;

// OData's ECMAScript pattern (matchesPattern, Validation.Pattern) as the
// MATCHES pattern that finds it anywhere, as ECMAScript's RegExp test
// does; nil, and why, as above.
+ (nullable NSString *)matchesPatternFindingECMAScript:(NSString *)pattern error:(NSError **)error;

// Whether this platform's MATCHES takes ^ and $ at each line: Apple's
// does, gnustep-base's did not before the fix (asked of NSPredicate once).
+ (BOOL)matchesAnchorsMatchLines;

// Built.
+ (instancetype)sequence:(NSArray<ODataRegex *> *)parts;
+ (instancetype)alternation:(NSArray<ODataRegex *> *)parts;
+ (instancetype)literal:(UTF32Char)character;
+ (instancetype)literalString:(NSString *)text;   // its characters in sequence
+ (instancetype)any:(ODataRegexAnyKind)kind;
+ (instancetype)set:(NSArray<ODataRegexMember *> *)members negated:(BOOL)negated;
+ (instancetype)anchor:(ODataRegexAnchorKind)kind unicode:(BOOL)unicode;
+ (instancetype)group:(ODataRegex *)part capturing:(BOOL)capturing;
+ (instancetype)look:(ODataRegex *)part behind:(BOOL)behind negated:(BOOL)negated;
+ (instancetype)repeat:(ODataRegex *)part minimum:(NSUInteger)minimum maximum:(NSUInteger)maximum lazy:(BOOL)lazy;

@property (nonatomic, readonly) ODataRegexKind kind;
@property (nonatomic, readonly, copy) NSArray<ODataRegex *> *parts;
@property (nonatomic, readonly, nullable) ODataRegex *part;
@property (nonatomic, readonly) UTF32Char character;
@property (nonatomic, readonly) ODataRegexAnyKind any;
@property (nonatomic, readonly, copy) NSArray<ODataRegexMember *> *members;
@property (nonatomic, readonly) BOOL negated;
@property (nonatomic, readonly) ODataRegexAnchorKind anchor;
@property (nonatomic, readonly) BOOL unicode;
@property (nonatomic, readonly) BOOL capturing;
@property (nonatomic, readonly) BOOL behind;
@property (nonatomic, readonly) NSUInteger minimum;
@property (nonatomic, readonly) NSUInteger maximum;
@property (nonatomic, readonly) BOOL lazy;

// Matched against the whole text: from its start to its end.
- (ODataRegex *)whole;
// Found anywhere in the text, as ECMAScript's test finds it, as a pattern
// of the whole text: anything, one character at a time, around it.
- (ODataRegex *)anywhere;
// With each node block gives in its place (nil: the node, its parts
// replaced), from the leaves up.
- (ODataRegex *)regexReplacing:(ODataRegex *_Nullable (^)(ODataRegex *node))block;

@end

NS_ASSUME_NONNULL_END
