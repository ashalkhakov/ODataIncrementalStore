// NSPredicate → OData ABNF commonExpr. No network.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Spec: OASIS OData Version 4.0 ABNF (eq / ne / gt / ge / lt / le,
// andExpr / orExpr / notExpr, boolMethodCallExpr startswith/endswith/contains,
// tolower, inExpr). Protocol §11.2.5.1 System Query Option $filter.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"

@interface ODataPredicateTranslatorTests : XCTestCase
@end

@implementation ODataPredicateTranslatorTests {
  ODataPredicateTranslator *_translator;
}

- (void)setUp
{
  [super setUp];
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  NSEntityDescription *product = OISCatalogEntity(@"Product");
  XCTAssertNotNil(product, @"Catalog.xcdatamodeld at %@", OISCatalogModelURL());
  _translator = [[ODataPredicateTranslator alloc] initWithMapper:mapper entity:product];
}

- (void)assertPredicate:(NSString *)format filter:(NSString *)expected
{
  NSError *error = nil;
  NSPredicate *predicate = [NSPredicate predicateWithFormat:format];
  NSString *got = [_translator translatePredicate:predicate error:&error];
  XCTAssertNil(error, @"%@ → %@", format, error);
  XCTAssertEqualObjects(got, expected, @"predicate %@", format);
}

- (void)testComparisonOperatorsMatchABNF
{
  [self assertPredicate:@"unitPrice == 18" filter:@"UnitPrice eq 18"];
  [self assertPredicate:@"unitPrice != 18" filter:@"UnitPrice ne 18"];
  [self assertPredicate:@"unitPrice > 20" filter:@"UnitPrice gt 20"];
  [self assertPredicate:@"unitPrice >= 20" filter:@"UnitPrice ge 20"];
  [self assertPredicate:@"unitPrice < 10" filter:@"UnitPrice lt 10"];
  [self assertPredicate:@"unitPrice <= 10" filter:@"UnitPrice le 10"];
}

- (void)testBooleanAndNullLiterals
{
  [self assertPredicate:@"discontinued == NO" filter:@"Discontinued eq false"];
  [self assertPredicate:@"discontinued == YES" filter:@"Discontinued eq true"];
  [self assertPredicate:@"name == nil" filter:@"ProductName eq null"];
}

- (void)testStringLiteralEscapesQuote
{
  [self assertPredicate:@"name == \"O'Brien\"" filter:@"ProductName eq 'O''Brien'"];
}

- (void)testLogicalConnectives
{
  [self assertPredicate:@"unitPrice > 20 AND discontinued == NO"
                 filter:@"(UnitPrice gt 20) and (Discontinued eq false)"];
  [self assertPredicate:@"unitPrice < 10 OR unitPrice > 100"
                 filter:@"(UnitPrice lt 10) or (UnitPrice gt 100)"];
  [self assertPredicate:@"NOT discontinued == YES" filter:@"not (Discontinued eq true)"];
}

- (void)testCanonicalFunctions
{
  [self assertPredicate:@"name BEGINSWITH \"Ch\"" filter:@"startswith(ProductName, 'Ch')"];
  [self assertPredicate:@"name ENDSWITH \"e\"" filter:@"endswith(ProductName, 'e')"];
  [self assertPredicate:@"name CONTAINS \"lager\"" filter:@"contains(ProductName, 'lager')"];
}

- (void)testCaseInsensitiveUsesTolower
{
  [self assertPredicate:@"name BEGINSWITH[cd] \"ch\""
                 filter:@"startswith(tolower(ProductName), tolower('ch'))"];
  [self assertPredicate:@"name CONTAINS[c] \"IPA\""
                 filter:@"contains(tolower(ProductName), tolower('IPA'))"];
}

- (void)testInAndBetween
{
  [self assertPredicate:@"name IN {\"Chai\", \"Chang\"}"
                 filter:@"ProductName in ('Chai', 'Chang')"];
  [self assertPredicate:@"unitPrice BETWEEN {10, 20}"
                 filter:@"(UnitPrice ge 10 and UnitPrice le 20)"];
}

- (void)testTrueFalsePredicate
{
  [self assertPredicate:@"TRUEPREDICATE" filter:@"true"];
  [self assertPredicate:@"FALSEPREDICATE" filter:@"false"];
}

- (void)testNavigationPathUsesSlash
{
  NSError *error = nil;
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"category.name == %@", @"Beverages"];
  NSString *got = [_translator translatePredicate:predicate error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(got, @"Category/CategoryName eq 'Beverages'");
}

- (void)testUnsupportedPredicateErrors
{
  NSError *error = nil;
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"name MATCHES %@", @".*"];
  NSString *got = [_translator translatePredicate:predicate error:&error];
  XCTAssertNil(got);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorUnsupportedPredicate);
}

@end
