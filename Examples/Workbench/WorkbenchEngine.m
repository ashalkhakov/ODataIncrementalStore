// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WorkbenchEngine.h"

@implementation WorkbenchLogEntry
@end

#pragma mark - The built-in service's operations

// What a product can be asked, and told: declared here, served by
// ODataService (see ODataService.h), and offered by the Workbench's
// Operations menu like any service's.
@protocol WorkbenchProductFunctions <ODataFunctions>
- (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply;
+ (NSArray *)cheaperThanPrice:(double)price reply:(ODataReply *)reply;
@end

@protocol WorkbenchProductActions <ODataActions>
- (NSDecimalNumber *)raisePriceByPercent:(double)percent reply:(ODataReply *)reply;
@end

@interface WorkbenchProduct : NSManagedObject <WorkbenchProductFunctions, WorkbenchProductActions>
@end

@implementation WorkbenchProduct

+ (NSDictionary *)ODataOperationTypes
{
  return @{ @"cheaperThanPrice:reply:": @"Collection(Catalog.Product)" };
}

- (NSDecimalNumber *)price:(double)percent
{
  NSDecimalNumber *factor = [NSDecimalNumber decimalNumberWithMantissa:(unsigned long long)llround(fabs(percent) * 100) exponent:-4 isNegative:percent < 0];
  NSDecimalNumber *price = [self valueForKey:@"unitPrice"] ?: [NSDecimalNumber zero];
  NSDecimalNumberHandler *cents = [NSDecimalNumberHandler decimalNumberHandlerWithRoundingMode:NSRoundPlain scale:2
                                                                             raiseOnExactness:NO raiseOnOverflow:NO
                                                                             raiseOnUnderflow:NO raiseOnDivideByZero:NO];
  return [price decimalNumberByAdding:[price decimalNumberByMultiplyingBy:factor] withBehavior:cents];
}

- (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply
{
  return [self price:-percent];
}

- (NSDecimalNumber *)raisePriceByPercent:(double)percent reply:(ODataReply *)reply
{
  if (percent <= -100) {
    [reply failWithError:ODataServiceError(400, @"A price cannot fall by 100% or more")];
    return nil;
  }
  NSDecimalNumber *price = [self price:percent];
  [self setValue:price forKey:@"unitPrice"];
  return price;
}

// Bound to the collection it is called on: all the products, or one
// category's (Categories(1)/Products/Catalog.CheaperThanPrice(Price=20)).
+ (NSArray *)cheaperThanPrice:(double)price reply:(ODataReply *)reply
{
  NSFetchRequest *fetch = [reply.request.collectionFetchRequest copy];
  NSPredicate *cheaper = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"unitPrice"]
                                                            rightExpression:[NSExpression expressionForConstantValue:@(price)]
                                                                   modifier:NSDirectPredicateModifier
                                                                       type:NSLessThanPredicateOperatorType
                                                                    options:0];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[ fetch.predicate, cheaper ]];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"unitPrice" ascending:YES] ];
  NSError *error = nil;
  NSArray *rows = [reply.request.context executeFetchRequest:fetch error:&error];
  if (!rows) [reply failWithError:error];
  return rows;
}

@end

@protocol WorkbenchCatalogFunctions <ODataFunctions>
- (int32_t)countProductsInCategoryWithName:(NSString *)name reply:(ODataReply *)reply;
@end

@interface WorkbenchCatalogOperations : NSObject <WorkbenchCatalogFunctions>
@end

@implementation WorkbenchCatalogOperations

+ (NSDictionary *)ODataOperationNames
{
  return @{ @"countProductsInCategoryWithName:reply:": @"CountProductsInCategoryNamed" };
}

- (int32_t)countProductsInCategoryWithName:(NSString *)name reply:(ODataReply *)reply
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:@"category.name"]
                                                       rightExpression:[NSExpression expressionForConstantValue:name ?: @""]
                                                              modifier:NSDirectPredicateModifier
                                                                  type:NSEqualToPredicateOperatorType
                                                               options:0];
  NSUInteger count = [reply.request.context countForFetchRequest:fetch error:NULL];
  return count == NSNotFound ? 0 : (int32_t)count;
}

@end

#pragma mark - The engine

@implementation WorkbenchEngine {
  NSURL *_modelURL;
  NSMutableArray *_log;
}

- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot modelURL:(NSURL *)modelURL
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [serviceRoot copy];
  _modelURL = [modelURL copy];
  _log = [NSMutableArray array];
  if (![self startService]) return nil;
  return self;
}

- (NSArray *)log
{
  return [_log copy];
}

- (void)reset
{
  [_log removeAllObjects];
  [self startService];
}

// A model of the service's own, whose products are WorkbenchProducts: the
// client's model is the same file, with plain managed objects. A copy,
// since a model loaded again may be the one the client already uses, which
// can no longer change.
- (BOOL)startService
{
  NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] initWithContentsOfURL:_modelURL] copy];
  if (!model.entities.count) return NO;
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  product.managedObjectClassName = NSStringFromClass([WorkbenchProduct class]);
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  if (![coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error]) {
    NSLog(@"Workbench: the built-in service's store does not open: %@", error);
    return NO;
  }
  [self seedCoordinator:coordinator];
  ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator serviceRoot:_serviceRoot];
  service.namespaceName = @"Catalog";
  service.serviceOperations = [[WorkbenchCatalogOperations alloc] init];
  for (NSString *problem in service.operationProblems) NSLog(@"Workbench: %@", problem);
  _service = service;
  return YES;
}

static NSManagedObject *WBInsert(NSManagedObjectContext *context, NSString *entity, NSDictionary *values)
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];
  for (NSString *key in values) [object setValue:values[key] forKey:key];
  return object;
}

// A few of Northwind's rows.
- (void)seedCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  [context performBlockAndWait:^{
    NSMutableDictionary *categories = [NSMutableDictionary dictionary];
    NSArray *categoryNames = @[ @"Beverages", @"Condiments", @"Confections", @"Dairy Products", @"Produce", @"Seafood" ];
    for (NSUInteger i = 0; i < categoryNames.count; i++) {
      categories[@(i + 1)] = WBInsert(context, @"Category", @{ @"id": @(i + 1), @"name": categoryNames[i] });
    }
    NSMutableDictionary *suppliers = [NSMutableDictionary dictionary];
    NSArray *supplierRows = @[ @[ @"Exotic Liquids", @"London", @"UK" ], @[ @"New Orleans Cajun Delights", @"New Orleans", @"USA" ],
                               @[ @"Grandma Kelly's Homestead", @"Ann Arbor", @"USA" ], @[ @"Tokyo Traders", @"Tokyo", @"Japan" ],
                               @[ @"Cooperativa de Quesos", @"Oviedo", @"Spain" ] ];
    for (NSUInteger i = 0; i < supplierRows.count; i++) {
      NSArray *row = supplierRows[i];
      suppliers[@(i + 1)] = WBInsert(context, @"Supplier", @{ @"id": @(i + 1), @"companyName": row[0], @"city": row[1], @"country": row[2] });
    }
    NSMutableDictionary *locations = [NSMutableDictionary dictionary];
    NSArray *locationRows = @[ @[ @"Warehouse North", @"Seattle", @"USA" ], @[ @"Dock 4", @"London", @"UK" ], @[ @"Cold Store", @"Tokyo", @"Japan" ] ];
    for (NSUInteger i = 0; i < locationRows.count; i++) {
      NSArray *row = locationRows[i];
      locations[@(i + 1)] = WBInsert(context, @"Location", @{ @"id": @(i + 1), @"name": row[0], @"city": row[1], @"country": row[2] });
    }
    // id, name, quantity per unit, price, discontinued, category, suppliers
    NSArray *productRows = @[
      @[ @1, @"Chai", @"10 boxes x 20 bags", @"18", @NO, @1, @[ @1, @4 ] ],
      @[ @2, @"Chang", @"24 - 12 oz bottles", @"19", @NO, @1, @[ @1 ] ],
      @[ @3, @"Aniseed Syrup", @"12 - 550 ml bottles", @"10", @NO, @2, @[ @1 ] ],
      @[ @4, @"Chef Anton's Cajun Seasoning", @"48 - 6 oz jars", @"22", @NO, @2, @[ @2 ] ],
      @[ @5, @"Grandma's Boysenberry Spread", @"12 - 8 oz jars", @"25", @NO, @2, @[ @3 ] ],
      @[ @6, @"Uncle Bob's Organic Dried Pears", @"12 - 1 lb pkgs.", @"30", @NO, @5, @[ @3 ] ],
      @[ @7, @"Ikura", @"12 - 200 ml jars", @"31", @NO, @6, @[ @4 ] ],
      @[ @8, @"Queso Cabrales", @"1 kg pkg.", @"21", @NO, @4, @[ @5 ] ],
      @[ @9, @"Konbu", @"2 kg box", @"6", @NO, @6, @[ @4 ] ],
      @[ @10, @"Tofu", @"40 - 100 g pkgs.", @"23.25", @NO, @5, @[ @4 ] ],
      @[ @11, @"Sir Rodney's Marmalade", @"30 gift boxes", @"81", @NO, @3, @[ @3 ] ],
      @[ @12, @"Côte de Blaye", @"12 - 75 cl bottles", @"263.5", @NO, @1, @[ @1 ] ],
      @[ @13, @"Guaraná Fantástica", @"12 - 355 ml cans", @"4.5", @YES, @1, @[ @2 ] ],
      @[ @14, @"NuNuCa Nuß-Nougat-Creme", @"20 - 450 g glasses", @"14", @NO, @3, @[ @3 ] ],
    ];
    NSMutableDictionary *products = [NSMutableDictionary dictionary];
    for (NSArray *row in productRows) {
      NSManagedObject *product = WBInsert(context, @"Product", @{
        @"id": row[0], @"name": row[1], @"quantityPerUnit": row[2],
        @"unitPrice": [NSDecimalNumber decimalNumberWithString:row[3]], @"discontinued": row[4],
        @"category": categories[row[5]] });
      NSMutableSet *supplied = [product mutableSetValueForKey:@"suppliers"];
      for (NSNumber *supplier in row[6]) [supplied addObject:suppliers[supplier]];
      products[row[0]] = product;
    }
    // id, product, location, quantity
    NSArray *stockRows = @[ @[ @1, @1, @1, @39 ], @[ @2, @1, @2, @12 ], @[ @3, @2, @1, @17 ], @[ @4, @4, @1, @53 ],
                            @[ @5, @7, @3, @31 ], @[ @6, @11, @2, @40 ], @[ @7, @12, @2, @8 ], @[ @8, @13, @1, @20 ] ];
    for (NSArray *row in stockRows) {
      WBInsert(context, @"Stock", @{ @"id": row[0], @"product": products[row[1]], @"location": locations[row[2]], @"quantity": row[3] });
    }
    NSError *error = nil;
    if (![context save:&error]) NSLog(@"Workbench: seeding the built-in service failed: %@", error);
  }];
}

#pragma mark Transport

// The service answers, and the exchange is logged as it went: a handler
// that answers later is logged when it does.
- (void)startExchange:(ODataExchange *)exchange
{
  ODataExchange *inner = [[ODataExchange alloc] initWithRequest:exchange.request target:self action:@selector(innerDidFinish:)];
  inner.context = @[ exchange, [NSDate date] ];
  @synchronized (self) {
    _started++;
  }
  [self.service startExchange:inner];
}

- (void)innerDidFinish:(ODataExchange *)inner
{
  ODataExchange *outer = inner.context[0];
  NSDate *started = inner.context[1];
  outer.URLResponse = inner.URLResponse;
  outer.data = inner.data;
  outer.error = inner.error;

  NSURLRequest *request = inner.request;
  NSHTTPURLResponse *http = [inner.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)inner.URLResponse : nil;
  WorkbenchLogEntry *entry = [[WorkbenchLogEntry alloc] init];
  entry.method = request.HTTPMethod.uppercaseString ?: @"GET";
  entry.URL = request.URL.absoluteString ?: @"";
  entry.status = http.statusCode;
  entry.requestHeaders = request.allHTTPHeaderFields;
  entry.requestData = request.HTTPBody;
  entry.responseHeaders = http.allHeaderFields;
  entry.responseData = inner.data ?: [NSData data];
  entry.failure = inner.error.localizedDescription;
  entry.date = started;
  entry.duration = -[started timeIntervalSinceNow];
  entry.storeHint = [self hintForURL:request.URL method:entry.method];
  @synchronized (_log) {
    [_log insertObject:entry atIndex:0];
    if (_log.count > 48) [_log removeLastObject];
  }
  if (self.didHandle) self.didHandle(entry);
  [outer finish];
}

- (NSString *)hintForURL:(NSURL *)url method:(NSString *)method
{
  NSString *path = [self relativePath:url];
  if ([path isEqualToString:@"$batch"]) return @"executeRequest:withContext:error:  (NSSaveChangesRequest, one change set)";
  if ([method isEqualToString:@"PATCH"] || [method isEqualToString:@"POST"] || [method isEqualToString:@"DELETE"]) {
    return @"executeRequest:withContext:error:  (NSSaveChangesRequest)";
  }
  if ([path rangeOfString:@"/$count"].location != NSNotFound) {
    return @"executeRequest:withContext:error:  (NSCountResultType)";
  }
  if ([path rangeOfString:@")/"].location != NSNotFound) {
    return @"newValueForRelationship:forObjectWithID:withContext:error:";
  }
  if ([path rangeOfString:@"("].location != NSNotFound) {
    return @"newValuesForObjectWithID:withContext:error:";
  }
  return @"executeRequest:withContext:error:  (NSFetchRequest)";
}

- (NSString *)relativePath:(NSURL *)url
{
  NSString *path = url.path ?: @"";
  NSString *root = self.serviceRoot.path ?: @"";
  if (root.length && [path hasPrefix:root]) path = [path substringFromIndex:root.length];
  while ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
  return path;
}

@end

#pragma mark - The network

@implementation WorkbenchNetworkTransport

- (void)startExchange:(ODataExchange *)exchange
{
  ODataExchange *inner = [[ODataExchange alloc] initWithRequest:exchange.request target:self action:@selector(innerDidFinish:)];
  inner.context = @[ exchange, [NSDate date] ];
  @synchronized (self) {
    _started++;
  }
  [ODataDefaultTransport() startExchange:inner];
}

- (void)innerDidFinish:(ODataExchange *)inner
{
  ODataExchange *outer = inner.context[0];
  NSDate *started = inner.context[1];
  outer.URLResponse = inner.URLResponse;
  outer.data = inner.data;
  outer.error = inner.error;

  WorkbenchLogEntry *entry = [[WorkbenchLogEntry alloc] init];
  NSURLRequest *request = inner.request;
  entry.method = request.HTTPMethod.uppercaseString ?: @"GET";
  entry.URL = request.URL.absoluteString ?: @"";
  NSHTTPURLResponse *http = [inner.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)inner.URLResponse : nil;
  entry.status = http.statusCode;
  entry.requestHeaders = request.allHTTPHeaderFields;
  entry.requestData = request.HTTPBody;
  entry.responseHeaders = http.allHeaderFields;
  entry.responseData = inner.data;
  entry.failure = inner.error.localizedDescription;
  entry.date = started;
  entry.duration = -[started timeIntervalSinceNow];
  entry.storeHint = @"";
  void (^report)(WorkbenchLogEntry *) = self.didHandle;
  // The main thread may be waiting for this very exchange: report later,
  // never wait for it.
  if (report) [self performSelectorOnMainThread:@selector(report:) withObject:@[ [report copy], entry ] waitUntilDone:NO];
  [outer finish];
}

- (void)report:(NSArray *)blockAndEntry
{
  void (^report)(WorkbenchLogEntry *) = blockAndEntry[0];
  report(blockAndEntry[1]);
}

@end
