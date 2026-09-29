// Regular expressions as trees: read in one dialect, written in another,
// exactly or not at all.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"

@interface ODataRegexTests : XCTestCase
@end

@implementation ODataRegexTests

- (NSString *)write:(NSString *)pattern from:(ODataRegexDialect)from to:(ODataRegexDialect)to
{
  NSError *error = nil;
  ODataRegex *r = [ODataRegex regexWithString:pattern dialect:from error:&error];
  XCTAssertNotNil(r, @"%@: %@", pattern, error);
  NSString *written = [r stringInDialect:to error:&error];
  XCTAssertNotNil(written, @"%@: %@", pattern, error);
  return written;
}

- (NSError *)refusalOf:(NSString *)pattern from:(ODataRegexDialect)from to:(ODataRegexDialect)to
{
  NSError *error = nil;
  ODataRegex *r = [ODataRegex regexWithString:pattern dialect:from error:&error];
  if (!r) return error;
  XCTAssertNil([r stringInDialect:to error:&error], @"%@", pattern);
  return error;
}

// ECMAScript as MATCHES reads it: each difference spelled out.
- (void)testECMAScriptAsICU
{
  NSDictionary *expected = @{
    @"^ab$": @"\\Aab\\z",
    @"a.b": @"a[^\\n\\r  ]b",
    @"\\d+": @"[0-9]+",
    @"\\W": @"[^A-Za-z0-9_]",
    @"[\\d_]": @"[0-9_]",
    @"[^\\d]": @"[^0-9]",
    @"a{2,}?": @"a{2,}?",
    @"(?:ab|cd)*": @"(?:ab|cd)*",
    @"(a)(?=b)(?!c)(?<=a)(?<!d)": @"(a)(?=b)(?!c)(?<=a)(?<!d)",
    @"\\x41\\u00e9\\n": @"Aé\\n",
    @"a{": @"a\\{",
    @"[]": @"(?!)",
    @"[^]": @"(?:[^\\r]|\\r)",
    @"\\.\\*\\/": @"\\.\\*/",
    @"\\bx": @"(?:(?<=[A-Za-z0-9_])(?![A-Za-z0-9_])|(?<![A-Za-z0-9_])(?=[A-Za-z0-9_]))x",
  };
  for (NSString *pattern in expected) {
    XCTAssertEqualObjects([self write:pattern from:ODataRegexECMAScript to:ODataRegexMatches], expected[pattern], @"%@", pattern);
  }
}

// What an ECMAScript pattern finds, as MATCHES then finds it: the answers
// are ECMAScript's (RegExp.prototype.test, no flags).
- (void)testECMAScriptPatternsFindWhatECMAScriptFinds
{
  NSArray *cases = @[
    @[ @"b", @"abc", @YES ], @[ @"^b", @"abc", @NO ], @[ @"^a", @"abc", @YES ],
    @[ @"a.c", @"a\nc", @NO ], @[ @"a.c", @"abc", @YES ], @[ @"a.c", @"a c", @NO ],
    @[ @"^b$", @"a\nb", @NO ], @[ @"c$", @"abc\n", @NO ], @[ @"c$", @"abc", @YES ],
    @[ @"\\d", @"٣", @NO ], @[ @"\\d", @"x7", @YES ], @[ @"\\w", @"é", @NO ],
    @[ @"\\s", @" ", @YES ], @[ @"\\s", @"﻿", @YES ],
    @[ @"\\bfoo\\b", @"a foo b", @YES ], @[ @"\\bfoo\\b", @"afoob", @NO ], @[ @"\\bfoo\\b", @"éfooé", @YES ],
    @[ @"x{2,3}", @"axxb", @YES ], @[ @"x{2,3}", @"axb", @NO ],
    @[ @"\\n", @"a\r\nb", @YES ], @[ @"^$", @"", @YES ], @[ @"a|^b", @"cb", @NO ],
  ];
  for (NSArray *c in cases) {
    NSError *error = nil;
    ODataRegex *r = [ODataRegex regexWithString:c[0] dialect:ODataRegexECMAScript error:&error];
    NSString *icu = [[r anywhere] stringInDialect:ODataRegexMatches error:&error];
    XCTAssertNotNil(icu, @"%@: %@", c[0], error);
    BOOL found = [[NSPredicate predicateWithFormat:@"SELF MATCHES %@", icu] evaluateWithObject:c[1]];
    XCTAssertEqual(found, [c[2] boolValue], @"/%@/.test(%@), as %@", c[0], c[1], icu);
  }
}

// MATCHES as ECMAScript: what reads alike, and what does not.
- (void)testICUAsECMAScript
{
  XCTAssertEqualObjects([self write:@"a.b" from:ODataRegexMatches to:ODataRegexECMAScript], @"a(?:\\r\\n|\\r(?!\\n)|[^\\r])b");
  XCTAssertEqualObjects([self write:@"\\Aab\\z" from:ODataRegexMatches to:ODataRegexECMAScript], @"^ab$");
  XCTAssertEqualObjects([self write:@"(?s)a\\Qx.y\\E" from:ODataRegexMatches to:ODataRegexECMAScript], @"ax\\.y");
  XCTAssertEqualObjects([self write:@"[0-9]{3}" from:ODataRegexMatches to:ODataRegexECMAScript], @"[0-9]{3}");
  XCTAssertEqualObjects([self write:@"a\\x{263A}" from:ODataRegexMatches to:ODataRegexECMAScript], @"a☺");
  NSString *whole = [[[ODataRegex regexWithString:@"ab|c" dialect:ODataRegexMatches error:NULL] whole] stringInDialect:ODataRegexECMAScript error:NULL];
  XCTAssertEqualObjects(whole, @"^(?:ab|c)$", @"whole, grouped");
  XCTAssertEqual([self refusalOf:@"\\d" from:ODataRegexMatches to:ODataRegexECMAScript].code, ODataIncrementalStoreErrorUnsupportedExpression,
                 @"ICU's \\d is Unicode");
  XCTAssertEqual([self refusalOf:@"\\bx" from:ODataRegexMatches to:ODataRegexECMAScript].code, ODataIncrementalStoreErrorUnsupportedExpression);
  if ([ODataRegex matchesAnchorsMatchLines]) {
    XCTAssertEqual([self refusalOf:@"^a" from:ODataRegexMatches to:ODataRegexECMAScript].code, ODataIncrementalStoreErrorUnsupportedExpression,
                   @"^ at each line");
    XCTAssertEqualObjects([self write:@"^a$" from:ODataRegexMatches to:ODataRegexMatches], @"(?m:^)a(?m:$)");
  } else {
    XCTAssertEqualObjects([self write:@"^a" from:ODataRegexMatches to:ODataRegexECMAScript], @"^a");
  }
  XCTAssertEqualObjects([self write:@"a\\Z" from:ODataRegexMatches to:ODataRegexECMAScript], @"a(?=(?:\\r\\n|[\\n\\x0B\\f\\r\\x85\\u2028\\u2029])?$)");
}

- (void)testLike
{
  XCTAssertEqualObjects([self write:@"a*b?" from:ODataRegexLike to:ODataRegexMatches], @"a.*b.");
  XCTAssertEqualObjects([self write:@"a.b+(c)" from:ODataRegexLike to:ODataRegexMatches], @"a\\.b\\+\\(c\\)");
  XCTAssertEqualObjects([self write:@"a\\*b" from:ODataRegexLike to:ODataRegexMatches], @"a\\*b");
  XCTAssertEqualObjects([self write:@"a*b?" from:ODataRegexLike to:ODataRegexLike], @"a*b?");
  XCTAssertEqualObjects([self write:@"a\\*" from:ODataRegexLike to:ODataRegexLike], @"a\\*");
  XCTAssertEqualObjects([self write:@"a?" from:ODataRegexLike to:ODataRegexECMAScript], @"a(?:\\r\\n|\\r(?!\\n)|[^\\r])");
  XCTAssertEqual([self refusalOf:@"a+" from:ODataRegexMatches to:ODataRegexLike].code, ODataIncrementalStoreErrorUnsupportedExpression);
}

- (void)testWhatIsNotAPatternAndWhatIsNotReadHere
{
  for (NSString *pattern in @[ @"(", @"a)", @"[a", @"a{3,2}", @"*a", @"a**", @"\\", @"[z-a]", @"\\x4" ]) {
    NSError *error = nil;
    XCTAssertNil([ODataRegex regexWithString:pattern dialect:ODataRegexECMAScript error:&error], @"%@", pattern);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@: %@", pattern, error);
  }
  for (NSString *pattern in @[ @"(a)\\1", @"\\p{L}", @"a++", @"(?i)a", @"[a[b]]", @"(?>a)", @"\\v" ]) {
    NSError *error = nil;
    XCTAssertNil([ODataRegex regexWithString:pattern dialect:ODataRegexMatches error:&error], @"%@", pattern);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedExpression, @"%@: %@", pattern, error);
  }
}

// Built rather than read: what the service's string functions compare.
- (void)testBuilt
{
  ODataRegex *three = [ODataRegex repeat:[ODataRegex any:ODataRegexAnyCodePoint] minimum:3 maximum:3 lazy:NO];
  XCTAssertEqualObjects([three stringInDialect:ODataRegexMatches error:NULL], @"(?:[^\\r]|\\r){3}");
  ODataRegex *needle = [ODataRegex literalString:@"a.b"];
  ODataRegex *before = [ODataRegex repeat:[ODataRegex sequence:@[ [ODataRegex look:needle behind:NO negated:YES], [ODataRegex any:ODataRegexAnyCodePoint] ]]
                                  minimum:2 maximum:2 lazy:NO];
  NSString *found = [[ODataRegex sequence:@[ before, needle ]] stringInDialect:ODataRegexMatches error:NULL];
  XCTAssertEqualObjects(found, @"(?:(?!a\\.b)(?:[^\\r]|\\r)){2}a\\.b");
  NSPredicate *matches = [NSPredicate predicateWithFormat:@"SELF MATCHES %@", found];
  XCTAssertTrue([matches evaluateWithObject:@"\r\na.b"], @"one character at a time: \\r\\n is two");
  XCTAssertEqualObjects([[ODataRegex literalString:@"\U0001F600"] stringInDialect:ODataRegexECMAScript error:NULL], @"\U0001F600");
}

@end
