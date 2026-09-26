// What changed at the service, and Core Data's persistent history.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OASIS OData 4.01 Part 1 section 11.3 (requesting changes), 8.2.8.6
// (odata.track-changes), JSON Format section 15 (delta payloads). The
// snapshot transport's state stands for time: "changed" is the Zoo after
// a change, read again; "delta" a Zoo that tracks changes.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"
#import "ODataSnapshotTransport.h"

@interface ODataHistoryTests : XCTestCase
@end

@implementation ODataHistoryTests {
  ODataSnapshotTransport *_transport;
  ODataIncrementalStore *_store;
  NSManagedObjectContext *_context;
}

- (void)openWithOptions:(NSDictionary *)extra
{
  [ODataIncrementalStore registerStore];
  NSError *error = nil;
  NSURL *root = [NSURL URLWithString:@"https://zoo.test/Zoo.svc/"];
  _transport = [[ODataSnapshotTransport alloc] initWithDirectory:[OISSnapshotDirectory() stringByAppendingPathComponent:@"Zoo"]
                                                     serviceRoot:root error:&error];
  XCTAssertNotNil(_transport, @"%@", error);
  NSMutableDictionary *options = [@{ ODataIncrementalStoreTransportOption: _transport, NSPersistentHistoryTrackingKey: @YES } mutableCopy];
  [options addEntriesFromDictionary:extra ?: @{}];
  NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:root options:options error:&error];
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  _store = (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                                                URL:root options:options error:&error];
  XCTAssertNotNil(_store, @"%@", error);
  _context = [[NSManagedObjectContext alloc] init];
  _context.persistentStoreCoordinator = psc;
}

- (void)tearDown
{
  XCTAssertEqualObjects(_transport.refusals, @[]);
  [super tearDown];
}

- (NSManagedObject *)animalNamed:(NSString *)name
{
  NSError *error = nil;
  NSArray *all = [_context executeFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Animal"] error:&error];
  XCTAssertNotNil(all, @"%@", error);
  for (NSManagedObject *animal in all) {
    if ([[animal valueForKey:@"name"] isEqual:name]) return animal;
  }
  return nil;
}

- (NSArray *)historyAfter:(NSPersistentHistoryToken *)token
{
  NSError *error = nil;
  NSPersistentHistoryResult *result = (NSPersistentHistoryResult *)[_context executeRequest:[NSPersistentHistoryChangeRequest fetchHistoryAfterToken:token]
                                                                                     error:&error];
  XCTAssertNotNil(result, @"%@", error);
  return result.result;
}

// The key of each changed object, by change type.
- (NSDictionary *)keysIn:(NSNotification *)changes
{
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *key in @[ NSInsertedObjectIDsKey, NSUpdatedObjectIDsKey, NSDeletedObjectIDsKey ]) {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSManagedObjectID *oid in changes.userInfo[key]) {
      [ids addObject:[ODataResourceIdentifier identifierFromReference:[_store referenceObjectForObjectID:oid]].path];
    }
    out[key] = [ids sortedArrayUsingSelector:@selector(compare:)];
  }
  return out;
}

- (void)testChangesAreFoundByReadingAgainWhereThereIsNoDelta
{
  [self openWithOptions:nil];
  NSManagedObject *zebra = [self animalNamed:@"Zebra"];
  NSError *error = nil;
  NSNotification *first = [_store fetchRemoteChanges:&error];
  XCTAssertNotNil(first, @"%@", error);
  XCTAssertEqual(first.userInfo.count, (NSUInteger)0, @"the first read starts tracking");

  _transport.state = @"changed";
  NSNotification *changes = [_store fetchRemoteChanges:&error];
  XCTAssertNotNil(changes, @"%@", error);
  NSDictionary *keys = [self keysIn:changes];
  XCTAssertEqualObjects(keys[NSInsertedObjectIDsKey], @[ @"Animals(7)" ]);
  XCTAssertEqualObjects(keys[NSUpdatedObjectIDsKey], @[ @"Animals(1)" ]);
  XCTAssertEqualObjects(keys[NSDeletedObjectIDsKey], @[ @"Animals(3)" ]);
  XCTAssertTrue([_transport.hits containsObject:@"changed-animals.json"]);

  [_context mergeChangesFromContextDidSaveNotification:changes];
  XCTAssertEqualObjects([zebra valueForKey:@"name"], @"Zed", @"merged: the object shows the service's change");

  NSArray *history = [self historyAfter:nil];
  XCTAssertEqual(history.count, (NSUInteger)1);
  NSPersistentHistoryTransaction *transaction = history.firstObject;
  XCTAssertEqualObjects(transaction.author, ODataRemoteChangesAuthor);
  XCTAssertEqual(transaction.changes.count, (NSUInteger)3);
  for (NSPersistentHistoryChange *change in transaction.changes) {
    if (change.changeType != NSPersistentHistoryChangeTypeUpdate) continue;
    XCTAssertEqualObjects([change.updatedProperties valueForKey:@"name"], [NSSet setWithObject:@"name"]);
  }
  XCTAssertEqual([self historyAfter:transaction.token].count, (NSUInteger)0, @"nothing after the last transaction");
}

- (void)testChangesAreReadFromTheDeltaLink
{
  [self openWithOptions:@{ ODataIncrementalStoreTrackedEntitiesOption: @[ @"Animal" ] }];
  _transport.state = @"delta";
  NSManagedObject *zebra = [self animalNamed:@"Zebra"];
  NSError *error = nil;
  XCTAssertNotNil([_store fetchRemoteChanges:&error], @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"delta-animals.json"], @"asked to track changes: %@", _transport.hits);

  NSNotification *changes = [_store fetchRemoteChanges:&error];
  XCTAssertNotNil(changes, @"%@", error);
  NSDictionary *keys = [self keysIn:changes];
  XCTAssertEqualObjects(keys[NSInsertedObjectIDsKey], @[ @"Animals(7)" ]);
  XCTAssertEqualObjects(keys[NSUpdatedObjectIDsKey], @[ @"Animals(1)" ]);
  XCTAssertEqualObjects(keys[NSDeletedObjectIDsKey], @[ @"Animals(3)" ]);
  [_context mergeChangesFromContextDidSaveNotification:changes];
  XCTAssertEqualObjects([zebra valueForKey:@"name"], @"Zed");
  XCTAssertEqualObjects([zebra valueForKey:@"diet"], @"Herbivore", @"a partial change keeps the rest of the row");

  changes = [_store fetchRemoteChanges:&error];
  XCTAssertEqual(changes.userInfo.count, (NSUInteger)0, @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"delta-animals-2.json"], @"the next delta link is followed");
}

- (void)testSavesAreTransactions
{
  [self openWithOptions:nil];
  _context.transactionAuthor = @"tester";
  NSManagedObject *zebra = [self animalNamed:@"Zebra"];
  NSError *error = nil;
  // zebra-rehome.json is the PATCH this save sends.
  NSMutableDictionary *rehomed = [@{ @"Zone": @"Savanna North", @"Opened": ODataDateFromString(@"2015-03-01"),
                                     @"Area": [NSDecimalNumber decimalNumberWithString:@"1250"] } mutableCopy];
  [zebra setValue:rehomed forKey:@"home"];
  [zebra setValue:@[ @"Stripes", @"Zed" ] forKey:@"nicknames"];
  XCTAssertTrue([_context save:&error], @"%@", error);

  NSArray *history = [self historyAfter:nil];
  XCTAssertEqual(history.count, (NSUInteger)1);
  NSPersistentHistoryTransaction *transaction = history.firstObject;
  XCTAssertEqualObjects(transaction.author, @"tester");
  NSPersistentHistoryChange *change = transaction.changes.firstObject;
  XCTAssertEqual(change.changeType, NSPersistentHistoryChangeTypeUpdate);
  XCTAssertEqualObjects(change.changedObjectID, zebra.objectID);
  XCTAssertEqualObjects([change.updatedProperties valueForKey:@"name"], ([NSSet setWithObjects:@"home", @"nicknames", nil]));
  XCTAssertEqualObjects([[transaction.objectIDNotification.userInfo[NSUpdatedObjectIDsKey] anyObject] URIRepresentation], zebra.objectID.URIRepresentation);

  // FreeCoreData's coordinator makes tokens of its own from the store's
  // history (Apple's gives none for a store of this kind).
  NSPersistentHistoryToken *current = [_context.persistentStoreCoordinator currentPersistentHistoryTokenFromStores:nil];
#ifdef GNUSTEP
  XCTAssertNotNil(current);
#endif
  if (current) XCTAssertEqual([self historyAfter:current].count, (NSUInteger)0, @"the coordinator's token stands at the last transaction");

  NSPersistentHistoryChangeRequest *count = [NSPersistentHistoryChangeRequest fetchHistoryAfterDate:[NSDate distantPast]];
  count.resultType = NSPersistentHistoryResultTypeCount;
  NSPersistentHistoryResult *counted = (NSPersistentHistoryResult *)[_context executeRequest:count error:&error];
  XCTAssertEqualObjects(counted.result, @1, @"%@", error);
  NSPersistentHistoryResult *purged = (NSPersistentHistoryResult *)[_context executeRequest:[NSPersistentHistoryChangeRequest deleteHistoryBeforeDate:[NSDate distantFuture]]
                                                                                      error:&error];
  XCTAssertNotNil(purged, @"%@", error);
  XCTAssertEqual([self historyAfter:nil].count, (NSUInteger)0, @"deleted");
}

@end
