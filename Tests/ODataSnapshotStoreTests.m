// Store + client against recorded OData v4 pairs. No live endpoint.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"
#import "ODataSnapshotTransport.h"

@interface ODataSnapshotStoreTests : XCTestCase
@end

@implementation ODataSnapshotStoreTests {
  ODataSnapshotTransport *_transport;
  ODataIncrementalStore *_store;
  NSManagedObjectContext *_context;
}

- (void)setUp
{
  [super setUp];
  NSError *error = nil;
  _transport = [[ODataSnapshotTransport alloc] initWithDirectory:OISSnapshotDirectory()
                                                     serviceRoot:OISTestServiceRoot()
                                                           error:&error];
  XCTAssertNotNil(_transport, @"%@", error);
  [ODataIncrementalStore registerStore];
  NSManagedObjectModel *model = OISCatalogModel();
  XCTAssertNotNil(model, @"Catalog.xcdatamodeld at %@", OISCatalogModelURL());
  NSPersistentStoreCoordinator *psc =
      [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSPersistentStore *generic =
      [psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                        configuration:nil
                                  URL:OISTestServiceRoot()
                              options:@{ ODataIncrementalStoreTransportOption: _transport }
                                error:&error];
  XCTAssertNotNil(generic, @"loadMetadata: %@", error);
  XCTAssertTrue([generic isKindOfClass:[ODataIncrementalStore class]]);
  _store = (ODataIncrementalStore *)generic;
  _context = [[NSManagedObjectContext alloc] init];
  _context.persistentStoreCoordinator = psc;
}

// Every request the store made has to be one a real service would take:
// version headers, a JSON Content-Type on a body, an Accept that admits
// the response. The snapshot transport refuses the rest.
- (void)tearDown
{
  if (_transport) XCTAssertEqualObjects(_transport.refusals, @[], @"requests a service would refuse");
  [super tearDown];
}

- (NSEntityDescription *)productEntity
{
  return _store.persistentStoreCoordinator.managedObjectModel.entitiesByName[@"Product"]
         ?: OISCatalogEntity(@"Product");
}

- (NSFetchRequest *)productFetch
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.entity = [self productEntity];
  fetch.returnsObjectsAsFaults = YES;
  return fetch;
}

- (void)testMetadataSnapshotIsRequiredToOpen
{
  XCTAssertNotNil(_store.metadata[NSStoreTypeKey]);
  XCTAssertTrue([_transport.hits containsObject:@"metadata.json"]);
}

- (void)testFetchedRowsNeedNoFurtherRequests
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  NSError *error = nil;
  NSArray *products = [_context executeFetchRequest:fetch error:&error];
  NSUInteger before = _transport.hits.count;
  for (NSManagedObject *product in products) {
    XCTAssertNotNil([product valueForKey:@"name"]);
    // The row named its category (Category($select=CategoryID)), so the
    // relationship is known without asking.
    XCTAssertNotNil([[product valueForKey:@"category"] objectID]);
  }
  XCTAssertEqual(_transport.hits.count, before, @"firing the faults went back to the service: %@", _transport.hits);
}

- (void)testFetchFilterHitsCollectionSnapshot
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *ids = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(ids.count, (NSUInteger)2);
  XCTAssertTrue([_transport.hits containsObject:@"products-filter.json"]);
}

- (void)testCountUsesPlainTextSnapshot
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.resultType = NSCountResultType;
  fetch.predicate = [NSPredicate predicateWithFormat:@"discontinued == NO"];
  NSError *error = nil;
  NSArray *result = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqualObjects(result.firstObject, @5);
  XCTAssertTrue([_transport.hits containsObject:@"products-count.json"]);
}

- (void)testDictionarySelect
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.resultType = NSDictionaryResultType;
  fetch.propertiesToFetch = @[ @"name", @"unitPrice" ];
  NSError *error = nil;
  NSArray *rows = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(rows.count, (NSUInteger)2);
  XCTAssertEqualObjects(rows[0][@"name"], @"Chai");
  XCTAssertTrue([_transport.hits containsObject:@"products-select.json"]);
}

- (void)testFaultFulfillmentHitsEntityByKey
{
  // An object ID the store has no row for, as a URI or another context
  // could hand it: firing its fault is a GET by key.
  ODataResourceIdentifier *four = [[ODataResourceIdentifier alloc] initWithEntitySet:@"Products" keys:@{ @"ProductID": @4 }];
  NSManagedObjectID *oid = [_store newObjectIDForEntity:[self productEntity] referenceObject:four.data];
  NSError *error = nil;
  NSIncrementalStoreNode *node = [_store newValuesForObjectWithID:oid withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertNotNil(node);
  XCTAssertEqualObjects([node valueForPropertyDescription:[self productEntity].attributesByName[@"name"]], @"Chef Anton's Cajun Seasoning");
  XCTAssertTrue([_transport.hits containsObject:@"product-by-key.json"]);
}

- (void)testRelationshipNavigation
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *ids = [_store executeRequest:fetch withContext:_context error:&error];
  NSRelationshipDescription *rel = [self productEntity].relationshipsByName[@"category"];
  id value = [_store newValueForRelationship:rel forObjectWithID:ids.firstObject withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertTrue([value isKindOfClass:[NSManagedObjectID class]]);
  XCTAssertTrue([_transport.hits containsObject:@"product-category.json"]);
}

- (void)testExpandPrefetch
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.relationshipKeyPathsForPrefetching = @[ @"category" ];
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *ids = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(ids.count, (NSUInteger)1);
  XCTAssertTrue([_transport.hits containsObject:@"products-expand.json"]);
}

- (void)testInsertPostsEntity
{
  NSManagedObject *object =
      [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:_context];
  [object setValue:@"New Blend" forKey:@"name"];
  [object setValue:@9.5 forKey:@"unitPrice"];
  [object setValue:@NO forKey:@"discontinued"];
  NSError *error = nil;
  NSArray *ids = [_store obtainPermanentIDsForObjects:@[ object ] error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(ids.count, (NSUInteger)1);
  XCTAssertTrue([_transport.hits containsObject:@"product-create.json"]);
}

- (void)testPatchSendsIfMatch
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *oids = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  [_store newValuesForObjectWithID:oids.firstObject withContext:_context error:&error];
  NSManagedObject *object = [_context objectWithID:oids.firstObject];
  // Filter snapshot already has UnitPrice 22 on Products(4).
  [object setValue:@23 forKey:@"unitPrice"];
  NSSaveChangesRequest *save =
      [[NSSaveChangesRequest alloc] initWithInsertedObjects:nil
                                             updatedObjects:[NSSet setWithObject:object]
                                             deletedObjects:nil
                                               lockedObjects:nil];
  id result = [_store executeRequest:save withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqualObjects(result, @[]);
  XCTAssertTrue([_transport.hits containsObject:@"product-patch.json"]);
}

- (void)testStaleETagIsOptimisticLock
{
  ODataConfiguration *configuration =
      [[ODataConfiguration alloc] initWithURL:OISTestServiceRoot() options:nil];
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:configuration];
  client.transport = _transport;
  NSURL *url = [NSURL URLWithString:@"https://odata.test/V4/Northwind.svc/Products(4)"];
  NSError *error = nil;
  ODataHTTPResponse *response =
      [client sendJSONMethod:@"PATCH" URL:url body:@{ @"UnitPrice": @1 } etag:@"W/\"stale\"" error:&error];
  XCTAssertNil(response);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorOptimisticLocking);
  XCTAssertTrue([_transport.hits containsObject:@"product-precondition.json"]);
}

- (void)testDelete
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *oids = [_store executeRequest:fetch withContext:_context error:&error];
  [_store newValuesForObjectWithID:oids.firstObject withContext:_context error:&error];
  NSManagedObject *object = [_context objectWithID:oids.firstObject];
  NSSaveChangesRequest *save =
      [[NSSaveChangesRequest alloc] initWithInsertedObjects:nil
                                             updatedObjects:nil
                                             deletedObjects:[NSSet setWithObject:object]
                                               lockedObjects:nil];
  id result = [_store executeRequest:save withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqualObjects(result, @[]);
  XCTAssertTrue([_transport.hits containsObject:@"product-delete.json"]);
}

- (void)testFetchFollowsNextLinks
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice < 10"];
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *ids = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(ids.count, (NSUInteger)3);
  XCTAssertTrue([_transport.hits containsObject:@"products-page-1.json"]);
  XCTAssertTrue([_transport.hits containsObject:@"products-page-2.json"]);
}

- (NSManagedObjectID *)categoryOfFirstFilteredProduct
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *ids = [_store executeRequest:fetch withContext:_context error:&error];
  NSRelationshipDescription *rel = [self productEntity].relationshipsByName[@"category"];
  return [_store newValueForRelationship:rel forObjectWithID:ids.firstObject withContext:_context error:&error];
}

- (void)testToManyRelationshipFollowsNextLinks
{
  NSManagedObjectID *category = [self categoryOfFirstFilteredProduct];
  XCTAssertTrue([category isKindOfClass:[NSManagedObjectID class]]);
  NSRelationshipDescription *products = category.entity.relationshipsByName[@"products"];
  NSError *error = nil;
  NSArray *ids = [_store newValueForRelationship:products forObjectWithID:category withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(ids.count, (NSUInteger)2);
  XCTAssertTrue([_transport.hits containsObject:@"category-products-page-2.json"]);
}

- (void)testPredicateComparesObjectsByKey
{
  NSManagedObjectID *category = [self categoryOfFirstFilteredProduct];
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"category == %@", category];
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *ids = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(ids.count, (NSUInteger)2);
  XCTAssertTrue([_transport.hits containsObject:@"products-by-category.json"]);
}

- (void)testFailedFetchIsAnErrorNotAnEmptyResult
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 999"];
  NSError *error = nil;
  NSArray *rows = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(rows);
  XCTAssertNotNil(error);
}

- (void)testTransportRefusesWhatAServiceWould
{
  ODataConfiguration *configuration =
      [[ODataConfiguration alloc] initWithURL:OISTestServiceRoot() options:nil];
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:configuration];
  client.transport = _transport;
  // $metadata is XML; asking for JSON only is what used to break Northwind.
  NSURL *url = [OISTestServiceRoot() URLByAppendingPathComponent:@"$metadata"];
  NSError *error = nil;
  XCTAssertNil([client JSONAtURL:url error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorHTTP + 406);
  XCTAssertEqual(_transport.refusals.count, (NSUInteger)1);
  _transport = nil;  // this refusal was the point; tearDown checks the rest
}

#pragma mark - Writes through the context

- (NSArray *)fetch:(NSString *)entity where:(NSString *)format, ...
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  if (format) {
    va_list args;
    va_start(args, format);
    fetch.predicate = [NSPredicate predicateWithFormat:format arguments:args];
    va_end(args);
  }
  NSError *error = nil;
  NSArray *rows = [_context executeFetchRequest:fetch error:&error];
  XCTAssertNotNil(rows, @"%@", error);
  return rows;
}

// Products(4) and (6), from the filter snapshot.
- (NSManagedObject *)productFour
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  NSError *error = nil;
  NSArray *rows = [_context executeFetchRequest:fetch error:&error];
  XCTAssertEqual(rows.count, (NSUInteger)2, @"%@", error);
  return rows.firstObject;
}

- (NSManagedObject *)categoryWithID:(NSInteger)categoryID
{
  for (NSManagedObject *category in [self fetch:@"Category" where:nil]) {
    if ([[category valueForKey:@"id"] integerValue] == categoryID) return category;
  }
  XCTFail(@"no Categories(%ld)", (long)categoryID);
  return nil;
}

- (void)save
{
  NSError *error = nil;
  XCTAssertTrue([_context save:&error], @"%@", error);
}

- (void)testETagsGoBackExactlyAsGiven
{
  NSManagedObject *pears = [self fetch:@"Product" where:@"name == %@", @"Uncle Bob's Organic Dried Pears"].firstObject;
  [pears setValue:[NSDecimalNumber decimalNumberWithString:@"31"] forKey:@"unitPrice"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-opaque-patch-1.json"]);
  // The next write sends the ETag the first one came back with.
  [pears setValue:[NSDecimalNumber decimalNumberWithString:@"32"] forKey:@"unitPrice"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-opaque-patch-2.json"]);
}

- (void)testNoETagMeansNoIfMatch
{
  NSManagedObject *tofu = [self fetch:@"Product" where:@"name == %@", @"Tofu"].firstObject;
  [tofu setValue:[NSDecimalNumber decimalNumberWithString:@"24"] forKey:@"unitPrice"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-untagged-patch.json"]);
}

- (void)testToOneChangePutsTheReference
{
  NSManagedObject *product = [self productFour];
  [product setValue:[self categoryWithID:1] forKey:@"category"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-rebind.json"]);
  // The reference changed the entity; its ETag is read back.
  XCTAssertEqualObjects(_transport.hits.lastObject, @"product-by-key.json");
}

- (void)testClearingToOneDeletesTheReference
{
  NSManagedObject *product = [self productFour];
  XCTAssertNotNil([product valueForKey:@"category"]);
  [product setValue:nil forKey:@"category"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-unbind.json"]);
}

- (void)testInsertBindsToOne
{
  NSManagedObject *category = [self categoryWithID:2];
  NSManagedObject *product = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:_context];
  [product setValue:@"Bound Blend" forKey:@"name"];
  [product setValue:[NSDecimalNumber decimalNumberWithString:@"5"] forKey:@"unitPrice"];
  [product setValue:category forKey:@"category"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-create-bound.json"]);
  XCTAssertFalse(product.objectID.isTemporaryID);
}

- (void)testNewObjectsArePostedInDependencyOrder
{
  NSManagedObject *category = [NSEntityDescription insertNewObjectForEntityForName:@"Category" inManagedObjectContext:_context];
  [category setValue:@"Teas" forKey:@"name"];
  NSManagedObject *product = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:_context];
  [product setValue:@"Earl Grey" forKey:@"name"];
  [product setValue:category forKey:@"category"];
  // The product comes first here; the category has to be posted first.
  NSError *error = nil;
  NSArray *ids = [_store obtainPermanentIDsForObjects:@[ product, category ] error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(ids.count, (NSUInteger)2);
  NSUInteger categoryAt = [_transport.hits indexOfObject:@"category-create.json"];
  NSUInteger productAt = [_transport.hits indexOfObject:@"product-create-in-new-category.json"];
  XCTAssertNotEqual(categoryAt, (NSUInteger)NSNotFound);
  XCTAssertNotEqual(productAt, (NSUInteger)NSNotFound);
  XCTAssertLessThan(categoryAt, productAt);
  XCTAssertEqualObjects([ids[0] entity].name, @"Product");
}

- (void)testInsertAnsweredWith204ReadsLocation
{
  NSManagedObject *product = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:_context];
  [product setValue:@"Quiet Blend" forKey:@"name"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-create-204.json"]);
  XCTAssertTrue([_transport.hits containsObject:@"product-79.json"]);
}

- (void)testClientChosenKeyIsSent
{
  NSManagedObject *product = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:_context];
  [product setValue:@90 forKey:@"id"];
  [product setValue:@"Keyed Blend" forKey:@"name"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-create-keyed.json"]);
}

- (void)testManyToManyChangesAreReferences
{
  NSManagedObject *product = [self productFour];
  NSManagedObject *exotic = nil;
  NSManagedObject *cajun = nil;
  for (NSManagedObject *supplier in [self fetch:@"Supplier" where:nil]) {
    if ([[supplier valueForKey:@"id"] integerValue] == 1) exotic = supplier;
    if ([[supplier valueForKey:@"id"] integerValue] == 2) cajun = supplier;
  }
  // Membership through the plain set: FreeCoreData's mutable relationship
  // set cannot enumerate yet, though adding and removing work.
  XCTAssertTrue([[product valueForKey:@"suppliers"] containsObject:cajun]);
  NSMutableSet *suppliers = [product mutableSetValueForKey:@"suppliers"];
  [suppliers addObject:exotic];
  [suppliers removeObject:cajun];
  [self save];
  // Product sorts before Supplier, so only the Product side is written.
  XCTAssertTrue([_transport.hits containsObject:@"product-suppliers-ref-add.json"]);
  XCTAssertTrue([_transport.hits containsObject:@"product-suppliers-ref-remove.json"]);
}

#pragma mark - Robustness

- (void)testServiceErrorBecomesTheNSError
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 5000"];
  NSError *error = nil;
  XCTAssertNil([_store executeRequest:fetch withContext:_context error:&error]);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorHTTP + 400);
  XCTAssertEqualObjects(error.localizedDescription, @"The filter is not valid.");
  XCTAssertEqualObjects(error.userInfo[ODataErrorHTTPStatusKey], @400);
  XCTAssertEqualObjects(error.userInfo[ODataErrorCodeKey], @"InvalidFilter");
  XCTAssertEqualObjects(error.userInfo[ODataErrorTargetKey], @"$filter");
  NSArray *details = error.userInfo[ODataErrorDetailsKey];
  XCTAssertEqual(details.count, (NSUInteger)1);
  XCTAssertEqualObjects(details.firstObject[@"target"], @"UnitPrice");
}

- (void)testWritesGoToTheEditLink
{
  NSManagedObject *ikura = [self fetch:@"Product" where:@"name == %@", @"Ikura"].firstObject;
  [ikura setValue:[NSDecimalNumber decimalNumberWithString:@"32"] forKey:@"unitPrice"];
  [self save];
  XCTAssertTrue([_transport.hits containsObject:@"product-edit-link-patch.json"]);
}

- (void)testFetchBatchSizeAsksForThatPageSize
{
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 100"];
  fetch.fetchBatchSize = 2;
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *ids = [_store executeRequest:fetch withContext:_context error:&error];
  XCTAssertNil(error, @"%@", error);
  XCTAssertEqual(ids.count, (NSUInteger)1);
  XCTAssertTrue([_transport.hits containsObject:@"products-page-size.json"]);
}

- (void)testUnmatchedRequestDoesNotHitTheNetwork
{
  ODataConfiguration *configuration =
      [[ODataConfiguration alloc] initWithURL:OISTestServiceRoot() options:nil];
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:configuration];
  client.transport = _transport;
  NSError *error = nil;
  id json = [client JSONAtURL:[NSURL URLWithString:@"https://odata.test/V4/Northwind.svc/NoSuchSet"] error:&error];
  XCTAssertNil(json);
  XCTAssertEqual(error.code, ODataIncrementalStoreErrorTransport);
  XCTAssertTrue([error.localizedDescription rangeOfString:@"No snapshot"].location != NSNotFound);
}

- (void)testClientSendsODataVersion4
{
  ODataConfiguration *configuration =
      [[ODataConfiguration alloc] initWithURL:OISTestServiceRoot() options:nil];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:OISTestServiceRoot()];
  [configuration applyToRequest:req];
  XCTAssertEqualObjects([req valueForHTTPHeaderField:@"OData-Version"], @"4.0");
  XCTAssertEqualObjects([req valueForHTTPHeaderField:@"OData-MaxVersion"], @"4.0");
  XCTAssertTrue([[req valueForHTTPHeaderField:@"Accept"] containsString:@"odata.metadata=minimal"]);
}

@end
