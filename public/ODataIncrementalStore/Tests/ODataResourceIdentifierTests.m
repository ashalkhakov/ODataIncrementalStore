// Resource path keys — OData ABNF keyPredicate / simpleKey / compoundKey.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import <XCTest/XCTest.h>
#import "OISTestSupport.h"

@interface ODataResourceIdentifierTests : XCTestCase
@end

@implementation ODataResourceIdentifierTests

- (void)testSimpleNumericKey
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @1 }];
  XCTAssertEqualObjects(id1.path, @"Products(1)");
}

- (void)testSimpleStringKeyQuotes
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Categories" keys:@{ @"CategoryName": @"Beverages" }];
  XCTAssertEqualObjects(id1.path, @"Categories('Beverages')");
}

- (void)testCompoundKeyNamed
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Order_Details"
                                                    keys:@{ @"OrderID": @10248, @"ProductID": @11 }];
  XCTAssertEqualObjects(id1.path, @"Order_Details(OrderID=10248,ProductID=11)");
}

- (void)testRoundTripThroughJSONData
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @42 }];
  ODataResourceIdentifier *id2 = [ODataResourceIdentifier identifierFromReference:id1.data];
  XCTAssertEqualObjects(id2.path, id1.path);
  XCTAssertEqualObjects(id2.entitySet, @"Products");
}

- (void)testStringKeyEscapesQuote
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Employees" keys:@{ @"LastName": @"O'Brien" }];
  XCTAssertEqualObjects(id1.path, @"Employees('O''Brien')");
}

@end
