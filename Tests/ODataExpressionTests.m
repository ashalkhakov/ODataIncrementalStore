// OData's URL syntax, parsed: expressions, query options, resource paths.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OASIS OData 4.01 Part 2 (URL Conventions) and its ABNF: section 4
// (resource paths, key predicates), 5.1 (system query options), 5.1.1.14
// (operator precedence), and the literal forms of section 5.1.1.14.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"

@interface ODataExpressionTests : XCTestCase
@end

@implementation ODataExpressionTests

- (ODataExpression *)parse:(NSString *)text
{
  NSError *error = nil;
  ODataExpression *e = [ODataExpression expressionWithString:text error:&error];
  XCTAssertNotNil(e, @"%@: %@", text, error);
  return e;
}

// Parsed, described canonically, and the description parses to itself.
- (void)assertText:(NSString *)text reads:(NSString *)canonical
{
  ODataExpression *e = [self parse:text];
  XCTAssertEqualObjects(e.description, canonical, @"%@", text);
  ODataExpression *again = [self parse:e.description ?: @""];
  XCTAssertEqualObjects(again.description, canonical, @"the description of %@ parses to itself", text);
}

- (void)testComparisonsAndConnectivesRoundTrip
{
  [self assertText:@"UnitPrice gt 20" reads:@"UnitPrice gt 20"];
  [self assertText:@"(UnitPrice gt 20) and (Discontinued eq false)" reads:@"UnitPrice gt 20 and Discontinued eq false"];
  [self assertText:@"not (A eq 1 or B eq 2)" reads:@"not (A eq 1 or B eq 2)"];
  [self assertText:@"A eq 1 or B eq 2 and C eq 3" reads:@"A eq 1 or B eq 2 and C eq 3"];
  [self assertText:@"(A eq 1 or B eq 2) and C eq 3" reads:@"(A eq 1 or B eq 2) and C eq 3"];
  [self assertText:@"ProductID in (1, 2, 3)" reads:@"ProductID in (1,2,3)"];
  [self assertText:@"Flags has Zoo.Features'Mane'" reads:@"Flags has Zoo.Features'Mane'"];
}

- (void)testArithmeticBindsAsThePrecedenceTableSays
{
  ODataExpression *e = [self parse:@"Price add 1 mul 2 gt 10"];
  XCTAssertEqualObjects(e.name, @"gt");
  XCTAssertEqualObjects(e.left.name, @"add");
  XCTAssertEqualObjects(e.left.right.name, @"mul", @"mul binds tighter than add");
  [self assertText:@"(Price add 1) mul 2 gt 10" reads:@"(Price add 1) mul 2 gt 10"];
  [self assertText:@"Price sub (Discount sub 1) lt 5" reads:@"Price sub (Discount sub 1) lt 5"];
  [self assertText:@"-Price lt 0" reads:@"-Price lt 0"];
  [self assertText:@"Price lt -5" reads:@"Price lt -5"];
}

- (void)testLiteralsOfEveryKind
{
  NSDictionary *cases = @{
    @"'it''s'": @[ @"Edm.String", @"it's" ],
    @"42": @[ @"Edm.Int64", @42 ],
    @"32.38": @[ @"Edm.Decimal", [NSDecimalNumber decimalNumberWithString:@"32.38"] ],
    @"1.5E3": @[ @"Edm.Double", @1500.0 ],
    @"true": @[ @"Edm.Boolean", @YES ],
    @"2018-02-11": @[ @"Edm.Date", @"2018-02-11" ],
    @"2024-03-01T14:34:56.1234567+02:00": @[ @"Edm.DateTimeOffset", @"2024-03-01T14:34:56.1234567+02:00" ],
    @"2024-01-01T12:00:00Z": @[ @"Edm.DateTimeOffset", @"2024-01-01T12:00:00Z" ],
    @"13:20:00": @[ @"Edm.TimeOfDay", @"13:20:00" ],
    @"01234567-89ab-cdef-0123-456789abcdef": @[ @"Edm.Guid", @"01234567-89ab-cdef-0123-456789abcdef" ],
    @"deadbeef-89ab-cdef-0123-456789abcdef": @[ @"Edm.Guid", @"deadbeef-89ab-cdef-0123-456789abcdef" ],
    @"duration'P1DT2H'": @[ @"Edm.Duration", @"P1DT2H" ],
    @"binary'AQID'": @[ @"Edm.Binary", @"AQID" ],
    @"NS.Color'Red,Blue'": @[ @"NS.Color", @"Red,Blue" ],
  };
  for (NSString *text in cases) {
    ODataExpression *e = [self parse:[@"X eq " stringByAppendingString:text]].right;
    XCTAssertEqual(e.kind, ODataExpressionLiteral, @"%@", text);
    XCTAssertEqualObjects(e.literalType, cases[text][0], @"%@", text);
    XCTAssertEqualObjects(e.value, cases[text][1], @"%@", text);
    XCTAssertEqualObjects(e.description, text, @"a literal describes itself as written");
  }
  ODataExpression *null = [self parse:@"X eq null"].right;
  XCTAssertEqualObjects(null.value, [NSNull null]);
}

- (void)testPathsLambdasAndFunctions
{
  ODataExpression *e = [self parse:@"Category/CategoryName eq 'Beverages'"];
  XCTAssertEqualObjects(e.left.memberPath, (@[ @"Category", @"CategoryName" ]));

  ODataExpression *any = [self parse:@"Products/any(x0:x0/UnitPrice gt 100)"];
  XCTAssertEqual(any.kind, ODataExpressionLambda);
  XCTAssertEqualObjects(any.operand.memberPath, @[ @"Products" ]);
  XCTAssertEqualObjects(any.variable, @"x0");
  XCTAssertEqual(any.body.left.operand.kind, ODataExpressionVariable, @"x0 is the lambda's variable, not a member");
  [self assertText:@"Products/any(x0:x0/Suppliers/any(x1:x1/City eq 'London'))" reads:@"Products/any(x0:x0/Suppliers/any(x1:x1/City eq 'London'))"];
  [self assertText:@"Emails/any(x0:endswith(x0, 'example.com'))" reads:@"Emails/any(x0:endswith(x0, 'example.com'))"];
  [self assertText:@"Orders/any()" reads:@"Orders/any()"];

  [self assertText:@"startswith(tolower(ProductName),tolower('c'))" reads:@"startswith(tolower(ProductName), tolower('c'))"];
  ODataExpression *age = [self parse:@"Zoo.Age(On=2024-01-01) gt 5"].left;
  XCTAssertEqual(age.kind, ODataExpressionCall);
  XCTAssertEqualObjects(age.namedArguments[@"On"].literalType, @"Edm.Date");
  [self assertText:@"Animals/Zoo.Heaviest()/Name eq 'Leo'" reads:@"Animals/Zoo.Heaviest()/Name eq 'Leo'"];
  [self assertText:@"Orders/$count gt 2" reads:@"Orders/$count gt 2"];
  ODataExpression *cast = [self parse:@"Zoo.Lion/MaxRoar gt 100"].left;
  XCTAssertEqual(cast.operand.kind, ODataExpressionCast);
  [self assertText:@"Name eq @name" reads:@"Name eq @name"];
}

- (void)testSyntaxErrorsSayWhere
{
  for (NSString *bad in @[ @"UnitPrice gt", @"Name eq 'x')", @"(A eq 1", @"Products/any(x0 x0 eq 1)", @"A eq eq 1", @"Zoo.F(1)" ]) {
    NSError *error = nil;
    XCTAssertNil([ODataExpression expressionWithString:bad error:&error], @"%@", bad);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@", bad);
    XCTAssertTrue([error.localizedDescription rangeOfString:@" at "].location != NSNotFound, @"%@", error);
  }
}

- (void)testQueryOptionsNestAsDeepAsTheyGo
{
  NSDictionary *query = @{
    @"$filter": @"Price gt 1",
    @"$orderby": @"Category/Name desc,ProductID",
    @"$select": @"Name,Price",
    @"$expand": @"Category($select=CategoryID;$expand=Products($top=2;$filter=Price gt 1;$orderby=Name)),Supplier/$ref,Photo($levels=max)",
    @"$top": @"5",
    @"$skip": @"10",
    @"$count": @"true",
    @"$skiptoken": @"8",
    @"@p": @"'x'",
    @"custom": @"anything",
  };
  NSError *error = nil;
  ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:query error:&error];
  XCTAssertNotNil(options, @"%@", error);
  XCTAssertEqualObjects(options.filter.description, @"Price gt 1");
  XCTAssertEqual(options.orderBy.count, (NSUInteger)2);
  XCTAssertTrue(options.orderBy[0].descending);
  XCTAssertEqualObjects(options.orderBy[0].expression.memberPath, (@[ @"Category", @"Name" ]));
  XCTAssertEqualObjects([options.select valueForKey:@"description"], (@[ @"Name", @"Price" ]));
  XCTAssertEqual(options.expand.count, (NSUInteger)3);
  ODataExpandItem *category = options.expand[0];
  XCTAssertEqualObjects(category.path, @[ @"Category" ]);
  XCTAssertEqualObjects([category.options.select valueForKey:@"description"], @[ @"CategoryID" ]);
  ODataExpandItem *products = category.options.expand.firstObject;
  XCTAssertEqualObjects(products.options.top, @2);
  XCTAssertEqualObjects(products.options.filter.description, @"Price gt 1");
  XCTAssertTrue(options.expand[1].isRef);
  XCTAssertEqualObjects(options.expand[2].options.levels, @-1);
  XCTAssertEqualObjects(options.top, @5);
  XCTAssertEqualObjects(options.skip, @10);
  XCTAssertEqualObjects(options.includeCount, @YES);
  XCTAssertEqualObjects(options.aliases[@"p"].value, @"x");
  XCTAssertEqualObjects(category.description, @"Category($select=CategoryID;$expand=Products($filter=Price gt 1;$orderby=Name;$top=2))");

  XCTAssertNil([ODataQueryOptions optionsWithQuery:@{ @"$expand": @"Category($select=CategoryID" } error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax);
  XCTAssertNil([ODataQueryOptions optionsWithQuery:@{ @"$top": @"five" } error:&error]);
}

// $search (Part 2 section 5.1.7): NOT, then AND (or nothing), then OR.
- (void)testSearchExpressions
{
  NSDictionary *cases = @{
    @"tea": @"tea",
    @"green tea": @"(green AND tea)",
    @"green AND tea": @"(green AND tea)",
    @"tea OR coffee milk": @"(tea OR (coffee AND milk))",
    @"NOT decaf tea": @"(NOT decaf AND tea)",
    @"(tea OR coffee) NOT decaf": @"((tea OR coffee) AND NOT decaf)",
    @"\"earl grey\" OR \"say \\\"hi\\\"\"": @"(\"earl grey\" OR \"say \\\"hi\\\"\")",
  };
  for (NSString *text in cases) {
    NSError *error = nil;
    ODataSearchExpression *search = [ODataSearchExpression searchWithString:text error:&error];
    XCTAssertNotNil(search, @"%@: %@", text, error);
    XCTAssertEqualObjects(search.description, cases[text], @"%@", text);
    XCTAssertEqualObjects([ODataSearchExpression searchWithString:search.description error:NULL].description, cases[text], @"%@ reads back", text);
  }
  for (NSString *bad in @[ @"", @"AND tea", @"tea OR", @"(tea", @"tea)", @"\"open", @"\"\"" ]) {
    NSError *error = nil;
    XCTAssertNil([ODataSearchExpression searchWithString:bad error:&error], @"%@", bad);
    XCTAssertEqual(error.code, ODataIncrementalStoreErrorSyntax, @"%@", bad);
  }
  ODataSearchExpression *search = [ODataSearchExpression searchWithString:@"(tea OR café) NOT \"iced tea\"" error:NULL];
  XCTAssertTrue([search matchesTexts:@[ @"Green TEA" ]]);
  XCTAssertTrue([search matchesTexts:@[ @"Cafe au lait" ]], @"diacritics aside");
  XCTAssertFalse([search matchesTexts:@[ @"Iced tea, lemon" ]]);
  XCTAssertFalse([search matchesTexts:@[ @"Water" ]]);
  ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:@{ @"$search": @"\"earl grey\" OR mint", @"$expand": @"Items($search=blue green)" } error:NULL];
  XCTAssertEqualObjects(options.searchExpression.description, @"(\"earl grey\" OR mint)");
  XCTAssertEqualObjects([options.expand.firstObject options].searchExpression.description, @"(blue AND green)");
  NSError *error = nil;
  XCTAssertNil([ODataQueryOptions optionsWithQuery:@{ @"$search": @"OR" } error:&error]);
}

// $apply: filter, groupby and aggregate read and written back.
- (void)testApplyTransformations
{
  for (NSString *text in @[ @"aggregate(UnitPrice with sum as Total,$count as N)",
                            @"filter(UnitPrice gt 10)/groupby((Category/CategoryName,Discontinued),aggregate(UnitPrice with max as Top))",
                            @"groupby((Category/CategoryName))/filter(Name eq 'a/b,c')",
                            @"filter(ProductName eq 'it''s (so)')/aggregate(ProductName with countdistinct as Names)" ]) {
    NSError *error = nil;
    NSArray *transformations = [ODataApplyTransformation transformationsWithString:text error:&error];
    XCTAssertNotNil(transformations, @"%@: %@", text, error);
    NSString *written = [ODataApplyTransformation stringForTransformations:transformations];
    XCTAssertEqualObjects([ODataApplyTransformation stringForTransformations:[ODataApplyTransformation transformationsWithString:written error:NULL]], written, @"%@", text);
  }
  NSArray *parsed = [ODataApplyTransformation transformationsWithString:@"groupby((Category/CategoryName),aggregate(UnitPrice with sum as Total))" error:NULL];
  ODataApplyTransformation *groupBy = parsed.firstObject;
  XCTAssertEqual(groupBy.kind, ODataApplyGroupBy);
  XCTAssertEqualObjects(groupBy.groupPaths, (@[ @[ @"Category", @"CategoryName" ] ]));
  XCTAssertEqualObjects([groupBy.aggregates.firstObject alias], @"Total");
  NSDictionary *codes = @{ @"concat(identity,identity)": @(ODataIncrementalStoreErrorUnsupportedExpression),
                           @"aggregate(UnitPrice with Custom.concat as X)": @(ODataIncrementalStoreErrorUnsupportedExpression),
                           @"groupby((rollup($all,Category)))": @(ODataIncrementalStoreErrorUnsupportedExpression),
                           @"aggregate(UnitPrice sum)": @(ODataIncrementalStoreErrorSyntax),
                           @"nonsense": @(ODataIncrementalStoreErrorSyntax), @"": @(ODataIncrementalStoreErrorSyntax) };
  for (NSString *text in codes) {
    NSError *error = nil;
    XCTAssertNil([ODataApplyTransformation transformationsWithString:text error:&error], @"%@", text);
    XCTAssertEqual(error.code, [codes[text] integerValue], @"%@: %@", text, error);
  }
  NSArray *rows = [ODataAggregation groupObjects:@[ @{ @"k": @"a", @"v": @1 }, @{ @"k": @"b", @"v": @2 }, @{ @"k": @"a", @"v": [NSNull null] } ]
                                      byKeyPaths:@[ @"k" ]
                                      aggregates:@[ [ODataAggregate aggregateOfPath:@[ @"v" ] method:@"sum" alias:@"s"],
                                                    [ODataAggregate aggregateOfPath:nil method:nil alias:@"n"] ]];
  XCTAssertEqualObjects(rows, (@[ @{ @"k": @"a", @"s": [NSDecimalNumber one], @"n": @2 },
                                  @{ @"k": @"b", @"s": [NSDecimalNumber decimalNumberWithString:@"2"], @"n": @1 } ]));
}

- (void)testResourcePathsAndKeys
{
  NSError *error = nil;
  ODataResourcePath *path = [ODataResourcePath pathWithString:@"People('russellwhyte')/Trips(0)/Microsoft.X.GetInvolvedPeople()" error:&error];
  XCTAssertNotNil(path, @"%@", error);
  XCTAssertEqual(path.segments.count, (NSUInteger)3);
  XCTAssertEqualObjects(path.segments[0].name, @"People");
  XCTAssertEqualObjects(path.segments[0].keys[@""].value, @"russellwhyte");
  XCTAssertEqualObjects(path.segments[1].keys[@""].value, @0);
  XCTAssertTrue(path.segments[2].isCall);
  XCTAssertEqualObjects(path.description, @"People('russellwhyte')/Trips(0)/Microsoft.X.GetInvolvedPeople()");

  ODataResourcePath *compound = [ODataResourcePath pathWithString:@"OrderItems(OrderID=1,ItemNo=2)/$count" error:&error];
  XCTAssertEqualObjects(compound.segments[0].keys[@"ItemNo"].value, @2);
  XCTAssertEqualObjects(compound.segments[1].name, @"$count");
  ODataResourcePath *segment = [ODataResourcePath pathWithString:@"Products/1" error:&error];
  XCTAssertEqualObjects([segment.segments valueForKey:@"name"], (@[ @"Products", @"1" ]), @"a key as a segment");
}

@end
