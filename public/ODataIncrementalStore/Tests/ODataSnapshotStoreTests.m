// Store + client against recorded OData v4 pairs. No live endpoint.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

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
  NSFetchRequest *fetch = [self productFetch];
  fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  fetch.fetchLimit = 25;
  fetch.resultType = NSManagedObjectIDResultType;
  NSError *error = nil;
  NSArray *ids = [_store executeRequest:fetch withContext:_context error:&error];
  NSManagedObjectID *oid = ids.firstObject;
  XCTAssertNotNil(oid);
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
  [object setValue:@22 forKey:@"unitPrice"];
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
