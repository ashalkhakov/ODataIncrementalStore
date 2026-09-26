// Actions and functions: the methods of a service's entities.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OASIS OData 4.01 Part 1 section 11.5 (operations), Part 2 section 4.5
// (addressing them) and 5.1.1.13.1 (parameter aliases), JSON Format
// section 17 (action invocation). The Zoo service's model is the one its
// $metadata describes, as a dynamic client's would be.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"
#import "ODataSnapshotTransport.h"

@interface ODataOperationTests : XCTestCase
@end

@implementation ODataOperationTests {
  ODataSnapshotTransport *_transport;
  ODataIncrementalStore *_store;
  NSManagedObjectContext *_context;
  ODataOperationCall *_finished;
}

- (void)setUp
{
  [super setUp];
  [ODataIncrementalStore registerStore];
  NSError *error = nil;
  NSURL *root = [NSURL URLWithString:@"https://zoo.test/Zoo.svc/"];
  _transport = [[ODataSnapshotTransport alloc] initWithDirectory:[OISSnapshotDirectory() stringByAppendingPathComponent:@"Zoo"]
                                                     serviceRoot:root error:&error];
  XCTAssertNotNil(_transport, @"%@", error);
  NSDictionary *options = @{ ODataIncrementalStoreTransportOption: _transport };
  NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:root options:options error:&error];
  XCTAssertNotNil(model, @"%@", error);
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

- (NSManagedObject *)fetchOne:(NSString *)entity where:(NSString *)format, ...
{
  va_list args;
  va_start(args, format);
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  NSPredicate *all = [NSPredicate predicateWithFormat:format arguments:args];
  va_end(args);
  NSError *error = nil;
  NSArray *rows = [_context executeFetchRequest:fetch error:&error];
  XCTAssertNotNil(rows, @"%@", error);
  return [rows filteredArrayUsingPredicate:all].firstObject;
}

- (void)testOperationsAreReadFromMetadata
{
  ODataSchema *schema = _store.schema;
  ODataSchemaEntityType *lion = [schema entityTypeNamed:@"Zoo.Lion"];
  NSArray *instance = [[schema operationsBoundToEntityType:lion collection:NO] valueForKey:@"name"];
  XCTAssertEqualObjects(instance, (@[ @"Age", @"Caretaker", @"CurrentHome", @"Feed", @"Move" ]), @"a derived type has its base's methods");
  XCTAssertEqualObjects([[schema operationsBoundToEntityType:lion collection:YES] valueForKey:@"name"], @[ @"Heaviest" ]);
  ODataSchemaOperation *admit = [schema operationNamed:@"AdmitAnimal" boundToEntityType:nil collection:NO parameterNames:nil];
  XCTAssertTrue(admit.isAction);
  XCTAssertEqualObjects(admit.qualifiedName, @"Zoo.Admit");
  XCTAssertEqualObjects(admit.returnType, @"Zoo.Animal", @"the alias resolves");
  XCTAssertEqualObjects([admit.callerParameters valueForKey:@"type"], (@[ @"Edm.String", @"Zoo.Diet", @"Zoo.Keeper" ]));
  XCTAssertEqualObjects(schema.operationImports[@"AdmitAnimal"].entitySet, @"Animals");
  ODataSchemaOperation *move = [schema operationNamed:@"Zoo.Move" boundToEntityType:lion collection:NO parameterNames:nil];
  XCTAssertEqualObjects(move.bindingParameter.name, @"animal");
}

- (void)testABoundFunctionIsAnInstanceMethod
{
  NSManagedObject *zebra = [self fetchOne:@"Animal" where:@"name == 'Zebra'"];
  NSError *error = nil;
  id age = [zebra invokeODataOperation:@"Age" parameters:@{ @"on": ODataDateFromString(@"2024-01-01") } error:&error];
  XCTAssertEqualObjects(age, @8, @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"op-age.json"]);
}

- (void)testAFunctionBoundToACollectionIsAClassMethod
{
  NSError *error = nil;
  NSManagedObject *heaviest = [[ODataOperationCall callOfOperation:@"Heaviest" onEntity:@"Animal" inContext:_context] invoke:&error];
  XCTAssertEqualObjects(heaviest.entity.name, @"Lion", @"%@", error);
  XCTAssertEqualObjects([heaviest valueForKey:@"name"], @"Leo");
}

- (void)testACollectionParameterGoesByAliasAndResultsArePaged
{
  NSManagedObject *ann = [self fetchOne:@"Keeper" where:@"code == 'K1'"];
  NSError *error = nil;
  NSArray *animals = [ann invokeODataOperation:@"AnimalsIn" parameters:@{ @"Zones": @[ @"Savanna", @"Pride Rock" ] } error:&error];
  XCTAssertEqualObjects([animals valueForKey:@"name"], (@[ @"Zebra", @"Leo" ]), @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"op-animals-in-2.json"]);
}

- (void)testAnImportedFunctionIsAFunctionOfTheService
{
  ODataOperationCall *call = [ODataOperationCall callOfOperation:@"CountByDiet" inContext:_context];
  call.parameters = @{ @"Diet": @"Herbivore" };
  NSError *error = nil;
  XCTAssertEqualObjects([call invoke:&error], @2, @"%@", error);
  XCTAssertEqualObjects(call.operation.qualifiedName, @"Zoo.CountByDiet");
}

- (void)testABoundActionTakesAndReturnsAComplexValue
{
  NSManagedObject *zebra = [self fetchOne:@"Animal" where:@"name == 'Zebra'"];
  NSDictionary *to = @{ @"Zone": @"Savanna North", @"Opened": ODataDateFromString(@"2024-02-01"),
                        @"Area": [NSDecimalNumber decimalNumberWithString:@"900"] };
  NSError *error = nil;
  NSDictionary *home = [zebra invokeODataOperation:@"Move" parameters:@{ @"To": to } error:&error];
  XCTAssertEqualObjects(home, to, @"%@", error);
}

- (void)testAnImportedActionCreatesAnObject
{
  NSManagedObject *ann = [self fetchOne:@"Keeper" where:@"code == 'K1'"];
  ODataOperationCall *call = [ODataOperationCall callOfOperation:@"AdmitAnimal" inContext:_context];
  call.parameters = @{ @"Name": @"Kovu", @"Diet": @"Carnivore", @"Keeper": ann };
  NSError *error = nil;
  NSManagedObject *kovu = [call invoke:&error];
  XCTAssertNotNil(kovu, @"%@", error);
  XCTAssertFalse(kovu.objectID.isTemporaryID, @"already saved");
  NSUInteger before = _transport.hits.count;
  XCTAssertEqualObjects(kovu.entity.name, @"Lion");
  XCTAssertEqualObjects([kovu valueForKey:@"name"], @"Kovu");
  XCTAssertEqual(_transport.hits.count, before, @"its row was kept");
}

- (void)callFinished:(ODataOperationCall *)call
{
  _finished = call;
}

- (void)testAnActionCanBeCalledWithoutWaiting
{
  NSManagedObject *leo = [self fetchOne:@"Animal" where:@"name == 'Leo'"];
  [[ODataOperationCall callOfOperation:@"Feed" onObject:leo] invokeWithTarget:self action:@selector(callFinished:)];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
  while (!_finished && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  XCTAssertNotNil(_finished, @"the action is sent");
  XCTAssertNil(_finished.error);
  XCTAssertEqualObjects(_finished.result, [NSNull null], @"nothing returned");
  XCTAssertTrue([_transport.hits containsObject:@"op-feed.json"]);
}

- (void)testWhatTheServiceDoesNotOfferIsAnError
{
  NSManagedObject *zebra = [self fetchOne:@"Animal" where:@"name == 'Zebra'"];
  NSError *error = nil;
  id result = [zebra invokeODataOperation:@"Roar" parameters:nil error:&error];
  XCTAssertNil(result);
  XCTAssertTrue([error.localizedDescription rangeOfString:@"No operation Roar bound to Zoo.Animal"].location != NSNotFound, @"%@", error);
  error = nil;
  result = [zebra invokeODataOperation:@"Age" parameters:@{ @"When": @1 } error:&error];
  XCTAssertNil(result);
  XCTAssertTrue([error.localizedDescription rangeOfString:@"no parameter When"].location != NSNotFound, @"%@", error);
  error = nil;
  result = [[ODataOperationCall callOfOperation:@"Heaviest" onEntity:@"Keeper" inContext:_context] invoke:&error];
  XCTAssertNil(result);
  XCTAssertNotNil(error, @"bound to animals, not keepers");
}

#pragma mark - Functions in $filter and $orderby

- (NSArray *)fetch:(NSString *)entity predicate:(NSPredicate *)predicate sort:(NSArray *)sort error:(NSError **)error
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.predicate = predicate;
  fetch.sortDescriptors = sort;
  return [_context executeFetchRequest:fetch error:error];
}

static NSPredicate *OISCompare(NSExpression *left, NSPredicateOperatorType type, id value)
{
  return [NSComparisonPredicate predicateWithLeftExpression:left rightExpression:[NSExpression expressionForConstantValue:value]
                                                   modifier:NSDirectPredicateModifier type:type options:0];
}

- (void)testAFunctionIsFilteredByAsAComputedProperty
{
  NSExpression *age = [ODataFunctionExpression expressionForFunction:@"Age" onKeyPath:nil
                                                          parameters:@{ @"on": ODataDateFromString(@"2024-01-01") } resultKeyPath:nil];
  NSError *error = nil;
  NSArray *old = [self fetch:@"Animal" predicate:OISCompare(age, NSGreaterThanPredicateOperatorType, @5) sort:nil error:&error];
  XCTAssertEqual(old.count, (NSUInteger)2, @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"fn-filter-age.json"]);
}

- (void)testAPathGoesOnIntoAFunctionsResult
{
  NSExpression *caretaker = [ODataFunctionExpression expressionForFunction:@"Caretaker" onKeyPath:nil parameters:nil resultKeyPath:@"name"];
  NSExpression *opened = [ODataFunctionExpression expressionForFunction:@"CurrentHome" onKeyPath:nil parameters:nil resultKeyPath:@"opened"];
  NSPredicate *both = [NSCompoundPredicate andPredicateWithSubpredicates:@[
    OISCompare(caretaker, NSEqualToPredicateOperatorType, @"Ann"),
    OISCompare(opened, NSLessThanPredicateOperatorType, ODataDateFromString(@"2016-01-01")) ]];
  NSError *error = nil;
  NSArray *found = [self fetch:@"Animal" predicate:both sort:nil error:&error];
  XCTAssertEqualObjects([found valueForKey:@"name"], @[ @"Zebra" ], @"%@", error);
}

- (void)testAFunctionOfACollectionIsReachedThroughARelationship
{
  NSExpression *heaviest = [ODataFunctionExpression expressionForFunction:@"Heaviest" onKeyPath:@"animals" parameters:nil resultKeyPath:@"name"];
  NSError *error = nil;
  NSArray *keepers = [self fetch:@"Keeper" predicate:OISCompare(heaviest, NSEqualToPredicateOperatorType, @"Leo") sort:nil error:&error];
  XCTAssertEqual(keepers.count, (NSUInteger)1, @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"fn-filter-collection.json"]);
}

- (void)testAFunctionIsSortedBy
{
  NSExpression *age = [ODataFunctionExpression expressionForFunction:@"Age" onKeyPath:nil
                                                          parameters:@{ @"On": ODataDateFromString(@"2024-01-01") } resultKeyPath:nil];
  NSError *error = nil;
  NSArray *sorted = [self fetch:@"Animal" predicate:nil sort:@[ [ODataSortDescriptor sortDescriptorWithExpression:age ascending:NO] ] error:&error];
  XCTAssertEqualObjects([sorted valueForKey:@"name"], (@[ @"Leo", @"Zebra", @"Okapi" ]), @"%@", error);
}

- (void)testAFunctionEvaluatedInMemoryCallsTheService
{
  NSManagedObject *zebra = [self fetchOne:@"Animal" where:@"name == 'Zebra'"];
  NSExpression *age = [ODataFunctionExpression expressionForFunction:@"Age" onKeyPath:nil
                                                          parameters:@{ @"On": ODataDateFromString(@"2024-01-01") } resultKeyPath:nil];
  XCTAssertTrue([OISCompare(age, NSEqualToPredicateOperatorType, @8) evaluateWithObject:zebra]);
  XCTAssertTrue([_transport.hits containsObject:@"op-age.json"]);
}

- (void)testWhatIsNoFunctionIsAnError
{
  NSExpression *move = [ODataFunctionExpression expressionForFunction:@"Move" onKeyPath:nil parameters:nil resultKeyPath:nil];
  NSError *error = nil;
  NSArray *rows = [self fetch:@"Animal" predicate:OISCompare(move, NSEqualToPredicateOperatorType, @1) sort:nil error:&error];
  XCTAssertNil(rows);
  XCTAssertTrue([error.localizedDescription rangeOfString:@"Move is no function bound to Zoo.Animal"].location != NSNotFound, @"%@", error);
}

@end
