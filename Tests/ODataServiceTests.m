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

#pragma mark Operations, declared in protocols

@class OISServedProduct;

@protocol OISProductFunctions <ODataFunctions>
- (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply;
- (OISServedProduct *)cheapestInCategory:(ODataReply *)reply;
+ (NSArray *)pricierThanPrice:(double)price reply:(ODataReply *)reply;
@end

@protocol OISProductActions <ODataActions>
- (void)raisePriceByPercent:(double)percent reply:(ODataReply *)reply;
- (NSDecimalNumber *)discontinueWithReason:(NSString *)reason reply:(ODataReply *)reply;
@end

@interface OISServedProduct : NSManagedObject <OISProductFunctions, OISProductActions>
@end

@implementation OISServedProduct

+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"pricierThanPrice:reply:": @"Collection(Default.Product)" };
}

- (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply
{
  NSDecimalNumber *factor = [NSDecimalNumber decimalNumberWithMantissa:(unsigned long long)(100 - percent) exponent:-2 isNegative:NO];
  return [[self valueForKey:@"unitPrice"] decimalNumberByMultiplyingBy:factor];
}

- (OISServedProduct *)cheapestInCategory:(ODataReply *)reply
{
  NSArray *siblings = [[self valueForKeyPath:@"category.products"] allObjects];
  return [siblings sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"unitPrice" ascending:YES] ]].firstObject;
}

// Bound to the collection it is called on: all of Products, or a
// category's.
+ (NSArray *)pricierThanPrice:(double)price reply:(ODataReply *)reply
{
  NSFetchRequest *fetch = [reply.request.collectionFetchRequest copy];
  NSPredicate *pricier = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"unitPrice"]
                                                            rightExpression:[NSExpression expressionForConstantValue:@(price)]
                                                                   modifier:NSDirectPredicateModifier
                                                                       type:NSGreaterThanPredicateOperatorType
                                                                    options:0];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[ fetch.predicate, pricier ]];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  NSError *error = nil;
  NSArray *rows = [reply.request.context executeFetchRequest:fetch error:&error];
  if (!rows) [reply failWithError:error];
  return rows;
}

- (void)raisePriceByPercent:(double)percent reply:(ODataReply *)reply
{
  NSDecimalNumber *factor = [NSDecimalNumber decimalNumberWithMantissa:(unsigned long long)(100 + percent) exponent:-2 isNegative:NO];
  [self setValue:[[self valueForKey:@"unitPrice"] decimalNumberByMultiplyingBy:factor] forKey:@"unitPrice"];
}

// Answers later, from another thread, through the request's context.
- (NSDecimalNumber *)discontinueWithReason:(NSString *)reason reply:(ODataReply *)reply
{
  [reply defer];
  NSManagedObjectContext *context = reply.request.context;
  NSManagedObjectID *objectID = self.objectID;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [context performBlock:^{
      NSManagedObject *product = [context objectWithID:objectID];
      if ([reason length] == 0) {
        [reply failWithError:ODataServiceError(400, @"Say why")];
        return;
      }
      [product setValue:@YES forKey:@"discontinued"];
      [reply finishWithResult:[product valueForKey:@"unitPrice"]];
    }];
  });
  return nil;
}

@end

@protocol OISCatalogFunctions <ODataFunctions>
- (int32_t)countProductsCheaperThanPrice:(double)price reply:(ODataReply *)reply;
- (NSString *)echoWithText:(NSString *)text times:(int32_t)times reply:(ODataReply *)reply;
- (NSDecimalNumber *)sumOfPrices:(NSArray *)prices reply:(ODataReply *)reply;
- (NSArray *)namesInCategory:(ODataReply *)reply;
@end

@protocol OISCatalogActions <ODataActions>
- (void)failWithCode:(int32_t)code reply:(ODataReply *)reply;
@end

@interface OISCatalogOperations : NSObject <OISCatalogFunctions, OISCatalogActions>
@end

@implementation OISCatalogOperations

+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"sumOfPrices:reply:.prices": @"Collection(Edm.Decimal)",
            @"namesInCategory:": @"Collection(Edm.String)" };
}

+ (NSDictionary *)ODataOperationNames
{
  return @{ @"namesInCategory:": @"ProductNames" };
}

- (int32_t)countProductsCheaperThanPrice:(double)price reply:(ODataReply *)reply
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"unitPrice"]
                                                       rightExpression:[NSExpression expressionForConstantValue:@(price)]
                                                              modifier:NSDirectPredicateModifier
                                                                  type:NSLessThanPredicateOperatorType
                                                               options:0];
  return (int32_t)[reply.request.context countForFetchRequest:fetch error:NULL];
}

- (NSString *)echoWithText:(NSString *)text times:(int32_t)times reply:(ODataReply *)reply
{
  NSMutableString *echo = [NSMutableString string];
  for (int32_t i = 0; i < times; i++) [echo appendString:text ?: @"?"];
  return echo;
}

- (NSDecimalNumber *)sumOfPrices:(NSArray *)prices reply:(ODataReply *)reply
{
  NSDecimalNumber *sum = [NSDecimalNumber zero];
  for (NSDecimalNumber *price in prices) sum = [sum decimalNumberByAdding:price];
  return sum;
}

- (NSArray *)namesInCategory:(ODataReply *)reply
{
  return @[ @"Chai", @"Chang" ];
}

- (void)failWithCode:(int32_t)code reply:(ODataReply *)reply
{
  [reply failWithError:ODataServiceError(code, @"Failing on purpose")];
}

@end

// Declarations the service cannot use, each for its own reason.
@protocol OISBadFunctions <ODataFunctions>
- (NSNumber *)mystery:(ODataReply *)reply;
- (NSString *)noReply;
- (void)nothing:(ODataReply *)reply;
@end

@interface OISBadOperations : NSObject <OISBadFunctions>
@end

@implementation OISBadOperations
- (NSNumber *)mystery:(ODataReply *)reply { return @1; }
- (NSString *)noReply { return @""; }
- (void)nothing:(ODataReply *)reply {}
@end

// Defers, and never answers.
@interface OISSilentProducts : ODataEntitySetHandler
@end

@implementation OISSilentProducts
- (NSArray *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [reply defer];
  return nil;
}
@end

@interface ODataServiceTests : XCTestCase
@end

@implementation ODataServiceTests {
  NSPersistentStoreCoordinator *_coordinator;
  ODataService *_service;
  dispatch_semaphore_t _finished;
  NSMutableArray<NSURL *> *_storeFiles;
}

- (void)setUp
{
  [super setUp];
  _storeFiles = [NSMutableArray array];
  [self serveModel:OISCatalogModel()];
}

- (void)tearDown
{
  for (NSURL *url in _storeFiles) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
      [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
    }
  }
  [super tearDown];
}

// A service over the Catalog rows in memory, in this model.
- (void)serveModel:(NSManagedObjectModel *)model
{
  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
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
  XCTAssertEqual([self get:@"$batch"].status, 405, @"$batch takes POST");
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

#pragma mark Operations

// The Catalog model, with Product's objects of a class that declares
// operations, and the service's own.
- (void)serveOperations
{
  // A model of its own to change: a copy (FreeCoreData's can be copied
  // since #43), else loaded again.
  NSManagedObjectModel *model = [OISCatalogModel() conformsToProtocol:@protocol(NSCopying)]
      ? [OISCatalogModel() copy]
      : [[NSManagedObjectModel alloc] initWithContentsOfURL:OISCatalogModelURL()];
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  product.managedObjectClassName = @"OISServedProduct";
  [self serveModel:model];
  _service.serviceOperations = [[OISCatalogOperations alloc] init];
}

- (void)testOperationsInMetadata
{
  [self serveOperations];
  XCTAssertEqualObjects(_service.operationProblems, @[]);
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"Default.Product"];

  ODataSchemaOperation *discount = [schema operationNamed:@"DiscountedPriceByPercent" boundToEntityType:product collection:NO parameterNames:nil];
  XCTAssertNotNil(discount);
  XCTAssertFalse(discount.isAction);
  XCTAssertEqualObjects([discount.callerParameters valueForKey:@"name"], @[ @"Percent" ]);
  XCTAssertEqualObjects([discount.callerParameters valueForKey:@"type"], @[ @"Edm.Double" ]);
  XCTAssertEqualObjects(discount.returnType, @"Edm.Decimal");

  ODataSchemaOperation *pricier = [schema operationNamed:@"PricierThanPrice" boundToEntityType:product collection:YES parameterNames:nil];
  XCTAssertEqualObjects(pricier.returnType, @"Collection(Default.Product)");
  XCTAssertEqualObjects([schema operationNamed:@"CheapestInCategory" boundToEntityType:product collection:NO parameterNames:nil].returnType, @"Default.Product");
  ODataSchemaOperation *discontinue = [schema operationNamed:@"Discontinue" boundToEntityType:product collection:NO parameterNames:nil];
  XCTAssertTrue(discontinue.isAction);
  XCTAssertEqualObjects([discontinue.callerParameters valueForKey:@"name"], @[ @"Reason" ]);

  XCTAssertEqualObjects(schema.operationImports[@"CountProductsCheaperThanPrice"].operation, @"Default.CountProductsCheaperThanPrice");
  XCTAssertEqualObjects(schema.operationImports[@"ProductNames"].operation, @"Default.ProductNames", @"renamed");
  XCTAssertTrue(schema.operationImports[@"Fail"].isAction);
  NSArray *echo = [schema.operations[@"Default.Echo"] valueForKey:@"callerParameters"];
  XCTAssertEqualObjects([echo.firstObject valueForKey:@"name"], (@[ @"Text", @"Times" ]));
}

- (void)testFunctions
{
  [self serveOperations];
  OISServiceResponse *discount = [self get:@"Products(1)/Default.DiscountedPriceByPercent(Percent=10)"];
  XCTAssertEqual(discount.status, 200, @"%@", discount.text);
  XCTAssertEqualObjects([discount.json[@"value"] description], @"16.2");
  XCTAssertEqualObjects(discount.json[@"@odata.context"], @"http://example.test/odata/$metadata#Edm.Decimal");

  OISServiceResponse *cheapest = [self get:@"Products(4)/Default.CheapestInCategory()"];
  XCTAssertEqualObjects(cheapest.json[@"ProductName"], @"Aniseed Syrup");
  XCTAssertEqualObjects(cheapest.json[@"@odata.context"], @"http://example.test/odata/$metadata#Products/$entity");

  XCTAssertEqualObjects([self names:[self get:@"Products/Default.PricierThanPrice(Price=19)"]],
                        (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects([self names:[self get:@"Categories(1)/Products/Default.PricierThanPrice(Price=18)"]], @[ @"Chang" ],
                        @"bound to the category's products only");

  XCTAssertEqualObjects([self get:@"CountProductsCheaperThanPrice(Price=19)"].json[@"value"], @2);
  XCTAssertEqualObjects([self get:@"Echo(Text='ha',Times=3)"].json[@"value"], @"hahaha");
  XCTAssertEqualObjects([self get:@"Echo(Text=@t,Times=2)?@t='yo'"].json[@"value"], @"yoyo", @"a parameter alias");
  XCTAssertEqualObjects([[self get:@"SumOfPrices(Prices=@p)?@p=[1.5,2.25]"].json[@"value"] description], @"3.75", @"a JSON alias");
  OISServiceResponse *names = [self get:@"ProductNames()"];
  XCTAssertEqualObjects(names.json[@"value"], (@[ @"Chai", @"Chang" ]));
  XCTAssertEqualObjects(names.json[@"@odata.context"], @"http://example.test/odata/$metadata#Collection(Edm.String)");

  XCTAssertEqual(([self send:@"POST" path:@"Products(1)/Default.DiscountedPriceByPercent(Percent=10)" headers:nil body:@{}].status), 405);
  XCTAssertEqual([self get:@"Products(1)/Default.DiscountedPriceByPercent()"].status, 400, @"needs Percent");
  XCTAssertEqual([self get:@"Products(1)/Default.DiscountedPriceByPercent(Percent=10,Extra=1)"].status, 400);
  XCTAssertEqual([self get:@"Products(1)/Default.DiscountedPriceByPercent(Percent='x')"].status, 400);
  XCTAssertEqual([self get:@"Products(1)/Default.Nothing()"].status, 501);
  XCTAssertEqual([self get:@"Products(1)/Default.DiscountedPriceByPercent(Percent=10)/Foo"].status, 400, @"a value cannot be read on from");
}

- (void)testActions
{
  [self serveOperations];
  OISServiceResponse *raised = [self send:@"POST" path:@"Products(1)/Default.RaisePriceByPercent" headers:nil body:@{ @"Percent": @50 }];
  XCTAssertEqual(raised.status, 204, @"%@", raised.text);
  XCTAssertEqualObjects([self get:@"Products(1)/UnitPrice/$value"].text, @"27", @"saved");
  XCTAssertEqual([self get:@"Products(1)/Default.RaisePriceByPercent"].status, 405);

  OISServiceResponse *discontinued = [self send:@"POST" path:@"Products(2)/Default.Discontinue" headers:nil body:@{ @"Reason": @"old" }];
  XCTAssertEqual(discontinued.status, 200, @"%@", discontinued.text);
  XCTAssertEqualObjects([discontinued.json[@"value"] description], @"19", @"answered later");
  XCTAssertEqualObjects([self get:@"Products(2)/Discontinued"].json[@"value"], @YES, @"and saved");
  XCTAssertEqual(([self send:@"POST" path:@"Products(3)/Default.Discontinue" headers:nil body:@{ @"Reason": @"" }].status), 400,
                 @"a deferred failure");
  XCTAssertEqualObjects([self get:@"Products(3)/Discontinued"].json[@"value"], @NO);

  OISServiceResponse *failed = [self send:@"POST" path:@"Fail" headers:nil body:@{ @"Code": @409 }];
  XCTAssertEqual(failed.status, 409);
  XCTAssertEqualObjects(failed.json[@"error"][@"message"], @"Failing on purpose");
  XCTAssertEqual(([self send:@"POST" path:@"Fail" headers:nil body:@{ @"Colour": @1 }].status), 400);
}

- (void)testDeclarationsTheServiceCannotUse
{
  _service.serviceOperations = [[OISBadOperations alloc] init];
  NSArray *problems = _service.operationProblems;
  XCTAssertEqual(problems.count, 3u, @"%@", problems);
  NSString *all = [problems componentsJoinedByString:@"\n"];
  for (NSString *selector in @[ @"mystery:", @"noReply", @"nothing:" ]) {
    XCTAssertTrue([all rangeOfString:selector].location != NSNotFound, @"%@ in %@", selector, all);
  }
  XCTAssertTrue([[self get:@"$metadata"].text rangeOfString:@"Mystery"].location == NSNotFound);
}

// The client, calling the service's operations as it calls any service's.
- (void)testClientCallsOperations
{
  [self serveOperations];
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: _service } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertNotNil(chai, @"%@", error);

  id discounted = [chai invokeODataOperation:@"DiscountedPriceByPercent" parameters:@{ @"Percent": @10 } error:&error];
  XCTAssertEqualObjects([discounted description], @"16.2", @"%@", error);
  ODataOperationCall *call = [ODataOperationCall callOfOperation:@"CountProductsCheaperThanPrice" inContext:context];
  call.parameters = @{ @"Price": @19 };
  XCTAssertEqualObjects([call invoke:&error], @2, @"%@", error);
  id nothing = [chai invokeODataOperation:@"RaisePriceByPercent" parameters:@{ @"Percent": @50 } error:&error];
  XCTAssertTrue(nothing == nil || nothing == [NSNull null], @"%@", nothing);
  XCTAssertNil(error);
  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  XCTAssertEqualObjects([[self productWithID:1 in:backing] valueForKey:@"unitPrice"], [NSDecimalNumber decimalNumberWithString:@"27"]);
}

#pragma mark $batch

// A multipart $batch body: each unit a request ({method, url, body,
// headers, id}), or an array of them, a change set.
- (NSData *)multipartBatch:(NSArray *)units boundary:(NSString *)boundary
{
  NSMutableString *out = [NSMutableString string];
  NSUInteger changeSets = 0;
  for (id unit in units) {
    NSArray *requests = [unit isKindOfClass:[NSArray class]] ? unit : @[ unit ];
    NSString *into = boundary;
    if ([unit isKindOfClass:[NSArray class]]) {
      into = [NSString stringWithFormat:@"changeset_%lu", (unsigned long)++changeSets];
      [out appendFormat:@"--%@\r\nContent-Type: multipart/mixed; boundary=%@\r\n\r\n", boundary, into];
    }
    for (NSDictionary *request in requests) {
      [out appendFormat:@"--%@\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\n", into];
      if (request[@"id"]) [out appendFormat:@"Content-ID: %@\r\n", request[@"id"]];
      [out appendFormat:@"\r\n%@ %@ HTTP/1.1\r\n", request[@"method"], request[@"url"]];
      for (NSString *name in request[@"headers"]) [out appendFormat:@"%@: %@\r\n", name, request[@"headers"][name]];
      NSString *body = @"";
      if (request[@"body"]) {
        body = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:request[@"body"] options:0 error:NULL] encoding:NSUTF8StringEncoding];
        [out appendString:@"Content-Type: application/json\r\n"];
      }
      [out appendFormat:@"\r\n%@\r\n", body];
    }
    if ([unit isKindOfClass:[NSArray class]]) [out appendFormat:@"--%@--\r\n", into];
  }
  [out appendFormat:@"--%@--\r\n", boundary];
  return [out dataUsingEncoding:NSUTF8StringEncoding];
}

- (OISServiceResponse *)postBatch:(NSArray *)units headers:(NSDictionary *)extra
{
  NSURL *url = [NSURL URLWithString:@"http://example.test/odata/$batch"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  request.HTTPMethod = @"POST";
  [request setValue:@"multipart/mixed; boundary=batch_1" forHTTPHeaderField:@"Content-Type"];
  for (NSString *name in extra) [request setValue:extra[name] forHTTPHeaderField:name];
  request.HTTPBody = [self multipartBatch:units boundary:@"batch_1"];
  return [self exchange:request];
}

- (OISServiceResponse *)exchange:(NSURLRequest *)request
{
  _finished = dispatch_semaphore_create(0);
  ODataExchange *exchange = [[ODataExchange alloc] initWithRequest:request target:self action:@selector(exchangeDidFinish:)];
  [_service startExchange:exchange];
  XCTAssertEqual(dispatch_semaphore_wait(_finished, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC))), 0L);
  OISServiceResponse *response = [[OISServiceResponse alloc] init];
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)exchange.URLResponse;
  response.status = http.statusCode;
  response.headers = http.allHeaderFields;
  response.data = exchange.data;
  return response;
}

- (NSArray<ODataBatchPart *> *)partsOf:(OISServiceResponse *)response
{
  NSString *boundary = ODataMultipartBoundary([response header:@"Content-Type"] ?: @"");
  XCTAssertNotNil(boundary, @"%@", [response header:@"Content-Type"]);
  return boundary ? ODataBatchParts(response.data, boundary) : @[];
}

- (id)JSONOf:(ODataBatchPart *)part
{
  return part.body.length ? [NSJSONSerialization JSONObjectWithData:part.body options:0 error:NULL] : nil;
}

- (void)testMultipartBatchWithAChangeSet
{
  OISServiceResponse *r = [self postBatch:@[
    @{ @"method": @"GET", @"url": @"Products(1)" },
    @[ @{ @"method": @"POST", @"url": @"Categories", @"id": @"1", @"body": @{ @"CategoryName": @"Seafood" } },
       @{ @"method": @"POST", @"url": @"$1/Products", @"id": @"2", @"body": @{ @"ProductName": @"Ikura" } },
       @{ @"method": @"PATCH", @"url": @"http://example.test/odata/Products(2)", @"id": @"3", @"body": @{ @"UnitPrice": @20 } } ],
    @{ @"method": @"GET", @"url": @"/odata/Categories(3)/Products?$select=ProductName" },
  ] headers:nil];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray<ODataBatchPart *> *parts = [self partsOf:r];
  XCTAssertEqualObjects([parts valueForKey:@"status"], (@[ @200, @201, @201, @204, @200 ]));
  XCTAssertEqualObjects([self JSONOf:parts[0]][@"ProductName"], @"Chai");
  XCTAssertNil(parts[0].changeSet);
  XCTAssertNotNil(parts[1].changeSet, @"the change set's responses come in a change set of their own");
  XCTAssertEqualObjects([parts valueForKey:@"contentID"][1], @"1");
  XCTAssertEqualObjects([self JSONOf:parts[1]][@"CategoryID"], @3);
  XCTAssertEqualObjects([[self JSONOf:parts[4]][@"value"] valueForKey:@"ProductName"], @[ @"Ikura" ], @"$1 was the new category");
  XCTAssertEqualObjects([self get:@"Products(2)/UnitPrice/$value"].text, @"20");
}

- (void)testFailedChangeSetTakesNoEffect
{
  OISServiceResponse *r = [self postBatch:@[
    @[ @{ @"method": @"POST", @"url": @"Categories", @"id": @"1", @"body": @{ @"CategoryName": @"Seafood" } },
       @{ @"method": @"PATCH", @"url": @"Products(1)", @"id": @"2", @"headers": @{ @"If-Match": @"W/\"stale\"" }, @"body": @{ @"UnitPrice": @1 } } ],
    @{ @"method": @"GET", @"url": @"Categories/$count" },
  ] headers:nil];
  XCTAssertEqual(r.status, 200);
  NSArray<ODataBatchPart *> *parts = [self partsOf:r];
  XCTAssertEqualObjects([parts valueForKey:@"status"], @[ @412 ], @"the failure alone, and the batch stops");
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"2", @"the category was not created");

  r = [self postBatch:@[
    @[ @{ @"method": @"POST", @"url": @"Categories", @"id": @"1", @"body": @{ @"CategoryName": @"Seafood" } },
       @{ @"method": @"POST", @"url": @"Products", @"id": @"2", @"body": @{ @"ProductName": @"X", @"Category@odata.bind": @"Categories(99)" } } ],
    @{ @"method": @"GET", @"url": @"Categories/$count" },
    @{ @"method": @"GET", @"url": @"Nothing" },
    @{ @"method": @"GET", @"url": @"Products(1)/ProductName" },
  ] headers:@{ @"Prefer": @"odata.continue-on-error" }];
  parts = [self partsOf:r];
  XCTAssertEqualObjects([parts valueForKey:@"status"], (@[ @400, @200, @404, @200 ]));
  XCTAssertEqualObjects([[NSString alloc] initWithData:parts[1].body encoding:NSUTF8StringEncoding], @"2");
  XCTAssertEqualObjects([r header:@"Preference-Applied"], @"odata.continue-on-error");

  parts = [self partsOf:[self postBatch:@[ @{ @"method": @"GET", @"url": @"Nothing" }, @{ @"method": @"GET", @"url": @"Products(1)" } ] headers:nil]];
  XCTAssertEqualObjects([parts valueForKey:@"status"], @[ @404 ], @"stops at the first failure");
  parts = [self partsOf:[self postBatch:@[ @[ @{ @"method": @"GET", @"url": @"Products(1)" } ] ] headers:nil]];
  XCTAssertEqualObjects([parts valueForKey:@"status"], @[ @400 ], @"no reads in a change set");
}

- (void)testJSONBatch
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/odata/$batch"]];
  request.HTTPMethod = @"POST";
  [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  NSDictionary *batch = @{ @"requests": @[
    @{ @"id": @"c", @"atomicityGroup": @"g1", @"method": @"post", @"url": @"Categories", @"body": @{ @"CategoryName": @"Seafood" } },
    @{ @"id": @"p", @"atomicityGroup": @"g1", @"method": @"post", @"url": @"$c/Products", @"body": @{ @"ProductName": @"Ikura" } },
    @{ @"id": @"r", @"method": @"get", @"url": @"Categories(3)/Products/$count" },
    @{ @"id": @"x", @"atomicityGroup": @"g2", @"method": @"post", @"url": @"Categories", @"body": @{ @"CategoryName": @"Grains" } },
    @{ @"id": @"y", @"atomicityGroup": @"g2", @"method": @"patch", @"url": @"Products(1)", @"headers": @{ @"If-Match": @"W/\"stale\"" }, @"body": @{ @"UnitPrice": @1 } },
  ] };
  request.HTTPBody = [NSJSONSerialization dataWithJSONObject:batch options:0 error:NULL];
  [request setValue:@"odata.continue-on-error" forHTTPHeaderField:@"Prefer"];
  OISServiceResponse *r = [self exchange:request];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  NSArray *responses = r.json[@"responses"];
  XCTAssertEqualObjects([responses valueForKey:@"id"], (@[ @"c", @"p", @"r", @"x", @"y" ]));
  XCTAssertEqualObjects([responses valueForKey:@"status"], (@[ @201, @201, @200, @424, @412 ]));
  XCTAssertEqualObjects(responses[1][@"body"][@"ProductName"], @"Ikura");
  XCTAssertEqualObjects(responses[2][@"body"], @"1", @"a text body stays text");
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"3", @"g1 saved, g2 not");
}

- (void)testBatchWaitsForHandlersThatAnswerLater
{
  OISLaterProducts *handler = [[OISLaterProducts alloc] initWithEntity:OISCatalogEntity(@"Product")];
  [_service setHandler:handler forEntitySet:@"Products"];
  NSArray<ODataBatchPart *> *parts = [self partsOf:[self postBatch:@[
    @{ @"method": @"GET", @"url": @"Products?$select=ProductName" },
    @[ @{ @"method": @"PATCH", @"url": @"Categories(1)", @"body": @{ @"CategoryName": @"Drinks" } } ],
    @{ @"method": @"GET", @"url": @"Products/$count" },
  ] headers:nil]];
  XCTAssertEqualObjects([parts valueForKey:@"status"], (@[ @200, @204, @200 ]));
  XCTAssertEqual([[self JSONOf:parts[0]][@"value"] count], 4u);
  XCTAssertEqual(handler.deferred, 1);
  XCTAssertEqualObjects([self get:@"Categories(1)/CategoryName"].json[@"value"], @"Drinks");
}

// The client's save of several objects is one change set now: a conflict
// leaves none of them saved. (Inserts join it when the client gives the
// keys; by default it POSTs them first, for the service to assign them.)
- (void)testClientSavesAreAtomic
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  NSDictionary *options = @{ ODataIncrementalStoreTransportOption: _service, ODataIncrementalStorePostOnObtainPermanentIDsOption: @NO };
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:options error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  // Read now, so the client's row (and ETag) is from before the change
  // behind its back; a fault fired later may read the row again.
  XCTAssertEqualObjects([chai valueForKey:@"name"], @"Chai");

  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  [[self productWithID:1 in:backing] setValue:@"Chai tea" forKey:@"name"];
  XCTAssertTrue([backing save:&error], @"%@", error);

  NSManagedObject *coffee = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:context];
  [coffee setValue:@70 forKey:@"id"];
  [coffee setValue:@"Ipoh Coffee" forKey:@"name"];
  [chai setValue:[NSDecimalNumber decimalNumberWithString:@"19"] forKey:@"unitPrice"];
  XCTAssertFalse([context save:&error], @"Chai changed behind the client's back");
  [backing reset];
  XCTAssertNil([self productWithID:70 in:backing], @"and so the new product was not saved either");
  XCTAssertEqualObjects([[self productWithID:1 in:backing] valueForKey:@"unitPrice"], [NSDecimalNumber decimalNumberWithString:@"18"]);
}

// A reference to an entity ($select=ProductID inside another row) carries
// the entity's current ETag. The client keeps the ETag of the row it has,
// so an update from stale values still conflicts, however it learnt that
// the entity exists.
- (void)testReferencesDoNotRefreshTheClientsETag
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: _service } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  XCTAssertEqualObjects([chai valueForKey:@"name"], @"Chai");

  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  [[self productWithID:1 in:backing] setValue:@"Chai tea" forKey:@"name"];
  XCTAssertTrue([backing save:&error], @"%@", error);

  // Chai's stocks come with Chai as a reference, and its new ETag.
  NSSet *stocks = [chai valueForKey:@"stocks"];
  XCTAssertEqual(stocks.count, 1u);
  XCTAssertEqualObjects([stocks.anyObject valueForKeyPath:@"product.objectID"], chai.objectID);

  [chai setValue:[NSDecimalNumber decimalNumberWithString:@"19"] forKey:@"unitPrice"];
  XCTAssertFalse([context save:&error], @"the name the client has is not the service's");
  [backing reset];
  XCTAssertEqualObjects([[self productWithID:1 in:backing] valueForKey:@"name"], @"Chai tea", @"not overwritten");
}

#pragma mark Timeouts, single properties, references

- (void)testAReplyThatNeverComesIsATimeout
{
  [_service setHandler:[[OISSilentProducts alloc] initWithEntity:OISCatalogEntity(@"Product")] forEntitySet:@"Products"];
  _service.replyTimeout = 0.2;
  OISServiceResponse *r = [self get:@"Products"];
  XCTAssertEqual(r.status, 504);
  XCTAssertTrue([r.json[@"error"][@"message"] length] > 0);
}

- (OISServiceResponse *)send:(NSString *)method path:(NSString *)path type:(NSString *)type text:(NSString *)text
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[@"http://example.test/odata/" stringByAppendingString:path]]];
  request.HTTPMethod = method;
  [request setValue:type forHTTPHeaderField:@"Content-Type"];
  request.HTTPBody = [text dataUsingEncoding:NSUTF8StringEncoding];
  return [self exchange:request];
}

- (void)testWritingOneProperty
{
  OISServiceResponse *put = [self send:@"PUT" path:@"Products(1)/ProductName" headers:nil body:@{ @"value": @"Chai tea" }];
  XCTAssertEqual(put.status, 204, @"%@", put.text);
  XCTAssertNotNil([put header:@"ETag"]);
  XCTAssertEqualObjects([self get:@"Products(1)/ProductName"].json[@"value"], @"Chai tea");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)/UnitPrice" headers:nil body:@{ @"value": @"18.5" }].status), 204);
  XCTAssertEqualObjects([self get:@"Products(1)/UnitPrice/$value"].text, @"18.5");
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/UnitPrice/$value" type:@"text/plain" text:@"20"].status), 204);
  XCTAssertEqualObjects([self get:@"Products(1)/UnitPrice/$value"].text, @"20");
  XCTAssertEqual(([self send:@"DELETE" path:@"Products(1)/QuantityPerUnit" headers:nil body:nil].status), 204);
  XCTAssertEqual([self get:@"Products(1)/QuantityPerUnit"].status, 204, @"null now");

  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/ProductID" headers:nil body:@{ @"value": @9 }].status), 400, @"keys do not change");
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/UnitPrice" headers:nil body:@{ @"value": @"cheap" }].status), 400);
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/UnitPrice" headers:nil body:@{ @"price": @1 }].status), 400);
  XCTAssertEqual(([self send:@"DELETE" path:@"Products(1)/ProductName" headers:nil body:nil].status), 400, @"a required property");
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/ProductName" headers:@{ @"If-Match": @"W/\"stale\"" } body:@{ @"value": @"x" }].status), 412);
}

- (void)testReferences
{
  OISServiceResponse *ref = [self get:@"Products(1)/Category/$ref"];
  XCTAssertEqual(ref.status, 200, @"%@", ref.text);
  XCTAssertEqualObjects(ref.json[@"@odata.id"], @"Categories(1)");
  XCTAssertEqualObjects(ref.json[@"@odata.context"], @"http://example.test/odata/$metadata#$ref");

  OISServiceResponse *list = [self get:@"Categories(1)/Products/$ref"];
  NSMutableArray *ids = [NSMutableArray array];
  for (NSDictionary *each in list.json[@"value"]) [ids addObject:each[@"@odata.id"]];
  XCTAssertEqualObjects(ids, (@[ @"Products(1)", @"Products(2)" ]));
  XCTAssertEqualObjects(list.json[@"@odata.context"], @"http://example.test/odata/$metadata#Collection($ref)");

  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/Category/$ref" headers:nil
                        body:@{ @"@odata.id": @"http://example.test/odata/Categories(2)" }].status), 204);
  XCTAssertEqualObjects([self get:@"Products(1)/Category/CategoryName"].json[@"value"], @"Condiments");
  XCTAssertEqual(([self send:@"DELETE" path:@"Products(1)/Category/$ref" headers:nil body:nil].status), 204);
  XCTAssertEqual([self get:@"Products(1)/Category"].status, 204, @"no category now");
  XCTAssertEqual([self get:@"Products(1)/Category/$ref"].status, 204);

  XCTAssertEqual(([self send:@"POST" path:@"Suppliers(2)/Products/$ref" headers:nil body:@{ @"@odata.id": @"Products(1)" }].status), 204);
  XCTAssertEqualObjects([self get:@"Suppliers(2)/Products/$count"].text, @"3");
  XCTAssertEqual(([self send:@"DELETE" path:@"Suppliers(2)/Products/$ref?$id=http://example.test/odata/Products(1)" headers:nil body:nil].status), 204);
  XCTAssertEqual(([self send:@"DELETE" path:@"Suppliers(2)/Products(4)/$ref" headers:nil body:nil].status), 204);
  XCTAssertEqualObjects([self get:@"Suppliers(2)/Products/$count"].text, @"1");
  XCTAssertEqualObjects([self get:@"Products(4)/ProductName"].json[@"value"], @"Chef Anton's Cajun Seasoning", @"the product stays");

  XCTAssertEqual(([self send:@"DELETE" path:@"Suppliers(2)/Products/$ref?$id=Products(1)" headers:nil body:nil].status), 404, @"not a member");
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/Category/$ref" headers:nil body:@{ @"@odata.id": @"Suppliers(1)" }].status), 400);
  XCTAssertEqual(([self send:@"POST" path:@"Products(1)/Category/$ref" headers:nil body:@{ @"@odata.id": @"Categories(1)" }].status), 405);
  XCTAssertEqual(([self send:@"PUT" path:@"Products(1)/$ref" headers:nil body:@{ @"@odata.id": @"Products(2)" }].status), 405);
  XCTAssertEqualObjects([self get:@"Products(3)/$ref"].json[@"@odata.id"], @"Products(3)");
}

// What the client sends for a changed relationship, $ref requests, the
// service now takes.
- (void)testClientChangesRelationships
{
  [ODataIncrementalStore registerStore];
  NSPersistentStoreCoordinator *client = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:OISCatalogModel()];
  NSError *error = nil;
  XCTAssertNotNil([client addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                 URL:[NSURL URLWithString:@"http://example.test/odata/"]
                                             options:@{ ODataIncrementalStoreTransportOption: _service } error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = client;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"name == 'Chai'"];
  NSManagedObject *chai = [[context executeFetchRequest:fetch error:&error] firstObject];
  NSFetchRequest *condiments = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
  condiments.predicate = [NSPredicate predicateWithFormat:@"name == 'Condiments'"];
  [chai setValue:[[context executeFetchRequest:condiments error:&error] firstObject] forKey:@"category"];
  NSFetchRequest *cajun = [NSFetchRequest fetchRequestWithEntityName:@"Supplier"];
  cajun.predicate = [NSPredicate predicateWithFormat:@"city == 'New Orleans'"];
  [[chai mutableSetValueForKey:@"suppliers"] addObject:[[context executeFetchRequest:cajun error:&error] firstObject]];
  XCTAssertTrue([context save:&error], @"%@", error);

  NSManagedObjectContext *backing = [[NSManagedObjectContext alloc] init];
  backing.persistentStoreCoordinator = _coordinator;
  NSManagedObject *saved = [self productWithID:1 in:backing];
  XCTAssertEqualObjects([saved valueForKeyPath:@"category.name"], @"Condiments");
  XCTAssertEqualObjects([[saved valueForKey:@"suppliers"] valueForKey:@"city"], ([NSSet setWithObjects:@"London", @"New Orleans", nil]));
}

- (void)testComposingOnFunctions
{
  [self serveOperations];
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:[self get:@"$metadata"].data error:&error];
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"Default.Product"];
  XCTAssertTrue([schema operationNamed:@"PricierThanPrice" boundToEntityType:product collection:YES parameterNames:nil].isComposable);

  OISServiceResponse *r = [self get:@"Products/Default.PricierThanPrice(Price=10)?$filter=startswith(ProductName,'Ch')&$orderby=UnitPrice desc&$top=2&$count=true"];
  XCTAssertEqual(r.status, 200, @"%@", r.text);
  XCTAssertEqualObjects([self names:r], (@[ @"Chef Anton's Cajun Seasoning", @"Chef Anton's Gumbo Mix" ]));
  XCTAssertEqualObjects(r.json[@"@odata.count"], @4, @"Chai, Chang and both of Chef Anton's");
  XCTAssertEqualObjects([self get:@"Products/Default.PricierThanPrice(Price=20)/$count"].text, @"2");
  XCTAssertEqualObjects([self get:@"Categories(1)/Products/Default.PricierThanPrice(Price=18)/$count"].text, @"1");

  XCTAssertEqualObjects([self get:@"Products(4)/Default.CheapestInCategory()/ProductName"].json[@"value"], @"Aniseed Syrup");
  XCTAssertEqualObjects([self get:@"Products(4)/Default.CheapestInCategory()/Category/CategoryName"].json[@"value"], @"Condiments");
  OISServiceResponse *selected = [self get:@"Products(4)/Default.CheapestInCategory()?$select=UnitPrice&$expand=Category($select=CategoryName)"];
  XCTAssertEqualObjects(selected.json[@"Category"][@"CategoryName"], @"Condiments");
  XCTAssertNil(selected.json[@"ProductName"]);

  XCTAssertEqual([self get:@"CountProductsCheaperThanPrice(Price=19)/Foo"].status, 400, @"a value cannot be read on from");
  XCTAssertEqual(([self send:@"POST" path:@"Products(1)/Default.RaisePriceByPercent/Category" headers:nil body:@{ @"Percent": @1 }].status), 400);
}

#pragma mark Derived types and $levels

// A model of its own, made here since the Catalog has neither inheritance
// nor a relationship to its own entity: employees, managers among them
// (and executives among those, though there are none yet), each with a
// manager and reports.
- (void)serveStaff
{
  [self serveStaffInStoreOfType:NSInMemoryStoreType];
}

- (void)serveStaffInStoreOfType:(NSString *)storeType
{
  NSEntityDescription *employee = [[NSEntityDescription alloc] init];
  employee.name = @"Employee";
  employee.managedObjectClassName = @"NSManagedObject";
  NSEntityDescription *manager = [[NSEntityDescription alloc] init];
  manager.name = @"Manager";
  manager.managedObjectClassName = @"NSManagedObject";
  NSEntityDescription *executive = [[NSEntityDescription alloc] init];
  executive.name = @"Executive";
  executive.managedObjectClassName = @"NSManagedObject";

  NSAttributeDescription *identifier = [[NSAttributeDescription alloc] init];
  identifier.name = @"id";
  identifier.attributeType = NSInteger32AttributeType;
  identifier.optional = NO;
  NSAttributeDescription *name = [[NSAttributeDescription alloc] init];
  name.name = @"name";
  name.attributeType = NSStringAttributeType;
  name.optional = YES;
  NSAttributeDescription *budget = [[NSAttributeDescription alloc] init];
  budget.name = @"budget";
  budget.attributeType = NSDecimalAttributeType;
  budget.optional = YES;
  NSRelationshipDescription *boss = [[NSRelationshipDescription alloc] init];
  boss.name = @"manager";
  boss.destinationEntity = employee;
  boss.maxCount = 1;
  boss.optional = YES;
  NSRelationshipDescription *reports = [[NSRelationshipDescription alloc] init];
  reports.name = @"reports";
  reports.destinationEntity = employee;
  reports.maxCount = 0;
  reports.optional = YES;
  boss.inverseRelationship = reports;
  reports.inverseRelationship = boss;
  employee.properties = @[ identifier, name, boss, reports ];
  manager.properties = @[ budget ];
  manager.subentities = @[ executive ];
  employee.subentities = @[ manager ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ employee, manager, executive ];

  _coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  NSURL *url = nil;
  if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_storeFiles addObject:url];
  }
  XCTAssertNotNil([_coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:nil error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = _coordinator;
  // Ann manages Bob, who manages Cy and Di.
  NSManagedObject *ann = [self insert:@"Manager" into:context values:@{ @"id": @1, @"name": @"Ann", @"budget": [NSDecimalNumber decimalNumberWithString:@"5000"] }];
  NSManagedObject *bob = [self insert:@"Manager" into:context values:@{ @"id": @2, @"name": @"Bob", @"budget": [NSDecimalNumber decimalNumberWithString:@"800"], @"manager": ann }];
  [self insert:@"Employee" into:context values:@{ @"id": @3, @"name": @"Cy", @"manager": bob }];
  [self insert:@"Employee" into:context values:@{ @"id": @4, @"name": @"Di", @"manager": bob }];
  XCTAssertTrue([context save:&error], @"%@", error);
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_coordinator serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
}

- (NSArray *)employeeNames:(OISServiceResponse *)response
{
  return [response.json[@"value"] valueForKey:@"Name"];
}

- (void)testTypeCasts
{
  [self serveStaff];
  OISServiceResponse *managers = [self get:@"Employees/Default.Manager"];
  XCTAssertEqual(managers.status, 200, @"%@", managers.text);
  XCTAssertEqualObjects([self employeeNames:managers], (@[ @"Ann", @"Bob" ]));
  XCTAssertEqualObjects(managers.json[@"@odata.context"], @"http://example.test/odata/$metadata#Employees/Default.Manager");
  XCTAssertEqualObjects([self get:@"Employees/Default.Manager/$count"].text, @"2");
  XCTAssertEqualObjects([self employeeNames:[self get:@"Employees/Default.Manager?$filter=Budget gt 1000"]], @[ @"Ann" ]);
  XCTAssertEqualObjects([self get:@"Employees(2)/Default.Manager/Budget"].json[@"value"], @800);
  XCTAssertEqual([self get:@"Employees(3)/Default.Manager"].status, 404, @"Cy manages no one");
  XCTAssertEqual([self get:@"Employees/Default.Nobody"].status, 404);

  OISServiceResponse *all = [self get:@"Employees?$select=Name,Default.Manager/Budget"];
  NSArray *rows = all.json[@"value"];
  XCTAssertEqualObjects(rows[0][@"Budget"], @5000);
  XCTAssertNil(rows[2][@"Budget"], @"an employee who is not a manager has none");
  XCTAssertEqualObjects(rows[2][@"@odata.type"], nil, @"the set's own type needs no @odata.type");
  XCTAssertEqualObjects(rows[0][@"@odata.type"], @"#Default.Manager");

  OISServiceResponse *created = [self send:@"POST" path:@"Employees/Default.Manager" headers:nil body:@{ @"Name": @"Eve", @"Budget": @100 }];
  XCTAssertEqual(created.status, 201, @"%@", created.text);
  XCTAssertEqualObjects(created.json[@"@odata.context"], @"http://example.test/odata/$metadata#Employees/Default.Manager/$entity",
                        @"the context names the type, so minimal metadata needs no @odata.type");
  XCTAssertEqualObjects(created.json[@"Budget"], @100);
  XCTAssertEqualObjects([self get:@"Employees/Default.Manager/$count"].text, @"3", @"created as the cast's type");
}

- (NSArray *)sortedEmployeeNames:(NSString *)path
{
  OISServiceResponse *response = [self get:path];
  XCTAssertEqual(response.status, 200, @"%@: %@", path, response.text);
  return [[self employeeNames:response] sortedArrayUsingSelector:@selector(compare:)];
}

- (void)testTypeCastsAndIsOfInFilters
{
  // Each store asks an object's type its own way: SQL, or the predicate
  // evaluated on its nodes, or on objects.
  for (NSString *storeType in @[ NSInMemoryStoreType, NSSQLiteStoreType, NSXMLStoreType ]) {
    [self serveStaffInStoreOfType:storeType];
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
    context.persistentStoreCoordinator = _coordinator;
    NSFetchRequest *annRequest = [NSFetchRequest fetchRequestWithEntityName:@"Employee"];
    annRequest.predicate = [NSPredicate predicateWithFormat:@"id == 1"];
    NSManagedObject *ann = [[context executeFetchRequest:annRequest error:NULL] firstObject];
    [self insert:@"Executive" into:context values:@{ @"id": @5, @"name": @"Zed", @"budget": [NSDecimalNumber decimalNumberWithString:@"100"], @"manager": ann }];
    NSError *error = nil;
    XCTAssertTrue([context save:&error], @"%@", error);

    NSDictionary *expected = @{
      @"isof(Default.Manager)": @[ @"Ann", @"Bob", @"Zed" ],
      @"isof(Default.Executive)": @[ @"Zed" ],
      @"isof(Default.Employee)": @[ @"Ann", @"Bob", @"Cy", @"Di", @"Zed" ],
      @"isof('Default.Executive')": @[ @"Zed" ],
      @"not isof(Default.Manager)": @[ @"Cy", @"Di" ],
      @"isof(Manager,Default.Manager)": @[ @"Bob", @"Cy", @"Di", @"Zed" ],
      @"Default.Manager/Budget gt 500": @[ @"Ann", @"Bob" ],
      @"Default.Manager/Budget eq null": @[ @"Cy", @"Di" ],
      @"Default.Manager/Budget ne 800": @[ @"Ann", @"Cy", @"Di", @"Zed" ],
      @"Default.Manager/Budget in (800,100)": @[ @"Bob", @"Zed" ],
      @"Default.Employee/Name eq 'Ann'": @[ @"Ann" ],
      @"Manager/Default.Manager/Budget lt 1000": @[ @"Cy", @"Di" ],
      @"Name eq 'Cy' or Default.Manager/Budget ge 5000": @[ @"Ann", @"Cy" ],
      @"Reports/Default.Manager/any(m:m/Budget lt 1000)": @[ @"Ann" ],
      @"Reports/Default.Executive/any()": @[ @"Ann" ],
      @"Reports/Default.Manager/$count eq 2": @[ @"Ann" ],
      @"Reports/any(r:isof(r,Default.Manager))": @[ @"Ann" ],
      @"Reports/all(r:isof(r,Default.Manager))": @[ @"Ann", @"Cy", @"Di", @"Zed" ],
      @"cast(Manager,Default.Manager)/Budget gt 1000": @[ @"Bob", @"Zed" ],
      @"cast(Manager,Default.Manager) eq null": @[ @"Ann" ],
      @"cast(Default.Manager)/Budget lt 1000": @[ @"Bob", @"Zed" ],
    };
    for (NSString *filter in expected) {
      NSString *path = [@"Employees?$filter=" stringByAppendingString:filter];
      XCTAssertEqualObjects([self sortedEmployeeNames:path], expected[filter], @"%@: %@", storeType, filter);
    }
    XCTAssertEqualObjects([self get:@"Employees/$count?$filter=isof(Default.Manager)"].text, @"3", @"%@", storeType);
    OISServiceResponse *expanded = [self get:@"Employees(1)?$expand=Reports($filter=isof(Default.Executive))"];
    XCTAssertEqualObjects([expanded.json[@"Reports"] valueForKey:@"Name"], @[ @"Zed" ], @"%@: %@", storeType, expanded.text);

    XCTAssertEqual([self get:@"Employees?$orderby=Default.Manager/Budget"].status, 501, @"a store that sorts objects cannot ask an Employee for its budget");
    XCTAssertEqual([self get:@"Employees?$filter=isof(Name,Edm.String)"].status, 501);
    XCTAssertEqual([self get:@"Employees?$filter=isof(Default.Nobody)"].status, 400);
    XCTAssertEqual([self get:@"Employees?$filter=Default.Manager/Nothing eq 1"].status, 400);
    XCTAssertEqual([self get:@"Employees?$filter=isof(Reports,Default.Manager)"].status, 400, @"a collection");
  }
}

- (void)testLevels
{
  [self serveStaff];
  OISServiceResponse *two = [self get:@"Employees(1)?$select=Name&$expand=Reports($select=Name;$levels=2)"];
  XCTAssertEqual(two.status, 200, @"%@", two.text);
  NSDictionary *bob = [two.json[@"Reports"] firstObject];
  XCTAssertEqualObjects(bob[@"Name"], @"Bob");
  XCTAssertEqualObjects([[bob[@"Reports"] valueForKey:@"Name"] sortedArrayUsingSelector:@selector(compare:)], (@[ @"Cy", @"Di" ]));
  XCTAssertNil([bob[@"Reports"] firstObject][@"Reports"], @"two levels, no more");

  OISServiceResponse *max = [self get:@"Employees(4)?$expand=Manager($levels=max)"];
  XCTAssertEqualObjects(max.json[@"Manager"][@"Name"], @"Bob");
  XCTAssertEqualObjects(max.json[@"Manager"][@"Manager"][@"Name"], @"Ann", @"to the top");
  XCTAssertEqualObjects(max.json[@"Manager"][@"Manager"][@"Manager"], [NSNull null]);

  OISServiceResponse *one = [self get:@"Employees(1)?$expand=Reports($levels=1)"];
  XCTAssertNil([one.json[@"Reports"] firstObject][@"Reports"]);
}

#pragma mark Deep inserts

- (void)testDeepInsert
{
  OISServiceResponse *category = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Seafood",
    @"Products": @[ @{ @"ProductName": @"Ikura", @"UnitPrice": @31 }, @{ @"ProductName": @"Konbu", @"UnitPrice": @6 } ] }];
  XCTAssertEqual(category.status, 201, @"%@", category.text);
  XCTAssertEqualObjects(category.json[@"CategoryID"], @3);
  NSArray *products = category.json[@"Products"];
  XCTAssertEqualObjects([[products valueForKey:@"ProductName"] sortedArrayUsingSelector:@selector(compare:)], (@[ @"Ikura", @"Konbu" ]),
                        @"what was created comes back expanded");
  XCTAssertEqualObjects([[products valueForKey:@"ProductID"] sortedArrayUsingSelector:@selector(compare:)], (@[ @6, @7 ]));
  XCTAssertEqualObjects([self get:@"Categories(3)/Products/$count"].text, @"2");

  OISServiceResponse *product = [self send:@"POST" path:@"Products" headers:nil body:@{
    @"ProductName": @"Tofu", @"Category": @{ @"CategoryName": @"Produce" }, @"Suppliers@odata.bind": @[ @"Suppliers(1)" ] }];
  XCTAssertEqual(product.status, 201, @"%@", product.text);
  XCTAssertEqualObjects(product.json[@"Category"][@"CategoryName"], @"Produce");
  XCTAssertEqualObjects([self get:@"Products(8)/Category/CategoryID"].json[@"value"], @4);
  XCTAssertEqualObjects([self get:@"Products(8)/Suppliers/$count"].text, @"1");

  OISServiceResponse *deep = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Confections",
    @"Products": @[ @{ @"ProductName": @"Teatime Biscuits",
                       @"Stocks": @[ @{ @"StockID": @9, @"Quantity": @5, @"Location@odata.bind": @"Locations(1)" } ] } ] }];
  XCTAssertEqual(deep.status, 201, @"%@", deep.text);
  XCTAssertEqualObjects([deep.json[@"Products"] firstObject][@"Stocks"][0][@"Quantity"], @5, @"three levels down");
  XCTAssertEqualObjects([self get:@"Stocks(9)/Location/LocationName"].json[@"value"], @"Warehouse");

  OISServiceResponse *bad = [self send:@"POST" path:@"Categories" headers:nil body:@{
    @"CategoryName": @"Grains", @"Products": @[ @{ @"ProductName": @"Rice", @"UnitPrice": @"cheap" } ] }];
  XCTAssertEqual(bad.status, 400);
  XCTAssertEqualObjects([self get:@"Categories/$count"].text, @"5", @"nothing of it was saved");
  XCTAssertEqual(([self send:@"POST" path:@"Categories" headers:nil body:@{ @"CategoryName": @"G", @"Products": @{ @"ProductName": @"R" } }].status), 400,
                 @"a to-many takes an array");
}

#pragma mark Deep updates

- (NSArray *)productIDsOf:(NSString *)path
{
  OISServiceResponse *response = [self get:[path stringByAppendingString:@"?$select=ProductID&$orderby=ProductID"]];
  XCTAssertEqual(response.status, 200, @"%@: %@", path, response.text);
  return [response.json[@"value"] valueForKey:@"ProductID"];
}

- (void)testDeepUpdate
{
  // A to-many's full set: one updated, one bound by @id, one created; the
  // one left out (Chang) unlinked, not deleted.
  OISServiceResponse *full = [self send:@"PATCH" path:@"Categories(1)" headers:@{ @"Prefer": @"return=representation" } body:@{
    @"CategoryName": @"Drinks",
    @"Products": @[ @{ @"ProductID": @1, @"ProductName": @"Chai Tea" }, @{ @"@id": @"Products(3)" }, @{ @"ProductName": @"Mate", @"UnitPrice": @12 } ] }];
  XCTAssertEqual(full.status, 200, @"%@", full.text);
  XCTAssertEqualObjects(full.json[@"CategoryName"], @"Drinks");
  XCTAssertEqualObjects([[full.json[@"Products"] valueForKey:@"ProductID"] sortedArrayUsingSelector:@selector(compare:)], (@[ @1, @3, @6 ]),
                        @"what it relates comes back expanded");
  XCTAssertEqualObjects([self productIDsOf:@"Categories(1)/Products"], (@[ @1, @3, @6 ]));
  XCTAssertEqualObjects([self get:@"Products(1)/ProductName"].json[@"value"], @"Chai Tea");
  XCTAssertEqualObjects([self get:@"Products(6)/UnitPrice"].json[@"value"], @12);
  XCTAssertEqual([self get:@"Products(2)/Category"].status, 204, @"Chang is unlinked");
  XCTAssertEqual([self get:@"Products(2)"].status, 200, @"and still there");

  // A to-one: the entity it names, updated; null; a new one.
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(2)" headers:nil body:@{ @"Category": @{ @"CategoryID": @2, @"CategoryName": @"Sauces" } }].status), 204);
  XCTAssertEqualObjects([self get:@"Products(2)/Category/CategoryName"].json[@"value"], @"Sauces");
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(2)" headers:nil body:@{ @"Category": [NSNull null] }].status), 204);
  XCTAssertEqual([self get:@"Products(2)/Category"].status, 204);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(2)" headers:nil body:@{ @"Category": @{ @"CategoryName": @"Snacks" } }].status), 204);
  XCTAssertEqualObjects([self get:@"Products(2)/Category/CategoryID"].json[@"value"], @3);

  // A delta: Chang added, Cajun Seasoning unlinked, Gumbo Mix deleted.
  OISServiceResponse *delta = [self send:@"PATCH" path:@"Categories(2)" headers:nil body:@{
    @"Products@delta": @[ @{ @"@id": @"Products(2)" },
                          @{ @"@removed": @{ @"reason": @"changed" }, @"@id": @"Products(4)" },
                          @{ @"@removed": @{ @"reason": @"deleted" }, @"ProductID": @5 } ] }];
  XCTAssertEqual(delta.status, 204, @"%@", delta.text);
  NSArray *sauces = [self productIDsOf:@"Categories(2)/Products"];
  XCTAssertEqualObjects(sauces, (@[ @2 ]), @"%@", sauces);
  XCTAssertEqual([self get:@"Products(4)/Category"].status, 204);
  XCTAssertEqual([self get:@"Products(5)"].status, 404);

  // Failures change nothing.
  OISServiceResponse *bad = [self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{
    @"CategoryName": @"Nothing", @"Products": @[ @{ @"ProductID": @1, @"UnitPrice": @"cheap" } ] }];
  XCTAssertEqual(bad.status, 400);
  XCTAssertEqualObjects([self get:@"Categories(1)/CategoryName"].json[@"value"], @"Drinks");
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"Products": @[ @{ @"@id": @"Products(99)" } ] }].status), 400);
  XCTAssertEqual(([self send:@"PATCH" path:@"Products(1)" headers:nil body:@{ @"Category@delta": @[] }].status), 400, @"a delta is of a collection");
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"Products": @{ @"ProductID": @1 } }].status), 400, @"a to-many takes an array");
  OISServiceResponse *stale = [self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{
    @"Products": @[ @{ @"ProductID": @1, @"@odata.etag": @"W/\"999\"", @"ProductName": @"Old" } ] }];
  XCTAssertEqual(stale.status, 412, @"%@", stale.text);
  XCTAssertEqualObjects([self productIDsOf:@"Categories(1)/Products"], (@[ @1, @3, @6 ]));

  // Each nested entity as its set allows.
  ODataEntitySetHandler *products = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Product")];
  products.allowsUpdate = NO;
  products.allowsDelete = NO;
  [_service setHandler:products forEntitySet:@"Products"];
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"Products": @[ @{ @"ProductID": @1, @"ProductName": @"Chai" } ] }].status), 405);
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{
    @"Products@delta": @[ @{ @"@removed": @{ @"reason": @"deleted" }, @"@id": @"Products(6)" } ] }].status), 405);
  XCTAssertEqual(([self send:@"PATCH" path:@"Categories(1)" headers:nil body:@{ @"Products": @[ @{ @"ProductID": @1 }, @{ @"@id": @"Products(3)" } ] }].status), 204,
                 @"naming entities, without changing them, only links them");
  XCTAssertEqualObjects([self productIDsOf:@"Categories(1)/Products"], (@[ @1, @3 ]));
}

- (void)testRestrictionsInMetadata
{
  XCTAssertTrue([[self get:@"$metadata"].text rangeOfString:@"Restrictions"].location == NSNotFound, @"everything allowed");
  ODataEntitySetHandler *locations = [[ODataEntitySetHandler alloc] initWithEntity:OISCatalogEntity(@"Location")];
  [_service setHandler:locations forEntitySet:@"Locations"];
  locations.allowsInsert = NO;
  locations.allowsDelete = NO;
  NSString *xml = [self get:@"$metadata"].text;
  XCTAssertTrue([xml rangeOfString:@"<EntitySet Name=\"Locations\" EntityType=\"Default.Location\">"].location != NSNotFound);
  XCTAssertTrue([xml rangeOfString:@"Org.OData.Capabilities.V1.InsertRestrictions\"><Record><PropertyValue Property=\"Insertable\" Bool=\"false\"/>"].location != NSNotFound, @"%@", xml);
  XCTAssertTrue([xml rangeOfString:@"Org.OData.Capabilities.V1.DeleteRestrictions"].location != NSNotFound);
  XCTAssertTrue([xml rangeOfString:@"UpdateRestrictions"].location == NSNotFound);
  XCTAssertNotNil([ODataSchema schemaWithData:[xml dataUsingEncoding:NSUTF8StringEncoding] error:NULL], @"still reads");
  XCTAssertEqual(([self send:@"POST" path:@"Locations" headers:nil body:@{ @"LocationName": @"Shed" }].status), 405);
}

@end
