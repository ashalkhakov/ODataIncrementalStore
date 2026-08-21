// NSFetchRequest → OData system query options. No network.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Spec: OASIS OData 4.0 Protocol §11.2.5 System Query Options
// ($filter, $orderby, $top, $skip, $select, $expand) and §11.2.5.5 /$count.

#import <XCTest/XCTest.h>
#import "OISTestSupport.h"

@interface ODataQueryBuilderTests : XCTestCase
@end

@implementation ODataQueryBuilderTests {
  ODataQueryBuilder *_builder;
}

- (void)setUp
{
  [super setUp];
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  _builder = [[ODataQueryBuilder alloc] initWithMapper:mapper serviceRoot:OISTestServiceRoot()];
}

- (NSDictionary *)queryFromURL:(NSURL *)url
{
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  NSString *query = url.query;
  if (!query.length) return out;
  for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
    NSRange eq = [pair rangeOfString:@"="];
    if (eq.location == NSNotFound) continue;
    NSString *name = [pair substringToIndex:eq.location];
    NSString *value = [pair substringFromIndex:eq.location + 1];
#ifdef __APPLE__
    value = [value stringByRemovingPercentEncoding] ?: value;
#else
    value = [value stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding] ?: value;
#endif
    out[name] = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
  }
  return out;
}

- (void)testFilterOrderbyTop
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = OISProductEntity();
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:OISProductEntity() error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects(url.path, @"/V4/Northwind.svc/Products");
  NSDictionary *q = [self queryFromURL:url];
  XCTAssertEqualObjects(q[@"$filter"], @"(UnitPrice gt 20) and (Discontinued eq false)");
  XCTAssertEqualObjects(q[@"$orderby"], @"ProductName");
  XCTAssertEqualObjects(q[@"$top"], @"25");
}

- (void)testSkipAndExpand
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = OISProductEntity();
  fetch.fetchOffset = 10;
  fetch.relationshipKeyPathsForPrefetching = @[ @"category" ];
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:OISProductEntity() error:&error];
  XCTAssertNil(error);
  NSDictionary *q = [self queryFromURL:url];
  XCTAssertEqualObjects(q[@"$skip"], @"10");
  XCTAssertEqualObjects(q[@"$expand"], @"Category");
}

- (void)testCountPath
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = OISProductEntity();
  fetch.resultType = NSCountResultType;
  fetch.predicate = [NSPredicate predicateWithFormat:@"discontinued == NO"];
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:OISProductEntity() error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([url.path hasSuffix:@"/Products/$count"]);
  XCTAssertEqualObjects([self queryFromURL:url][@"$filter"], @"Discontinued eq false");
}

- (void)testSelectFromDictionaryResult
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = OISProductEntity();
  fetch.resultType = NSDictionaryResultType;
  fetch.propertiesToFetch = @[ @"name", @"unitPrice" ];
  NSError *error = nil;
  NSURL *url = [_builder URLForFetch:fetch entity:OISProductEntity() error:&error];
  XCTAssertNil(error);
  XCTAssertEqualObjects([self queryFromURL:url][@"$select"], @"ProductName,UnitPrice");
}

- (void)testEntityByKeyAndNavigation
{
  ODataResourceIdentifier *id1 =
      [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @1 }];
  NSError *error = nil;
  NSURL *url = [_builder URLForIdentifier:id1 error:&error];
  XCTAssertNil(error);
  XCTAssertTrue([url.path hasSuffix:@"/Products(1)"]);
  NSRelationshipDescription *rel = OISProductEntity().relationshipsByName[@"category"];
  NSURL *nav = [_builder URLForIdentifier:id1 relationship:rel error:&error];
  XCTAssertTrue([nav.path hasSuffix:@"/Products(1)/Category"]);
}

@end
