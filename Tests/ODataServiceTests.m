// The server's core: ODataService over the Catalog model in memory.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OASIS OData 4.01 Part 1 (Protocol) section 11 (data service requests),
// Part 2 (URL Conventions), JSON Format; and the round trip: the client's
// ODataIncrementalStore talking to the service in-process, with the
// service as its transport.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"

@interface OISServiceResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary *headers;
@property (nonatomic, copy) NSData *data;
@property (nonatomic, readonly) id json;
@property (nonatomic, readonly) NSString *text;
- (NSString *)header:(NSString *)name;
@end

@implementation OISServiceResponse
- (id)json
{
  return self.data.length ? [NSJSONSerialization JSONObjectWithData:self.data options:0 error:NULL] : nil;
}
- (NSString *)text
{
  return [[NSString alloc] initWithData:self.data ?: [NSData data] encoding:NSUTF8StringEncoding];
}
- (NSString *)header:(NSString *)name
{
  for (NSString *key in self.headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return self.headers[key];
  }
  return nil;
}
@end

// Hides discontinued products, and answers fetches later, from another
// thread, as a handler that waits on something would.
@interface OISLaterProducts : ODataEntitySetHandler
@property (nonatomic) NSInteger deferred;
@end

@implementation OISLaterProducts

- (NSPredicate *)predicateForVisibleObjectsInRequest:(ODataRequest *)request
{
  return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"discontinued"]
                                            rightExpression:[NSExpression expressionForConstantValue:@NO]
                                                   modifier:NSDirectPredicateModifier
                                                       type:NSEqualToPredicateOperatorType
                                                    options:0];
}

- (NSArray *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [reply defer];
  self.deferred++;
  NSManagedObjectContext *context = request.context;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [context performBlock:^{
      NSError *error = nil;
      NSArray *rows = [context executeFetchRequest:fetchRequest error:&error];
      if (rows) [reply finishWithResult:rows];
      else [reply failWithError:error];
    }];
  });
  return nil;
}

@end

@interface ODataServiceTests : XCTestCase
@end

@implementation ODataServiceTests {
  NSPersistentStoreCoordinator *_coordinator;
  ODataService *_service;
  dispatch_semaphore_t _finished;
}

- (void)setUp
{
  [super setUp];
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error], @"%@", error);
  [self seed];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator
                                                          serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

- (NSManagedObject *)insert:(NSString *)entity into:(NSManagedObjectContext *)context values:(NSDictionary *)values
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];
  for (NSString *key in values) [object setValue:values[key] forKey:key];
  return object;
}

// A few of Northwind's rows.
- (void)seed
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  NSManagedObject *beverages = [self insert:@"Category" into:context values:@{ @"id": @1, @"name": @"Beverages" }];
  NSManagedObject *condiments = [self insert:@"Category" into:context values:@{ @"id": @2, @"name": @"Condiments" }];
  NSManagedObject *exotic = [self insert:@"Supplier" into:context values:@{ @"id": @1, @"companyName": @"Exotic Liquids", @"city": @"London", @"country": @"UK" }];
  NSManagedObject *cajun = [self insert:@"Supplier" into:context values:@{ @"id": @2, @"companyName": @"New Orleans Cajun Delights", @"city": @"New Orleans", @"country": @"USA" }];
  NSArray *products = @[
    @[ @1, @"Chai", @"18", @NO, beverages, @[ exotic ] ],
    @[ @2, @"Chang", @"19", @NO, beverages, @[ exotic ] ],
    @[ @3, @"Aniseed Syrup", @"10", @NO, condiments, @[ exotic ] ],
    @[ @4, @"Chef Anton's Cajun Seasoning", @"22", @NO, condiments, @[ cajun ] ],
    @[ @5, @"Chef Anton's Gumbo Mix", @"21.35", @YES, condiments, @[ cajun ] ],
  ];
  NSManagedObject *chai = nil;
  for (NSArray *p in products) {
    NSManagedObject *product = [self insert:@"Product" into:context values:@{
      @"id": p[0], @"name": p[1], @"unitPrice": [NSDecimalNumber decimalNumberWithString:p[2]],
      @"discontinued": p[3], @"category": p[4] }];
    [[product mutableSetValueForKey:@"suppliers"] addObjectsFromArray:p[5]];
    if (!chai) chai = product;
  }
  NSManagedObject *warehouse = [self insert:@"Location" into:context values:@{ @"id": @1, @"name": @"Warehouse", @"city": @"Leeds" }];
  [self insert:@"Stock" into:context values:@{ @"id": @1, @"quantity": @40, @"product": chai, @"location": warehouse }];
  NSError *error = nil;
  XCTAssertTrue([context save:&error], @"%@", error);
}

- (NSManagedObject *)productWithID:(NSInteger)identifier in:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"id"]
                                                       rightExpression:[NSExpression expressionForConstantValue:@(identifier)]
                                                              modifier:NSDirectPredicateModifier
                                                                  type:NSEqualToPredicateOperatorType
                                                               options:0];
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

#pragma mark Sending

- (void)exchangeDidFinish:(ODataExchange *)exchange
{
  dispatch_semaphore_signal(_finished);
}

- (OISServiceResponse *)send:(NSString *)method path:(NSString *)path headers:(NSDictionary *)headers body:(id)body
{
  NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
  NSURL *url = [NSURL URLWithString:[@"http://example.test/odata/" stringByAppendingString:encoded]];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = method;
  for (NSString *name in headers) [request setValue:headers[name] forHTTPHeaderField:name];
  if (body) {
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  }
  _finished = dispatch_semaphore_create(0);
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:request target:self action:@selector(exchangeDidFinish:)];
  [_service startExchange:exchange];
  long waited = dispatch_semaphore_wait(_finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
  XCTAssertEqual(waited, 0L, @"%@ %@ did not finish", method, path);
  OISServiceResponse *response = [[OISServiceResponse alloc] init];
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)exchange.URLResponse;
  response.status = http.statusCode;
  response.headers = http.allHeaderFields;
  response.data = exchange.data;
  return response;
}

- (OISServiceResponse *)get:(NSString *)path
{
  return [self send:@"GET" path:path headers:nil body:nil];
}

- (NSArray *)names:(OISServiceResponse *)response
{
  return [response.json[@"value"] valueForKey:@"ProductName"];
}

#pragma mark Documents

- (void)testServiceDocumentAndMetadata
{
  OISServiceResponse *doc = [self get:@""];
  XCTAssertEqual(doc.status, 200);
  XCTAssertEqualObjects([doc header:@"OData-Version"], @"4.01");
  XCTAssertEqualObjects(doc.json[@"@odata.context"], @"http://example.test/odata/$metadata");
  XCTAssertEqualObjects([[doc.json[@"value"] valueForKey:@"name"] sortedArrayUsingSelector:@selector(compare:)],
                        (@[ @"Categories", @"Locations", @"Products", @"Stocks", @"Suppliers" ]));

  OISServiceResponse *metadata = [self get:@"$metadata"];
  XCTAssertEqual(metadata.status, 200);
  XCTAssertTrue([[metadata header:@"Content-Type"] hasPrefix:@"application/xml"]);
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:metadata.data error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  XCTAssertEqualObjects(schema.version, @"4.01");
  XCTAssertEqualObjects(schema.entitySets[@"Products"], @"Default.Product");
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"Default.Product"];
  XCTAssertEqualObjects([schema keyOfEntityType:product], @[ @"ProductID" ]);
  XCTAssertEqualObjects([schema property:@"UnitPrice" ofEntityType:product].type, @"Edm.Decimal");
  XCTAssertEqualObjects([schema navigationProperty:@"Category" ofEntityType:product].partner, @"Products");
  XCTAssertTrue([schema navigationProperty:@"Suppliers" ofEntityType:product].isCollection);

  // The client, given this $metadata, finds the model matches it.
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = schema;
  XCTAssertEqualObjects([mapper problemsWithModel:OISCatalogModel()], @[]);
  XCTAssertEqualObjects(_service.metadataProblems, @[]);

  OISServiceResponse *old = [self send:@"GET" path:@"$metadata" headers:@{ @"OData-MaxVersion": @"4.0" } body:nil];
  XCTAssertEqualObjects([old header:@"OData-Version"], @"4.0");
  XCTAssertEqualObjects([ODataSchema schemaWithData:old.data error:NULL].version, @"4.0");
}

#pragma mark Reading

- (void)testQueryOptions
{
  OISServiceResponse *all = [self get:@"Products"];
  XCTAssertEqual(all.status, 200);
  XCTAssertEqualObjects(all.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products");
  XCTAssertEqual([all.json[@"value"] count], 5u);
  NSDictionary *chai = all.json[@"value"][0];
  XCTAssertEqualObjects(chai[@"ProductID"], @1);
  XCTAssertEqualObjects(chai[@"ProductName"], @"Chai");
  XCTAssertEqualObjects(chai[@"Discontinued"], @NO);
  XCTAssertTrue([chai[@"@odata.etag"] hasPrefix:@"W/\""]);

  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=UnitPrice gt 18&$orderby=UnitPrice desc"]],
                        (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix", @"Chang" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Category/CategoryName eq 'Beverages'"]], (@[ @"Chai", @"Chang" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=startswith(tolower(ProductName),'ch')&$top=2&$skip=1"]],
                        (@[ @"Chang", @"Chef Anton's Cajun Seasoning" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=tolower(ProductName) eq 'Chai'"]], @[], @"tolower never gives an upper-case letter");
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=contains(ProductName,'Anton') and not Discontinued"]],
                        @[ @"Chef Anton's Cajun Seasoning" ]);
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=ProductID in (1,3)"]], (@[ @"Chai", @"Aniseed Syrup" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Suppliers/any(s:s/City eq 'New Orleans')"]],
                        (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Suppliers/all(s:s/Country eq 'UK')"]],
                        (@[ @"Chai", @"Chang", @"Aniseed Syrup" ]));
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=ProductName eq @n&@n='Chang'"]], @[ @"Chang" ]);
  XCTAssertEqualObjects([self names:[self get:@"Products?$filter=Category eq null"]], @[]);

  OISServiceResponse *counted = [self get:@"Products?$count=true&$top=1&$select=ProductName"];
  XCTAssertEqualObjects(counted.json[@"@odata.count"], @5);
  XCTAssertEqualObjects(counted.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products(ProductName)");
  NSMutableSet *keys = [NSMutableSet setWithArray:[counted.json[@"value"][0] allKeys]];
  [keys removeObject:@"@odata.etag"];
  XCTAssertEqualObjects(keys, [NSSet setWithObject:@"ProductName"]);

  OISServiceResponse *count = [self get:@"Products/$count?$filter=UnitPrice lt 20"];
  XCTAssertEqual(count.status, 200);
  XCTAssertEqualObjects(count.text, @"3");
  XCTAssertTrue([[count header:@"Content-Type"] hasPrefix:@"text/plain"]);
}

- (void)testEntitiesPropertiesAndNavigation
{
  OISServiceResponse *chai = [self get:@"Products(1)"];
  XCTAssertEqual(chai.status, 200);
  XCTAssertEqualObjects(chai.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products/$entity");
  XCTAssertEqualObjects(chai.json[@"ProductName"], @"Chai");
  XCTAssertEqualObjects([chai header:@"ETag"], chai.json[@"@odata.etag"]);
  XCTAssertEqualObjects([self get:@"Products/1"].json[@"ProductName"], @"Chai", @"a key as a segment");

  XCTAssertEqualObjects([self get:@"Products(1)/Category"].json[@"CategoryName"], @"Beverages");
  XCTAssertEqualObjects([self names:[self get:@"Categories(2)/Products?$orderby=ProductID desc"]],
                        (@[ @"Chef Anton's Gumbo Mix", @"Chef Anton's Cajun Seasoning", @"Aniseed Syrup" ]));
  XCTAssertEqualObjects([self names:[self get:@"Suppliers(2)/Products"]], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects([self get:@"Categories(2)/Products(3)"].json[@"ProductName"], @"Aniseed Syrup");
  XCTAssertEqual([self get:@"Categories(1)/Products(3)"].status, 404, @"3 is not a beverage");
  XCTAssertEqualObjects([self get:@"Categories(2)/Products/$count"].text, @"3");

  OISServiceResponse *name = [self get:@"Products(4)/ProductName"];
  XCTAssertEqualObjects(name.json[@"value"], @"Chef Anton's Cajun Seasoning");
  XCTAssertEqualObjects(name.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products(4)/ProductName");
  XCTAssertEqualObjects([self get:@"Products(4)/UnitPrice/$value"].text, @"22");
  XCTAssertEqual([self get:@"Locations(1)/Country"].status, 204, @"null");

  XCTAssertEqual([self get:@"Products(99)"].status, 404);
  XCTAssertEqual([self get:@"Products(1)/Nothing"].status, 404);
  XCTAssertEqual([self get:@"Nothing"].status, 404);
}

- (void)testExpand
{
  OISServiceResponse *r = [self get:@"Products?$filter=ProductID eq 1&$expand=Category($select=CategoryName),Suppliers($filter=City eq 'London';$count=true)"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSDictionary *chai = r.json[@"value"][0];
  XCTAssertEqualObjects(chai[@"Category"][@"CategoryName"], @"Beverages");
  XCTAssertNil(chai[@"Category"][@"CategoryID"], @"$select within $expand");
  XCTAssertEqualObjects([chai[@"Suppliers"] valueForKey:@"CompanyName"], @[ @"Exotic Liquids" ]);
  XCTAssertEqualObjects(chai[@"Suppliers@odata.count"], @1);
  XCTAssertEqualObjects(r.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products(Category(CategoryName),Suppliers())");

  OISServiceResponse *nested = [self get:@"Categories(2)?$expand=Products($orderby=UnitPrice desc;$top=1;$expand=Suppliers)"];
  NSArray *products = nested.json[@"Products"];
  XCTAssertEqual(products.count, 1u);
  XCTAssertEqualObjects(products[0][@"ProductName"], @"Chef Anton's Cajun Seasoning");
  XCTAssertEqualObjects([products[0][@"Suppliers"] valueForKey:@"City"], @[ @"New Orleans" ]);

  OISServiceResponse *refs = [self get:@"Categories(1)?$expand=Products/$ref"];
  NSMutableArray *ids = [NSMutableArray array];
  for (NSDictionary *reference in refs.json[@"Products"]) [ids addObject:reference[@"@odata.id"] ?: @""];
  XCTAssertEqualObjects(ids, (@[ @"Products(1)", @"Products(2)" ]));
}

- (void)testServerDrivenPaging
{
  OISServiceResponse *first = [self send:@"GET" path:@"Products?$orderby=ProductName" headers:@{ @"Prefer": @"odata.maxpagesize=2" } body:nil];
  XCTAssertEqualObjects([self names:first], (@[ @"Aniseed Syrup", @"Chai" ]));
  XCTAssertEqualObjects([first header:@"Preference-Applied"], @"odata.maxpagesize=2");
  NSString *next = first.json[@"@odata.nextLink"];
  XCTAssertTrue([next hasPrefix:@"http://example.test/odata/Products?"], @"%@", next);
  NSMutableArray *names = [[self names:first] mutableCopy];
  while (next) {
    NSString *path = [[next substringFromIndex:@"http://example.test/odata/".length] stringByRemovingPercentEncoding];
    OISServiceResponse *page = [self send:@"GET" path:path headers:@{ @"Prefer": @"odata.maxpagesize=2" } body:nil];
    [names addObjectsFromArray:[self names:page]];
    next = page.json[@"@odata.nextLink"];
  }
  XCTAssertEqualObjects(names, (@[ @"Aniseed Syrup", @"Chai", @"Chang", @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));

  _service.maxPageSize = 3;
  OISServiceResponse *topped = [self get:@"Products?$top=4"];
  XCTAssertEqual([topped.json[@"value"] count], 3u);
  NSString *rest = [[topped.json[@"@odata.nextLink"] substringFromIndex:@"http://example.test/odata/".length] stringByRemovingPercentEncoding];
  XCTAssertEqual([[self get:rest].json[@"value"] count], 1u, @"$top counts across pages");
  XCTAssertNil([self get:rest].json[@"@odata.nextLink"]);
}

#pragma mark Writing

- (void)testCreateUpdateDelete
{
  OISServiceResponse *created = [self send:@"POST" path:@"Products" headers:nil body:@{
    @"ProductName": @"Ipoh Coffee", @"UnitPrice": @46, @"Discontinued": @NO,
    @"Category@odata.bind": @"Categories(1)", @"Suppliers@odata.bind": @[ @"http://example.test/odata/Suppliers(1)" ] }];
  XCTAssertEqual(created.status, 201, @"%@", created.text);
  XCTAssertEqualObjects(created.json[@"ProductID"], @6, @"one more than the largest key");
  XCTAssertEqualObjects([created header:@"Location"], @"http://example.test/odata/Products(6)");
  XCTAssertEqualObjects([self get:@"Products(6)/Category"].json[@"CategoryName"], @"Beverages");
  XCTAssertEqualObjects([self get:@"Suppliers(1)/Products/$count"].text, @"4");

  NSString *etag = [created header:@"ETag"];
  OISServiceResponse *stale = [self send:@"PATCH" path:@"Products(6)" headers:@{ @"If-Match": @"W/\"nope\"" } body:@{ @"UnitPrice": @40 }];
  XCTAssertEqual(stale.status, 412);
  XCTAssertNotNil(stale.json[@"error"][@"message"]);

  OISServiceResponse *patched = [self send:@"PATCH" path:@"Products(6)" headers:@{ @"If-Match": etag } body:@{ @"UnitPrice": @40 }];
  XCTAssertEqual(patched.status, 204, @"%@", patched.text);
  XCTAssertNotEqualObjects([patched header:@"ETag"], etag);
  XCTAssertEqualObjects([self get:@"Products(6)/UnitPrice/$value"].text, @"40");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(6)" headers:@{ @"If-Match": etag } body:@{ @"UnitPrice": @1 }].status), 412, @"the old ETag no longer matches");

  OISServiceResponse *represented = [self send:@"PATCH" path:@"Products(6)" headers:@{ @"Prefer": @"return=representation" } body:@{ @"ProductName": @"Ipoh" }];
  XCTAssertEqual(represented.status, 200);
  XCTAssertEqualObjects(represented.json[@"ProductName"], @"Ipoh");
  XCTAssertEqualObjects(represented.json[@"UnitPrice"], @40);

  OISServiceResponse *put = [self send:@"PUT" path:@"Products(6)" headers:nil body:@{ @"ProductName": @"Ipoh Coffee" }];
  XCTAssertEqual(put.status, 204);
  XCTAssertEqual([self get:@"Products(6)/UnitPrice"].status, 204, @"PUT resets what it leaves out");

  XCTAssertEqual(([self send:@"PATCH" path:@"Products(6)" headers:nil body:@{ @"ProductID": @7 }].status), 400, @"keys do not change");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(6)" headers:nil body:@{ @"Colour": @"red" }].status), 400);
  XCTAssertEqual(([self send:@"POST" path:@"Products" headers:nil body:@{ @"ProductName": @"x", @"Category@odata.bind": @"Categories(9)" }].status), 400);

  OISServiceResponse *child = [self send:@"POST" path:@"Categories(2)/Products" headers:@{ @"Prefer": @"return=minimal" } body:@{ @"ProductName": @"Genen Shouyu" }];
  XCTAssertEqual(child.status, 204);
  XCTAssertEqualObjects([child header:@"OData-EntityId"], @"http://example.test/odata/Products(7)");
  XCTAssertEqualObjects([self get:@"Products(7)/Category/CategoryName"].json[@"value"], @"Condiments");

  XCTAssertEqual(([self send:@"DELETE" path:@"Products(6)" headers:nil body:nil].status), 204);
  XCTAssertEqual([self get:@"Products(6)"].status, 404);
  XCTAssertEqualObjects([self get:@"Suppliers(1)/Products/$count"].text, @"3");
}

- (void)testErrors
{
  OISServiceResponse *missing = [self get:@"Nothing(1)"];
  XCTAssertEqual(missing.status, 404);
  XCTAssertTrue([missing.json[@"error"][@"code"] length] > 0);
  XCTAssertTrue([missing.json[@"error"][@"message"] length] > 0);

  XCTAssertEqual([self get:@"Products?$filter=UnitPrice gt"].status, 400, @"does not parse");
  XCTAssertEqual([self get:@"Products?$filter=Colour eq 'red'"].status, 400, @"no such property");
  XCTAssertEqual([self get:@"Products?$filter=ProductName eq 1 add"].status, 400);
  XCTAssertEqual([self get:@"Products?$apply=groupby((Category))"].status, 501);
  XCTAssertEqual([self get:@"Products?$search=chai"].status, 501);
  XCTAssertEqual([self get:@"Products?$filter=Flags has Default.Colour'Red'"].status, 501);
  XCTAssertEqual([self get:@"$batch"].status, 501);
  XCTAssertEqual([self get:@"Products?$format=xml"].status, 406);
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"Accept": @"application/xml" } body:nil].status), 406);
  XCTAssertEqual(([self send:@"GET" path:@"Products" headers:@{ @"OData-Version": @"5.0" } body:nil].status), 400);

  OISServiceResponse *method = [self send:@"POST" path:@"Products(1)" headers:nil body:@{}];
  XCTAssertEqual(method.status, 405);
  XCTAssertNotNil([method header:@"Allow"]);
  XCTAssertEqual(([self send:@"POST" path:@"Products" headers:@{ @"Content-Type": @"text/plain" } body:nil].status), 415);
}

- (void)testMetadataLevels
{
  OISServiceResponse *full = [self send:@"GET" path:@"Products(1)" headers:@{ @"Accept": @"application/json;odata.metadata=full" } body:nil];
  XCTAssertEqualObjects(full.json[@"@odata.id"], @"Products(1)");
  XCTAssertEqualObjects(full.json[@"@odata.type"], @"#Default.Product");
  XCTAssertTrue([[full header:@"Content-Type"] rangeOfString:@"odata.metadata=full"].location != NSNotFound);
  OISServiceResponse *none = [self get:@"Products(1)?$format=application/json;odata.metadata=none"];
  XCTAssertNil(none.json[@"@odata.context"]);
  XCTAssertNil(none.json[@"@odata.etag"]);
  XCTAssertEqualObjects(none.json[@"ProductName"], @"Chai");
  OISServiceResponse *strings = [self send:@"GET" path:@"Products(5)" headers:@{ @"Accept": @"application/json;IEEE754Compatible=true" } body:nil];
  XCTAssertEqualObjects(strings.json[@"UnitPrice"], @"21.35", @"Decimal as a string");
}

#pragma mark Handlers

- (void)testHandlerSeesAndAnswersLater
{
  OISLaterProducts *handler = [[OISLaterProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:handler forEntitySet:@"Products"];
  XCTAssertEqual([[self get:@"Products"].json[@"value"] count], 4u, @"the discontinued one is hidden");
  XCTAssertEqual(handler.deferred, 1);
  XCTAssertEqual([self get:@"Products(5)"].status, 404, @"by key too");
  XCTAssertEqualObjects([self get:@"Products/$count"].text, @"4");
  NSArray *expanded = [self get:@"Categories(2)?$expand=Products"].json[@"Products"];
  XCTAssertEqual(expanded.count, 2u, @"and through $expand");

  handler.allowsDelete = NO;
  XCTAssertEqual(([self send:@"DELETE" path:@"Products(1)" headers:nil body:nil].status), 405);
}

#pragma mark The client, talking to the service

- (void)testIncrementalStoreOverTheService
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  NSPersistentStore *store = [client addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                  configuration:nil
                                                            URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                                        options:@{ ODataIncrementalStoreTransportOption: _service }
                                                          error:&error];
  XCTAssertNotNil(store, @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;

  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 18 AND category.name == 'Condiments'"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  NSArray *rows = [context executeFetchRequest:fetch error:&error];
  XCTAssertNotNil(rows, @"%@", error);
  XCTAssertEqualObjects([rows valueForKey:@"name"], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  NSManagedObject *seasoning = rows.firstObject;
  XCTAssertEqualObjects([seasoning valueForKeyPath:@"category.name"], @"Condiments", @"a fault, fired through the service");
  XCTAssertEqualObjects([[seasoning valueForKey:@"suppliers"] valueForKey:@"city"], [NSSet setWithObject:@"New Orleans"]);

  // Insert, update and delete in one save.
  NSManagedObject *coffee = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:context];
  [coffee setValue:@60 forKey:@"id"];
  [coffee setValue:@"Ipoh Coffee" forKey:@"name"];
  [coffee setValue:[NSDecimalNumber decimalNumberWithString:@"46"] forKey:@"unitPrice"];
  [coffee setValue:[seasoning valueForKey:@"category"] forKey:@"category"];
  [seasoning setValue:[NSDecimalNumber decimalNumberWithString:@"23.5"] forKey:@"unitPrice"];
  [context deleteObject:rows[1]];
  XCTAssertTrue([context save:&error], @"%@", error);

  // What the service's own store now holds.
  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  XCTAssertEqualObjects([[self productWithID:60 in:backing] valueForKeyPath:@"category.name"], @"Condiments");
  XCTAssertEqualObjects([[self productWithID:4 in:backing] valueForKey:@"unitPrice"], [NSDecimalNumber decimalNumberWithString:@"23.5"]);
  XCTAssertNil([self productWithID:5 in:backing]);

  // A change made behind the client's back is a conflict at its next save.
  NSManagedObject *behind = [self productWithID:4 in:backing];
  [behind setValue:@"Seasoning" forKey:@"name"];
  XCTAssertTrue([backing save:&error], @"%@", error);
  [seasoning setValue:[NSDecimalNumber decimalNumberWithString:@"24"] forKey:@"unitPrice"];
  XCTAssertFalse([context save:&error]);
}

@end
