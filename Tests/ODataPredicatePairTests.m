// The client's ODataPredicateTranslator and the server's
// ODataPredicateBuilder, each against the other, over the same rows.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Both ways:
//   - what a client fetches: predicate -> $filter -> predicate, the two
//     predicates selecting the same rows;
//   - what a service reads: $filter -> predicate -> $filter -> predicate,
//     the same.
// Rows, not text: tolower(Name) eq 'chai' comes back as name ==[c] 'chai',
// and writes back as tolower(ProductName) eq 'chai', and all of them are
// the same question. Each case runs over an in-memory store and SQLite,
// and writes both OData 4.0 and 4.01; the rows it should select are the
// in-memory store's for the predicate it starts from (Apple's SQLite store
// does not take ALL).
//
// A $filter the service reads and the client cannot write is listed, with
// why (and "4.0: " before the why for one it cannot write in 4.0 only): the
// test checks that the client refuses it cleanly, and fails when it no
// longer does, so the list stays true.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"

static NSAttributeDescription *OISPairAttribute(NSString *name, NSAttributeType type)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = ![name isEqualToString:@"id"];
  return attribute;
}

// Employees, managers among them, each with a manager and reports. One
// model, so that its entities are the same in every store's predicates.
static NSManagedObjectModel *OISMakeStaffModel(void);
static NSManagedObjectModel *OISStaffModel(void)
{
  static NSManagedObjectModel *model;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    model = OISMakeStaffModel();
  });
  return model;
}

static NSManagedObjectModel *OISMakeStaffModel(void)
{
  NSEntityDescription *employee = [[NSEntityDescription alloc] init];
  employee.name = @"Employee";
  employee.managedObjectClassName = @"NSManagedObject";
  employee.userInfo = @{ @"OData.type": @"Default.Employee", @"OData.entitySet": @"Employees" };
  NSEntityDescription *manager = [[NSEntityDescription alloc] init];
  manager.name = @"Manager";
  manager.managedObjectClassName = @"NSManagedObject";
  manager.userInfo = @{ @"OData.type": @"Default.Manager" };
  NSAttributeDescription *identifier = OISPairAttribute(@"id", NSInteger32AttributeType);
  identifier.userInfo = @{ @"OData.key": @"YES" };
  NSRelationshipDescription *boss = [[NSRelationshipDescription alloc] init];
  boss.name = @"manager";
  boss.destinationEntity = employee;
  boss.maxCount = 1;
  boss.optional = YES;
  NSRelationshipDescription *reports = [[NSRelationshipDescription alloc] init];
  reports.name = @"reports";
  reports.destinationEntity = employee;
  reports.optional = YES;
  boss.inverseRelationship = reports;
  reports.inverseRelationship = boss;
  employee.properties = @[ identifier, OISPairAttribute(@"name", NSStringAttributeType), OISPairAttribute(@"hired", NSDateAttributeType), boss, reports ];
  manager.properties = @[ OISPairAttribute(@"budget", NSDecimalAttributeType) ];
  employee.subentities = @[ manager ];
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ employee, manager ];
  return model;
}

@interface ODataPredicatePairTests : XCTestCase
@end

@implementation ODataPredicatePairTests {
  ODataPropertyMapper *_mapper;
  NSMutableArray<NSURL *> *_files;
}

- (void)setUp
{
  [super setUp];
  _mapper = [[ODataPropertyMapper alloc] init];
  _files = [NSMutableArray array];
}

- (void)tearDown
{
  for (NSURL *url in _files) {
    for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
      [[NSFileManager defaultManager] removeItemAtPath:[url.path stringByAppendingString:suffix] error:NULL];
    }
  }
  [super tearDown];
}

#pragma mark Rows

- (NSManagedObjectContext *)contextForModel:(NSManagedObjectModel *)model storeType:(NSString *)storeType
{
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSURL *url = nil;
  if (![storeType isEqualToString:NSInMemoryStoreType]) {
    url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[[NSProcessInfo processInfo] globallyUniqueString]]];
    [_files addObject:url];
  }
  NSError *error = nil;
  XCTAssertNotNil([coordinator addPersistentStoreWithType:storeType configuration:nil URL:url options:nil error:&error], @"%@", error);
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = coordinator;
  return context;
}

- (NSManagedObject *)insert:(NSString *)entity into:(NSManagedObjectContext *)context values:(NSDictionary *)values
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];
  for (NSString *key in values) {
    id value = values[key];
    if ([value isKindOfClass:[NSArray class]]) {
      [[object mutableSetValueForKey:key] addObjectsFromArray:value];
    } else if (value != [NSNull null]) {
      [object setValue:value forKey:key];
    }
  }
  return object;
}

// Products with nulls, mixed case, no category, several suppliers or none.
- (NSManagedObjectContext *)catalogIn:(NSString *)storeType
{
  NSManagedObjectContext *context = [self contextForModel:OISCatalogModel() storeType:storeType];
  NSManagedObject *beverages = [self insert:@"Category" into:context values:@{ @"id": @1, @"name": @"Beverages" }];
  NSManagedObject *condiments = [self insert:@"Category" into:context values:@{ @"id": @2, @"name": @"Condiments" }];
  [self insert:@"Category" into:context values:@{ @"id": @3, @"name": @"Produce" }];
  NSManagedObject *exotic = [self insert:@"Supplier" into:context values:@{ @"id": @1, @"companyName": @"Exotic Liquids", @"city": @"London", @"country": @"UK" }];
  NSManagedObject *cajun = [self insert:@"Supplier" into:context values:@{ @"id": @2, @"companyName": @"New Orleans Cajun Delights", @"city": @"New Orleans", @"country": @"USA" }];
  NSManagedObject *tokyo = [self insert:@"Supplier" into:context values:@{ @"id": @3, @"companyName": @"Tokyo Traders", @"city": @"Tokyo", @"country": @"Japan" }];
  NSArray *rows = @[
    @[ @1, @"Chai", @"18", @NO, beverages, @[ exotic ], @"10 boxes x 20 bags" ],
    @[ @2, @"Chang", @"19", @NO, beverages, @[ exotic ], @"24 - 12 oz bottles" ],
    @[ @3, @"Aniseed Syrup", @"10", @NO, condiments, @[ exotic ], [NSNull null] ],
    @[ @4, @"Chef Anton's Cajun Seasoning", @"22", @NO, condiments, @[ cajun ], @"48 - 6 oz jars" ],
    @[ @5, @"Chef Anton's Gumbo Mix", @"21.35", @YES, condiments, @[ cajun ], [NSNull null] ],
    @[ @6, @"Ikura", @"31", @NO, [NSNull null], @[ tokyo, exotic ], @"12 - 200 ml jars" ],
    @[ @7, @"chai latte", @"4.5", [NSNull null], beverages, @[], [NSNull null] ],
    @[ @8, @"Mystery", [NSNull null], @YES, [NSNull null], @[], [NSNull null] ],
  ];
  for (NSArray *row in rows) {
    [self insert:@"Product" into:context values:@{
      @"id": row[0], @"name": row[1],
      @"unitPrice": row[2] == [NSNull null] ? row[2] : [NSDecimalNumber decimalNumberWithString:row[2]],
      @"discontinued": row[3], @"category": row[4], @"suppliers": row[5], @"quantityPerUnit": row[6] }];
  }
  NSError *error = nil;
  XCTAssertTrue([context save:&error], @"%@", error);
  [context reset];
  return context;
}

- (NSManagedObjectContext *)staffIn:(NSString *)storeType
{
  NSManagedObjectContext *context = [self contextForModel:OISStaffModel() storeType:storeType];
  NSManagedObject *ann = [self insert:@"Manager" into:context values:@{ @"id": @1, @"name": @"Ann", @"budget": [NSDecimalNumber decimalNumberWithString:@"5000"],
                                                                        @"hired": ODataDateFromString(@"2019-06-01T09:00:00Z") }];
  NSManagedObject *bob = [self insert:@"Manager" into:context values:@{ @"id": @2, @"name": @"Bob", @"budget": [NSDecimalNumber decimalNumberWithString:@"800"],
                                                                        @"manager": ann, @"hired": ODataDateFromString(@"2024-12-31T23:30:00Z") }];
  [self insert:@"Employee" into:context values:@{ @"id": @3, @"name": @"Cy", @"manager": bob, @"hired": ODataDateFromString(@"2025-01-01T00:00:00Z") }];
  [self insert:@"Employee" into:context values:@{ @"id": @4, @"name": @"Di", @"manager": bob }];
  NSError *error = nil;
  XCTAssertTrue([context save:&error], @"%@", error);
  [context reset];
  return context;
}

- (NSArray *)idsOf:(NSString *)entity where:(NSPredicate *)predicate in:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.predicate = predicate;
  NSError *error = nil;
  NSArray *objects = nil;
  @try {
    objects = [context executeFetchRequest:fetch error:&error];
  } @catch (NSException *exception) {
    return @[ [NSString stringWithFormat:@"raised %@", exception.reason] ];
  }
  if (!objects) return @[ [NSString stringWithFormat:@"failed %@", error] ];
  return [[objects valueForKey:@"id"] sortedArrayUsingSelector:@selector(compare:)];
}

#pragma mark The two sides

- (ODataPredicateBuilder *)builderForModel:(NSManagedObjectModel *)model
{
  ODataPredicateBuilder *builder = [[ODataPredicateBuilder alloc] initWithMapper:_mapper];
  NSMutableDictionary *types = [NSMutableDictionary dictionary];
  for (NSEntityDescription *entity in model.entities) {
    NSString *name = [_mapper qualifiedTypeForEntity:entity];
    if (name) types[name] = entity;
  }
  builder.entitiesByTypeName = types;
  return builder;
}

- (NSString *)write:(NSPredicate *)predicate entity:(NSEntityDescription *)entity version:(NSString *)version error:(NSError **)error
{
  ODataPredicateTranslator *translator = [[ODataPredicateTranslator alloc] initWithMapper:_mapper entity:entity];
  translator.version = version;
  return [translator translatePredicate:predicate error:error];
}

- (NSPredicate *)read:(NSString *)filter entity:(NSEntityDescription *)entity error:(NSError **)error
{
  ODataExpression *expression = [ODataExpression expressionWithString:filter error:error];
  if (!expression) return nil;
  return [[self builderForModel:entity.managedObjectModel] predicateForExpression:expression entity:entity aliases:nil error:error];
}

// predicate -> $filter -> predicate: the same rows.
- (void)assertClientPredicates:(NSArray *)formats entity:(NSString *)entityName contexts:(NSArray *)contexts
{
  NSManagedObjectContext *reference = contexts.firstObject;
  for (NSManagedObjectContext *context in contexts) {
    NSEntityDescription *entity = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[entityName];
    NSString *store = ((NSPersistentStore *)context.persistentStoreCoordinator.persistentStores.firstObject).type;
    for (id format in formats) {
      @try {
        [self assertClientPredicate:format entity:entity entityName:entityName store:store context:context reference:reference];
      } @catch (NSException *exception) {
        XCTFail(@"%@: %@ raised %@: %@", store, format, exception.name, exception.reason);
      }
    }
  }
}

- (void)assertClientPredicate:(id)format entity:(NSEntityDescription *)entity entityName:(NSString *)entityName store:(NSString *)store
                      context:(NSManagedObjectContext *)context reference:(NSManagedObjectContext *)reference
{
  NSPredicate *predicate = [format isKindOfClass:[NSPredicate class]] ? format : [NSPredicate predicateWithFormat:format];
  NSArray *expected = [self idsOf:entityName where:predicate in:reference];
  for (NSString *version in @[ @"4.0", @"4.01" ]) {
    NSError *error = nil;
    NSString *filter = [self write:predicate entity:entity version:version error:&error];
    if (!filter) {
      XCTFail(@"%@ %@: the client cannot write %@: %@", store, version, format, error);
      continue;
    }
    NSPredicate *read = [self read:filter entity:entity error:&error];
    if (!read) {
      XCTFail(@"%@ %@: the service cannot read %@ (from %@): %@", store, version, filter, format, error);
      continue;
    }
    NSArray *got = [self idsOf:entityName where:read in:context];
    XCTAssertEqualObjects(got, expected, @"%@ %@: %@ -> %@ -> %@", store, version, format, filter, read);
  }
}

// $filter -> predicate -> $filter -> predicate: the same rows. What the
// client cannot write, it refuses, as the list says.
- (void)assertServiceFilters:(NSArray<NSString *> *)filters clientCannotWrite:(NSDictionary<NSString *, NSString *> *)gaps
                      entity:(NSString *)entityName contexts:(NSArray *)contexts
{
  NSManagedObjectContext *reference = contexts.firstObject;
  for (NSManagedObjectContext *context in contexts) {
    NSEntityDescription *entity = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[entityName];
    NSString *store = ((NSPersistentStore *)context.persistentStoreCoordinator.persistentStores.firstObject).type;
    for (NSString *filter in [filters arrayByAddingObjectsFromArray:gaps.allKeys]) {
      NSError *error = nil;
      NSPredicate *read = [self read:filter entity:entity error:&error];
      if (!read) {
        XCTFail(@"%@: the service cannot read %@: %@", store, filter, error);
        continue;
      }
      NSArray *expected = [self idsOf:entityName where:read in:reference];
      XCTAssertEqualObjects([self idsOf:entityName where:read in:context], expected, @"%@: %@ read as %@", store, filter, read);
      for (NSString *version in @[ @"4.0", @"4.01" ]) {
        NSString *written = [self write:read entity:entity version:version error:&error];
        BOOL gap = gaps[filter] && (![gaps[filter] hasPrefix:@"4.0: "] || [version isEqualToString:@"4.0"]);
        if (gap) {
          XCTAssertNil(written, @"%@ %@: the client now writes %@ (%@), which the list says it cannot (%@): take it off the list",
                       store, version, filter, written, gaps[filter]);
          if (!written) XCTAssertNotNil(error, @"%@: a refusal says why", filter);
          continue;
        }
        if (!written) {
          XCTFail(@"%@ %@: the client cannot write %@ (read as %@): %@", store, version, filter, read, error);
          continue;
        }
        NSPredicate *again = [self read:written entity:entity error:&error];
        if (!again) {
          XCTFail(@"%@ %@: the service cannot read what the client wrote, %@ (from %@): %@", store, version, written, filter, error);
          continue;
        }
        XCTAssertEqualObjects([self idsOf:entityName where:again in:context], expected, @"%@ %@: %@ -> %@ -> %@", store, version, filter, read, written);
      }
    }
  }
}

- (NSArray *)catalogs
{
  return @[ [self catalogIn:NSInMemoryStoreType], [self catalogIn:NSSQLiteStoreType] ];
}

- (NSArray *)staffs
{
  return @[ [self staffIn:NSInMemoryStoreType], [self staffIn:NSSQLiteStoreType] ];
}

#pragma mark Cases

- (void)testWhatTheClientWrites
{
  [self assertClientPredicates:@[
    @"unitPrice == 18", @"unitPrice != 18", @"unitPrice > 20", @"unitPrice >= 21.35", @"unitPrice < 10", @"unitPrice <= 10",
    @"discontinued == YES", @"discontinued == NO", @"name == nil", @"unitPrice == nil", @"unitPrice != nil", @"quantityPerUnit == nil",
    @"name == 'Chai'", @"name ==[c] 'chai'", @"name !=[c] 'chai'",
    @"name BEGINSWITH 'Chef'", @"name BEGINSWITH[c] 'chai'", @"name ENDSWITH 'Mix'", @"name CONTAINS 'Anton'", @"name CONTAINS[c] 'CHAI'",
    @"unitPrice > 10 AND discontinued == NO", @"unitPrice < 10 OR unitPrice > 30", @"NOT (unitPrice > 20)",
    @"NOT (name BEGINSWITH 'C') AND (unitPrice >= 10 OR discontinued == YES)",
    @"id IN {1, 3, 5}", @"name IN {'Chai', 'Ikura'}", @"unitPrice BETWEEN {10, 20}",
    @"category.name == 'Beverages'", @"category == nil", @"category != nil", @"category.id == 2",
    @"ANY suppliers.city == 'London'", @"ANY suppliers.country IN {'Japan', 'USA'}",
    @"SUBQUERY(suppliers, $s, $s.city == 'London' AND $s.country == 'UK').@count > 0",
    @"ALL suppliers.country == 'UK'", @"suppliers.@count == 0", @"suppliers.@count > 1",
    @"TRUEPREDICATE", @"FALSEPREDICATE",
  ] entity:@"Product" contexts:[self catalogs]];
}

- (void)testWhatTheServiceReads
{
  [self assertServiceFilters:@[
    @"UnitPrice eq 18", @"UnitPrice gt 20 and Discontinued eq false", @"not (UnitPrice gt 20)", @"UnitPrice eq null",
    @"ProductName eq 'Chai'", @"tolower(ProductName) eq 'chai'", @"toupper(ProductName) eq 'CHAI'",
    @"startswith(ProductName,'Chef')", @"endswith(ProductName,'Mix')", @"contains(ProductName,'Anton')",
    @"contains(tolower(ProductName),'chai')",
    @"ProductID in (1,3,5)", @"UnitPrice add 1 gt 20", @"UnitPrice mul 2 lt 30",
    @"Category/CategoryName eq 'Beverages'", @"Category eq null", @"Category ne null",
    @"Suppliers/any(s:s/City eq 'London')", @"Suppliers/all(s:s/Country eq 'UK')", @"Suppliers/any()",
    @"Suppliers/$count gt 1", @"Suppliers/any(s:s/City eq 'London' and s/Country eq 'UK')",
    @"true", @"false", @"Discontinued",
    // Read as ranges of their argument, written back as those ranges.
    @"floor(UnitPrice) eq 21", @"round(UnitPrice) gt 19", @"ceiling(UnitPrice) le 19",
  ] clientCannotWrite:@{
    @"matchesPattern(ProductName,'^Ch')": @"4.0: matchesPattern is 4.01's",
    @"not matchesPattern(QuantityPerUnit,'jars')": @"4.0: matchesPattern is 4.01's",
    // Read as MATCHES, which the client writes as matchesPattern.
    @"length(ProductName) gt 10": @"4.0: length() is read as a pattern, and 4.0 has no matchesPattern",
    @"length(QuantityPerUnit) le 16": @"4.0: as length(ProductName)",
  } entity:@"Product" contexts:[self catalogs]];
}

- (void)testTypesAndDates
{
  [self assertServiceFilters:@[
    @"Name eq 'Ann'",
    @"Manager/Name eq 'Ann'",
    @"Reports/any(r:r/Name eq 'Cy')",
    @"isof(Default.Manager)", @"not isof(Default.Manager)", @"isof(Manager,Default.Manager)",
    @"Default.Manager/Budget gt 1000", @"Default.Manager/Budget eq null", @"Manager/Default.Manager/Budget lt 1000",
    @"Reports/any(r:isof(r,Default.Manager))", @"Reports/Default.Manager/any(m:m/Budget lt 1000)",
    @"year(Hired) eq 2025", @"year(Hired) ne 2025", @"date(Hired) eq 2024-12-31",
  ] clientCannotWrite:@{} entity:@"Employee" contexts:[self staffs]];
  NSDictionary *entities = OISStaffModel().entitiesByName;
  NSEntityDescription *employee = entities[@"Employee"], *manager = entities[@"Manager"];
  [self assertClientPredicates:@[
    [NSPredicate predicateWithFormat:@"entity == %@", manager],
    [NSPredicate predicateWithFormat:@"entity == %@", employee],
    [NSPredicate predicateWithFormat:@"entity != %@", employee],
    [NSPredicate predicateWithFormat:@"entity IN %@", @[ employee, manager ]],
    [NSPredicate predicateWithFormat:@"manager.entity == %@", manager],
    [NSPredicate predicateWithFormat:@"entity == %@ AND budget > 1000", manager],
    [NSPredicate predicateWithFormat:@"SUBQUERY(reports, $r, $r.entity == %@).@count > 0", manager],
  ] entity:@"Employee" contexts:[self staffs]];
}

@end
