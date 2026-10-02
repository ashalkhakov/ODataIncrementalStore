// An offline store kept in sync with a service (docs/offline-sync.md): the
// engine against an ODataService in the process, each with a SQLite store
// of its own that keeps history.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import <ODataSync/ODataSync.h>
#import <ODataService/ODataService.h>
#import <ODataKit/ODataError.h>

// Refuses an inspection whose note is "bad", as a service's rule would.
@interface OSTPickyInspections : ODataEntitySetHandler
@end

@implementation OSTPickyInspections
- (NSManagedObject *)insertObjectWithValues:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  if ([values[@"note"] isEqual:@"bad"]) {
    [reply failWithError:ODataServiceError(400, @"A note cannot be bad")];
    return nil;
  }
  return [super insertObjectWithValues:values request:request reply:reply];
}
@end

// Both titles, joined; or set aside, when told to.
@interface OSTJoiningResolver : NSObject <ODataSyncResolving>
@property (nonatomic) BOOL defers;
@property (atomic, strong) ODataSyncConflict *last;
@end

@implementation OSTJoiningResolver
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  self.last = conflict;
  if (self.defers) return [ODataSyncResolution defer];
  return [ODataSyncResolution mergedValues:@{ @"title": [NSString stringWithFormat:@"%@ / %@", conflict.local[@"title"], conflict.remote[@"title"]] }];
}
@end

@interface OSTDelegate : NSObject <ODataSyncDelegate>
@property (atomic, strong) NSMutableArray *setAside;
@property (atomic, strong) NSMutableArray *ignored;
@end

@implementation OSTDelegate
- (instancetype)init
{
  self = [super init];
  _setAside = [NSMutableArray array];
  _ignored = [NSMutableArray array];
  return self;
}
- (void)syncEngine:(ODataSyncEngine *)engine didSetAside:(ODataSyncIssue *)issue
{
  [self.setAside addObject:issue];
}
- (void)syncEngine:(ODataSyncEngine *)engine ignoredLocalChangeToObject:(NSManagedObjectID *)objectID
{
  [self.ignored addObject:objectID];
}
@end

static NSAttributeDescription *OSTAttribute(NSString *name, NSAttributeType type, BOOL key)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = YES;
  attribute.preservesValueInHistoryOnDeletion = YES;
  if (key) attribute.userInfo = @{ @"OData.key": @"YES" };
  return attribute;
}

// Assets (down), Inspections (up, each of an asset), Tasks (both).
static NSManagedObjectModel *OSTModel(void)
{
  NSEntityDescription *asset = [[NSEntityDescription alloc] init];
  asset.name = @"Asset";
  asset.managedObjectClassName = @"NSManagedObject";
  asset.userInfo = @{ @"OData.entitySet": @"Assets", ODataSyncDirectionKey: @"down" };
  NSEntityDescription *inspection = [[NSEntityDescription alloc] init];
  inspection.name = @"Inspection";
  inspection.managedObjectClassName = @"NSManagedObject";
  inspection.userInfo = @{ @"OData.entitySet": @"Inspections", ODataSyncDirectionKey: @"up" };
  NSEntityDescription *task = [[NSEntityDescription alloc] init];
  task.name = @"Task";
  task.managedObjectClassName = @"NSManagedObject";
  task.userInfo = @{ @"OData.entitySet": @"Tasks", ODataSyncDirectionKey: @"both", ODataSyncModifiedKey: @"modified" };

  NSRelationshipDescription *ofAsset = [[NSRelationshipDescription alloc] init];
  ofAsset.name = @"asset";
  ofAsset.destinationEntity = asset;
  ofAsset.maxCount = 1;
  ofAsset.optional = YES;
  ofAsset.deleteRule = NSNullifyDeleteRule;
  NSRelationshipDescription *inspections = [[NSRelationshipDescription alloc] init];
  inspections.name = @"inspections";
  inspections.destinationEntity = inspection;
  inspections.maxCount = 0;
  inspections.optional = YES;
  inspections.deleteRule = NSNullifyDeleteRule;
  ofAsset.inverseRelationship = inspections;
  inspections.inverseRelationship = ofAsset;

  asset.properties = @[ OSTAttribute(@"id", NSInteger32AttributeType, YES), OSTAttribute(@"name", NSStringAttributeType, NO),
                        OSTAttribute(@"region", NSStringAttributeType, NO), inspections ];
  inspection.properties = @[ OSTAttribute(@"id", NSStringAttributeType, YES), OSTAttribute(@"note", NSStringAttributeType, NO),
                             OSTAttribute(@"score", NSInteger32AttributeType, NO), ofAsset ];
  task.properties = @[ OSTAttribute(@"id", NSStringAttributeType, YES), OSTAttribute(@"title", NSStringAttributeType, NO),
                       OSTAttribute(@"done", NSBooleanAttributeType, NO), OSTAttribute(@"modified", NSStringAttributeType, NO) ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ asset, inspection, task ];
  return model;
}

@interface ODataSyncTests : XCTestCase
@end

@implementation ODataSyncTests {
  NSMutableArray<NSURL *> *_files;
  NSPersistentStoreCoordinator *_server;
  ODataService *_service;
  NSPersistentStoreCoordinator *_device;
  ODataSyncEngine *_engine;
  ODataSyncRemote *_remote;
  OSTDelegate *_delegate;
}

- (NSPersistentStoreCoordinator *)coordinatorWithModel:(NSManagedObjectModel *)model
{
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
  [_files addObject:url];
  NSError *error = nil;
  XCTAssertNotNil([coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:url
                                                  options:@{ NSPersistentHistoryTrackingKey: @YES } error:&error], @"%@", error);
  return coordinator;
}

- (void)setUp
{
  _files = [NSMutableArray array];
  _server = [self coordinatorWithModel:OSTModel()];
  [self atServer:^(NSManagedObjectContext *context) {
    for (NSArray *a in @[ @[ @1, @"Pump", @"North" ], @[ @2, @"Valve", @"North" ], @[ @3, @"Boiler", @"South" ] ]) {
      NSManagedObject *asset = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
      [asset setValue:a[0] forKey:@"id"];
      [asset setValue:a[1] forKey:@"name"];
      [asset setValue:a[2] forKey:@"region"];
    }
  }];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:_server serviceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];

  NSManagedObjectModel *model = OSTModel();
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  _device = [self coordinatorWithModel:model];
  _engine = [[ODataSyncEngine alloc] initWithCoordinator:_device];
  _delegate = [[OSTDelegate alloc] init];
  _engine.delegate = _delegate;
  _remote = [ODataSyncRemote remoteWithServiceRoot:[NSURL URLWithString:@"http://example.test/odata/"]];
  _remote.transport = _service;
  [_engine addRemote:_remote];
}

- (void)tearDown
{
  for (NSURL *url in _files) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
      [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
    }
  }
}

#pragma mark Helpers

- (void)in:(NSPersistentStoreCoordinator *)coordinator do:(void (^)(NSManagedObjectContext *context))work
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = coordinator;
  [context performBlockAndWait:^{
    work(context);
    NSError *error = nil;
    if (context.hasChanges) XCTAssertTrue([context save:&error], @"%@", error);
  }];
}

- (void)atServer:(void (^)(NSManagedObjectContext *context))work
{
  [self in:_server do:work];
}

- (void)onDevice:(void (^)(NSManagedObjectContext *context))work
{
  [self in:_device do:work];
}

- (NSArray *)values:(NSString *)key of:(NSString *)entity in:(NSPersistentStoreCoordinator *)coordinator
{
  __block NSArray *values = nil;
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
    values = [[context executeFetchRequest:fetch error:NULL] valueForKey:key];
  }];
  return values;
}

- (NSManagedObject *)object:(NSString *)entity id:(id)identifier in:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", identifier];
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

- (void)sync
{
  NSError *error = nil;
  XCTAssertTrue([_engine syncWithError:&error], @"%@", error);
}

- (NSString *)inspect:(NSString *)note asset:(NSNumber *)assetID
{
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *inspection = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [inspection setValue:identifier forKey:@"id"];
    [inspection setValue:note forKey:@"note"];
    [inspection setValue:@3 forKey:@"score"];
    if (assetID) [inspection setValue:[self object:@"Asset" id:assetID in:context] forKey:@"asset"];
  }];
  return identifier;
}

#pragma mark Down

- (void)testDownloadWholeThenByDeltaLink
{
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump", @"Valve", @"Boiler" ]));
  XCTAssertEqual(_engine.lastResult.downloaded, 3u);

  [self atServer:^(NSManagedObjectContext *context) {
    [[self object:@"Asset" id:@1 in:context] setValue:@"Pump (new)" forKey:@"name"];
    [context deleteObject:[self object:@"Asset" id:@2 in:context]];
    NSManagedObject *added = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
    [added setValue:@4 forKey:@"id"];
    [added setValue:@"Fan" forKey:@"name"];
  }];
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump (new)", @"Boiler", @"Fan" ]));
  XCTAssertEqual(_engine.lastResult.downloaded, 2u, @"only what changed: %@", _engine.lastResult);
  XCTAssertEqual(_engine.lastResult.removed, 1u);

  [self sync];
  XCTAssertEqual(_engine.lastResult.downloaded, 0u, @"nothing new: %@", _engine.lastResult);
}

- (void)testAnExpiredDeltaLinkReadsTheSetAgain
{
  [self sync];
  [self atServer:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Asset" id:@3 in:context]];
  }];
  NSError *error = nil;
  XCTAssertTrue([_service pruneHistoryBeforeDate:[NSDate dateWithTimeIntervalSinceNow:1] error:&error], @"%@", error);
  [self sync];
  XCTAssertEqualObjects([self values:@"id" of:@"Asset" in:_device], (@[ @1, @2 ]), @"read again, and what is gone swept");
}

- (void)testFilteredSets
{
  _remote.filters = @{ @"Asset": @"Region eq 'North'" };
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump", @"Valve" ]));
  // Another filter: another set, read again.
  _remote.filters = @{ @"Asset": @"Region eq 'South'" };
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Boiler" ]));
}

- (void)testReconcilingKeys
{
  [self sync];
  // Here, a row the service has not (a down entity is not sent); and one
  // of its rows missing.
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *stray = [NSEntityDescription insertNewObjectForEntityForName:@"Asset" inManagedObjectContext:context];
    [stray setValue:@99 forKey:@"id"];
    [context deleteObject:[self object:@"Asset" id:@2 in:context]];
  }];
  NSError *error = nil;
  XCTAssertTrue([_engine reconcileWithRemote:_remote error:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"id" of:@"Asset" in:_device], (@[ @1, @2, @3 ]));
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_device], (@[ @"Pump", @"Valve", @"Boiler" ]));
}

- (void)testLocalChangesToDownEntitiesAreNotSent
{
  [self sync];
  [self onDevice:^(NSManagedObjectContext *context) {
    [[self object:@"Asset" id:@1 in:context] setValue:@"Mine" forKey:@"name"];
  }];
  [self sync];
  XCTAssertEqualObjects([self values:@"name" of:@"Asset" in:_server].firstObject, @"Pump");
  XCTAssertEqual(_delegate.ignored.count, 1u);
}

#pragma mark Up

- (void)testUploadByUpsert
{
  [self sync];
  NSString *first = [self inspect:@"Leaks" asset:@1];
  NSString *second = [self inspect:@"Fine" asset:@2];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 2u, @"%@", _engine.lastResult);
  XCTAssertEqualObjects([NSSet setWithArray:[self values:@"note" of:@"Inspection" in:_server]], ([NSSet setWithObjects:@"Leaks", @"Fine", nil]));
  __block NSString *assetName = nil;
  [self atServer:^(NSManagedObjectContext *context) {
    assetName = [[self object:@"Inspection" id:first in:context] valueForKeyPath:@"asset.name"];
  }];
  XCTAssertEqualObjects(assetName, @"Pump", @"bound to its asset");

  // Changed, then deleted.
  [self onDevice:^(NSManagedObjectContext *context) {
    [[self object:@"Inspection" id:first in:context] setValue:@"Leaks badly" forKey:@"note"];
    [context deleteObject:[self object:@"Inspection" id:second in:context]];
  }];
  [self sync];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"Leaks badly" ]));

  // Made and gone before a sync: never sent.
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *fleeting = [NSEntityDescription insertNewObjectForEntityForName:@"Inspection" inManagedObjectContext:context];
    [fleeting setValue:@"fleeting" forKey:@"id"];
    [context save:NULL];
    [context deleteObject:fleeting];
  }];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 0u, @"%@", _engine.lastResult);
}

- (void)testSendingAgainIsHarmless
{
  [self sync];
  [self inspect:@"Once" asset:@1];
  [self sync];
  // The engine forgets how far it got (a crash before it could save): it
  // sends everything again, which the upserts take as the same.
  [self onDevice:^(NSManagedObjectContext *context) {
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"ODSRemoteState"];
    [[[context executeFetchRequest:fetch error:NULL] firstObject] setValue:nil forKey:@"historyToken"];
  }];
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 1u, @"sent again: %@", _engine.lastResult);
  XCTAssertEqual([self values:@"id" of:@"Inspection" in:_server].count, 1u, @"one inspection, not two");
}

- (void)testRefusedChangesAreSetAside
{
  [_service setHandler:[[OSTPickyInspections alloc] initWithEntity:_server.managedObjectModel.entitiesByName[@"Inspection"]] forEntitySet:@"Inspections"];
  [self sync];
  NSString *bad = [self inspect:@"bad" asset:@1];
  [self inspect:@"good" asset:@2];
  [self sync];
  XCTAssertEqualObjects([self values:@"note" of:@"Inspection" in:_server], (@[ @"good" ]), @"the rest went");
  XCTAssertEqual(_engine.lastResult.refused, 1u);
  NSArray<ODataSyncIssue *> *issues = [_engine issues];
  XCTAssertEqual(issues.count, 1u);
  XCTAssertEqual(issues.firstObject.status, 400);
  XCTAssertEqualObjects(issues.firstObject.message, @"A note cannot be bad");
  XCTAssertNotNil(issues.firstObject.objectID);
  XCTAssertEqual(_delegate.setAside.count, 1u);

  // Not sent again by itself; put right, it is.
  [self sync];
  XCTAssertEqual(_engine.lastResult.uploaded, 0u);
  [self onDevice:^(NSManagedObjectContext *context) {
    [[self object:@"Inspection" id:bad in:context] setValue:@"better" forKey:@"note"];
  }];
  [self sync];
  XCTAssertEqualObjects([NSSet setWithArray:[self values:@"note" of:@"Inspection" in:_server]], ([NSSet setWithObjects:@"good", @"better", nil]));
  XCTAssertEqual([_engine issues].count, 0u);
}

#pragma mark Both

- (NSString *)makeTask:(NSString *)title
{
  NSString *identifier = [NSUUID UUID].UUIDString;
  [self onDevice:^(NSManagedObjectContext *context) {
    NSManagedObject *task = [NSEntityDescription insertNewObjectForEntityForName:@"Task" inManagedObjectContext:context];
    [task setValue:identifier forKey:@"id"];
    [task setValue:title forKey:@"title"];
  }];
  return identifier;
}

- (void)retitle:(NSString *)identifier to:(NSString *)title in:(NSPersistentStoreCoordinator *)coordinator
{
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    [[self object:@"Task" id:identifier in:context] setValue:title forKey:@"title"];
  }];
}

- (void)testBothWaysWithoutConflict
{
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Check pump" ]));
  [self retitle:task to:@"Check pump (server)" in:_server];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Check pump (server)" ]), @"came down");
  [self retitle:task to:@"Check pump (device)" in:_device];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Check pump (device)" ]), @"went up");
  XCTAssertEqual(_engine.lastResult.conflicts, 0u);
}

- (void)testConflictTheRemoteWins
{
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self retitle:task to:@"Server's" in:_server];
  [self retitle:task to:@"Device's" in:_device];
  [self sync];
  XCTAssertGreaterThan(_engine.lastResult.conflicts, 0u);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Server's" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Server's" ]), @"the device's change dropped");
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Server's" ]), @"and not sent later");
}

- (void)testConflictTheDeviceWins
{
  _engine.conflictPolicy = ODataSyncPolicyLocalWins;
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self retitle:task to:@"Server's" in:_server];
  [self retitle:task to:@"Device's" in:_device];
  [self sync];
  XCTAssertGreaterThan(_engine.lastResult.conflicts, 0u);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Device's" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Device's" ]));
}

#pragma mark Conflicts

- (void)set:(NSDictionary *)values onTask:(NSString *)identifier in:(NSPersistentStoreCoordinator *)coordinator
{
  [self in:coordinator do:^(NSManagedObjectContext *context) {
    NSManagedObject *task = [self object:@"Task" id:identifier in:context];
    for (NSString *name in values) [task setValue:values[name] forKey:name];
  }];
}

- (void)testMergeFields
{
  _engine.resolver = [[ODataSyncMergeFields alloc] init];
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self set:@{ @"title": @"Check pump today" } onTask:task in:_server];
  [self set:@{ @"done": @YES } onTask:task in:_device];
  [self sync];
  XCTAssertEqual(_engine.lastResult.conflicts, 1u);
  for (NSPersistentStoreCoordinator *side in @[ _server, _device ]) {
    XCTAssertEqualObjects([self values:@"title" of:@"Task" in:side], (@[ @"Check pump today" ]), @"the server's title");
    XCTAssertEqualObjects([self values:@"done" of:@"Task" in:side], (@[ @YES ]), @"the device's done");
  }

  // Both changed the title: the fallback (the remote) decides that one.
  [self set:@{ @"title": @"Server's" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's", @"done": @NO } onTask:task in:_device];
  [self sync];
  for (NSPersistentStoreCoordinator *side in @[ _server, _device ]) {
    XCTAssertEqualObjects([self values:@"title" of:@"Task" in:side], (@[ @"Server's" ]));
    XCTAssertEqualObjects([self values:@"done" of:@"Task" in:side], (@[ @NO ]), @"what only the device changed still goes");
  }
}

- (void)testLastWriterWins
{
  [_engine setResolver:[[ODataSyncLastWriterWins alloc] init] forEntityName:@"Task"];
  NSString *task = [self makeTask:@"Check pump"];
  XCTAssertNotNil([self values:@"modified" of:@"Task" in:_device].firstObject, @"stamped when saved");
  [self sync];

  // The device changes it, then the service, later.
  [self set:@{ @"title": @"Device's" } onTask:task in:_device];
  NSString *later = [NSString stringWithFormat:@"%016lld.0000.server00", (long long)([[NSDate date] timeIntervalSince1970] * 1000) + 60000];
  [self set:@{ @"title": @"Server's, later", @"modified": later } onTask:task in:_server];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Server's, later" ]));

  // The service, with a stamp from before; then the device: the device's stands.
  [self set:@{ @"title": @"Server's, earlier", @"modified": @"0000000000000001.0000.server00" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's, after" } onTask:task in:_device];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Device's, after" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Device's, after" ]));
  NSString *stamp = [self values:@"modified" of:@"Task" in:_device].firstObject;
  XCTAssertEqual([stamp compare:later], NSOrderedDescending, @"the clock went past what it saw: %@ after %@", stamp, later);
}

- (void)testCustomResolverAndTheConflictItSees
{
  OSTJoiningResolver *joining = [[OSTJoiningResolver alloc] init];
  [_engine setResolver:joining forEntityName:@"Task"];
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self set:@{ @"title": @"Server's" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's" } onTask:task in:_device];
  [self sync];
  ODataSyncConflict *conflict = joining.last;
  XCTAssertEqualObjects(conflict.base[@"title"], @"Check pump", @"the version both had");
  XCTAssertEqualObjects(conflict.localChanges, ([NSSet setWithObjects:@"title", @"modified", nil]));
  XCTAssertEqualObjects(conflict.remoteChanges, [NSSet setWithObject:@"title"]);
  for (NSPersistentStoreCoordinator *side in @[ _server, _device ]) {
    XCTAssertEqualObjects([self values:@"title" of:@"Task" in:side], (@[ @"Device's / Server's" ]));
  }
}

- (void)testDeferredConflictsAreIssues
{
  OSTJoiningResolver *deferring = [[OSTJoiningResolver alloc] init];
  deferring.defers = YES;
  [_engine setResolver:deferring forEntityName:@"Task"];
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self set:@{ @"title": @"Server's" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's" } onTask:task in:_device];
  [self sync];
  NSArray<ODataSyncIssue *> *issues = [_engine issues];
  XCTAssertEqual(issues.count, 1u);
  XCTAssertEqual(issues.firstObject.status, 409);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Device's" ]), @"left as it was, for the user");

  // Retried: the device's goes over the server's.
  [_engine retryIssue:issues.firstObject];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Device's" ]));

  // Again, and given up: the server's comes back.
  [self set:@{ @"title": @"Server's again" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's again" } onTask:task in:_device];
  [self sync];
  [_engine discardIssue:[_engine issues].firstObject];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Server's again" ]));
  XCTAssertEqual([_engine issues].count, 0u);
}

- (void)testEditedHereDeletedThere
{
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self atServer:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Task" id:task in:context]];
  }];
  [self set:@{ @"title": @"Still needed" } onTask:task in:_device];
  [self sync];
  XCTAssertEqual([self values:@"id" of:@"Task" in:_device].count, 0u, @"the remote wins: gone here too");

  NSString *other = [self makeTask:@"Check valve"];
  [self sync];
  _engine.conflictPolicy = ODataSyncPolicyLocalWins;
  [self atServer:^(NSManagedObjectContext *context) {
    [context deleteObject:[self object:@"Task" id:other in:context]];
  }];
  [self set:@{ @"title": @"Still needed" } onTask:other in:_device];
  [self sync];
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Still needed" ]), @"the device wins: made again there");
}

- (void)testAConflictMetOnUpload
{
  // Changed there after this side last read: met by the PATCH's If-Match (412).
  NSString *task = [self makeTask:@"Check pump"];
  [self sync];
  [self set:@{ @"title": @"Server's" } onTask:task in:_server];
  [self set:@{ @"title": @"Device's" } onTask:task in:_device];
  NSError *error = nil;
  XCTAssertTrue([_engine uploadToRemote:_remote error:&error], @"%@", error);
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_server], (@[ @"Server's" ]));
  XCTAssertEqualObjects([self values:@"title" of:@"Task" in:_device], (@[ @"Server's" ]), @"the remote wins");
}

@end
