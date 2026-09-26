// $metadata, and what the store makes of it.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OASIS OData CSDL XML 4.0; OData 4.01 Part 2 section 4.11 (derived types),
// JSON Format section 4.5.3 (@odata.type). Snapshots/Zoo is a small service
// with an alias, enumerations, a derived type, a key no naming rule
// guesses and an entity set that is not a plural. Its Core Data model,
// built below, says nothing about OData at all: no userInfo anywhere.

#import <XCTest/XCTest.h>
#import "OISCatalogModel.h"
#import "ODataSnapshotTransport.h"

static NSAttributeDescription *OISAttribute(NSString *name, NSAttributeType type)
{
  NSAttributeDescription *attr = [[NSAttributeDescription alloc] init];
  attr.name = name;
  attr.attributeType = type;
  attr.optional = YES;
  return attr;
}

static NSManagedObjectModel *OISZooModel(NSArray *extraAnimalAttributes)
{
  NSEntityDescription *animal = [[NSEntityDescription alloc] init];
  animal.name = @"Animal";
  animal.managedObjectClassName = @"NSManagedObject";
  NSEntityDescription *lion = [[NSEntityDescription alloc] init];
  lion.name = @"Lion";
  lion.managedObjectClassName = @"NSManagedObject";
  NSEntityDescription *keeper = [[NSEntityDescription alloc] init];
  keeper.name = @"Keeper";
  keeper.managedObjectClassName = @"NSManagedObject";

  NSRelationshipDescription *keeperOf = [[NSRelationshipDescription alloc] init];
  keeperOf.name = @"keeper";
  keeperOf.destinationEntity = keeper;
  keeperOf.minCount = 0;
  keeperOf.maxCount = 1;
  keeperOf.optional = YES;
  NSRelationshipDescription *animals = [[NSRelationshipDescription alloc] init];
  animals.name = @"animals";
  animals.destinationEntity = animal;
  animals.minCount = 0;
  animals.maxCount = 0;
  animals.optional = YES;
  keeperOf.inverseRelationship = animals;
  animals.inverseRelationship = keeperOf;

  NSMutableArray *animalProperties = [@[ OISAttribute(@"id", NSInteger32AttributeType), OISAttribute(@"name", NSStringAttributeType),
                                         OISAttribute(@"diet", NSStringAttributeType), OISAttribute(@"features", NSInteger32AttributeType),
                                         OISAttribute(@"born", NSDateAttributeType), OISAttribute(@"home", NSTransformableAttributeType),
                                         OISAttribute(@"nicknames", NSTransformableAttributeType),
                                         OISAttribute(@"pastHomes", NSTransformableAttributeType), keeperOf ] mutableCopy];
  [animalProperties addObjectsFromArray:extraAnimalAttributes ?: @[]];
  animal.properties = animalProperties;
  lion.properties = @[ OISAttribute(@"maxRoar", NSInteger32AttributeType) ];
  keeper.properties = @[ OISAttribute(@"code", NSStringAttributeType), OISAttribute(@"name", NSStringAttributeType), animals ];
  animal.subentities = @[ lion ];

  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  model.entities = @[ animal, lion, keeper ];
  return model;
}

@interface ODataSchemaTests : XCTestCase
@end

@implementation ODataSchemaTests {
  ODataSnapshotTransport *_transport;
  ODataIncrementalStore *_store;
  NSManagedObjectContext *_context;
}

- (NSURL *)zooRoot
{
  return [NSURL URLWithString:@"https://zoo.test/Zoo.svc/"];
}

- (ODataIncrementalStore *)openZoo:(NSManagedObjectModel *)model options:(NSDictionary *)options error:(NSError **)error
{
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSMutableDictionary *all = [@{ ODataIncrementalStoreTransportOption: _transport } mutableCopy];
  [all addEntriesFromDictionary:options ?: @{}];
  ODataIncrementalStore *store = (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                                             configuration:nil URL:[self zooRoot]
                                                                                   options:all error:error];
  if (store) {
    _context = [[NSManagedObjectContext alloc] init];
    _context.persistentStoreCoordinator = psc;
  }
  return store;
}

- (void)setUp
{
  [super setUp];
  [ODataIncrementalStore registerStore];
  NSError *error = nil;
  _transport = [[ODataSnapshotTransport alloc] initWithDirectory:[OISSnapshotDirectory() stringByAppendingPathComponent:@"Zoo"]
                                                     serviceRoot:[self zooRoot] error:&error];
  XCTAssertNotNil(_transport, @"%@", error);
  _store = [self openZoo:OISZooModel(nil) options:nil error:&error];
  XCTAssertNotNil(_store, @"%@", error);
}

- (void)tearDown
{
  XCTAssertEqualObjects(_transport.refusals, @[]);
  [super tearDown];
}

- (NSArray *)fetch:(NSString *)entity where:(NSPredicate *)predicate
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
  fetch.predicate = predicate;
  fetch.sortDescriptors = nil;
  NSError *error = nil;
  NSArray *rows = [_context executeFetchRequest:fetch error:&error];
  XCTAssertNotNil(rows, @"%@", error);
  return rows;
}

#pragma mark - Reading CSDL

- (void)testReadsTypesKeysSetsAndEnumerations
{
  ODataSchema *schema = _store.schema;
  XCTAssertNotNil(schema);
  ODataSchemaEntityType *lion = [schema entityTypeNamed:@"Self.Lion"];
  XCTAssertEqualObjects(lion.qualifiedName, @"Zoo.Lion");
  XCTAssertEqualObjects(lion.baseType, @"Zoo.Animal", @"the alias resolves");
  XCTAssertEqualObjects([schema keyOfEntityType:lion], @[ @"Id" ], @"a derived type has its base's key");
  XCTAssertEqualObjects([schema property:@"Name" ofEntityType:lion].type, @"Edm.String");
  XCTAssertEqualObjects([schema property:@"Diet" ofEntityType:lion].type, @"Zoo.Diet");
  XCTAssertEqualObjects([schema entitySetForEntityType:lion], @"Animals");
  XCTAssertEqualObjects(schema.entitySets[@"Staff"], @"Zoo.Keeper");
  ODataSchemaNavigationProperty *animals = [schema navigationProperty:@"Animals" ofEntityType:[schema entityTypeNamed:@"Zoo.Keeper"]];
  XCTAssertTrue(animals.isCollection);
  XCTAssertEqualObjects(animals.type, @"Zoo.Animal");
  ODataSchemaEnumType *features = [schema enumTypeNamed:@"Zoo.Features"];
  XCTAssertTrue(features.isFlags);
  XCTAssertEqualObjects(features.values[@"Mane"], @4);
  XCTAssertNil([schema entityTypeNamed:@"Zoo.Enclosure"], @"a complex type is not an entity type");
}

- (void)testReadsComplexTypesCollectionsAndTypeDefinitions
{
  ODataSchema *schema = _store.schema;
  ODataSchemaComplexType *aviary = [schema complexTypeNamed:@"Self.Aviary"];
  XCTAssertEqualObjects(aviary.baseType, @"Zoo.Enclosure");
  XCTAssertEqualObjects([schema property:@"Zone" ofComplexType:aviary].type, @"Edm.String", @"inherited");
  XCTAssertEqualObjects([schema property:@"Area" ofComplexType:aviary].type, @"Edm.Decimal", @"a type definition is its underlying type");
  XCTAssertEqual([schema propertiesOfComplexType:aviary].count, (NSUInteger)4);
  ODataSchemaEntityType *animal = [schema entityTypeNamed:@"Zoo.Animal"];
  ODataSchemaProperty *pastHomes = [schema property:@"PastHomes" ofEntityType:animal];
  XCTAssertTrue(pastHomes.isCollection);
  XCTAssertEqualObjects(pastHomes.type, @"Collection(Zoo.Enclosure)", @"the alias resolves inside Collection()");
  XCTAssertEqualObjects(pastHomes.elementType, @"Zoo.Enclosure");
}

- (void)testKeyAsSegmentSupportIsReadFromTheContainer
{
  XCTAssertFalse(_store.schema.keyAsSegmentSupported);
  NSString *xml = @"<edmx:Edmx Version=\"4.0\" xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\">"
                  @"<edmx:Reference Uri=\"https://oasis-tcs.github.io/odata-vocabularies/vocabularies/Org.OData.Capabilities.V1.xml\">"
                  @"<edmx:Include Namespace=\"Org.OData.Capabilities.V1\" Alias=\"Capabilities\"/></edmx:Reference>"
                  @"<edmx:DataServices><Schema Namespace=\"S\" xmlns=\"http://docs.oasis-open.org/odata/ns/edm\">"
                  @"<EntityType Name=\"T\"><Key><PropertyRef Name=\"Id\"/></Key><Property Name=\"Id\" Type=\"Edm.Int32\"/></EntityType>"
                  @"<EntityContainer Name=\"C\"><EntitySet Name=\"Ts\" EntityType=\"S.T\"/>"
                  @"<Annotation Term=\"Capabilities.KeyAsSegmentSupported\"/></EntityContainer></Schema></edmx:DataServices></edmx:Edmx>";
  ODataSchema *schema = [ODataSchema schemaWithData:[xml dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
  XCTAssertTrue(schema.keyAsSegmentSupported);
  NSString *off = [xml stringByReplacingOccurrencesOfString:@"KeyAsSegmentSupported\"/>" withString:@"KeyAsSegmentSupported\" Bool=\"false\"/>"];
  XCTAssertFalse([ODataSchema schemaWithData:[off dataUsingEncoding:NSUTF8StringEncoding] error:NULL].keyAsSegmentSupported);
}

- (void)testKeyAsSegmentAddressesEntitiesByKeySegments
{
  NSError *error = nil;
  ODataIncrementalStore *store = [self openZoo:OISZooModel(nil) options:@{ ODataIncrementalStoreKeyAsSegmentOption: @YES } error:&error];
  XCTAssertNotNil(store, @"%@", error);
  NSManagedObject *zebra = [self animalNamed:@"Zebra" in:[self fetch:@"Animal" where:nil]];
  [zebra setValue:@"Zed" forKey:@"name"];
  XCTAssertTrue([_context save:&error], @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"zebra-rename-segment.json"]);
}

- (void)testUnreadableMetadataIsNoSchema
{
  NSError *error = nil;
  XCTAssertNil([ODataSchema schemaWithData:[@"<html>not metadata</html>" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
  XCTAssertNotNil(error);
}

#pragma mark - What the model leaves unsaid

- (void)testKeysSetsAndTypesComeFromTheSchema
{
  NSEntityDescription *keeper = _context.persistentStoreCoordinator.managedObjectModel.entitiesByName[@"Keeper"];
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = _store.schema;
  XCTAssertEqualObjects([[mapper keyAttributesForEntity:keeper] valueForKey:@"name"], @[ @"code" ]);
  XCTAssertEqualObjects([mapper entitySetForEntity:keeper], @"Staff");
  NSEntityDescription *animal = _context.persistentStoreCoordinator.managedObjectModel.entitiesByName[@"Animal"];
  XCTAssertEqual([mapper.values edmTypeOfAttribute:animal.attributesByName[@"born"]], ODataEdmDate);
  XCTAssertEqual([mapper.values edmTypeOfAttribute:animal.attributesByName[@"diet"]], ODataEdmEnum);
  XCTAssertEqualObjects(_store.metadataProblems, @[]);

  NSArray *staff = [self fetch:@"Keeper" where:nil];
  XCTAssertEqual(staff.count, (NSUInteger)1);
  XCTAssertEqualObjects([staff.firstObject valueForKey:@"name"], @"Ann");
}

- (void)testRowsOfADerivedTypeAreObjectsOfTheSubentity
{
  NSArray *animals = [self fetch:@"Animal" where:nil];
  XCTAssertEqual(animals.count, (NSUInteger)3);
  NSManagedObject *leo = nil, *okapi = nil;
  for (NSManagedObject *animal in animals) {
    if ([[animal valueForKey:@"name"] isEqual:@"Leo"]) leo = animal;
    if ([[animal valueForKey:@"name"] isEqual:@"Okapi"]) okapi = animal;
  }
  XCTAssertEqualObjects(leo.entity.name, @"Lion");
  XCTAssertEqualObjects([leo valueForKey:@"maxRoar"], @114);
  XCTAssertEqualObjects([leo valueForKey:@"diet"], @"Carnivore", @"an enumeration on a String attribute is its member name");
  XCTAssertEqualObjects([leo valueForKey:@"features"], @4, @"on an integer attribute, its value");
  XCTAssertEqualObjects([okapi valueForKey:@"features"], @3, @"flags: Stripes, Spots");
  XCTAssertEqualObjects(ODataDateString([leo valueForKey:@"born"]), @"2018-02-11", @"an Edm.Date, known from the schema");
  XCTAssertEqualObjects([[leo valueForKey:@"keeper"] valueForKey:@"code"] ?: @"", @"K1");
  XCTAssertNil([okapi valueForKey:@"keeper"]);
}

- (void)testFetchingASubentityCastsTheType
{
  NSArray *lions = [self fetch:@"Lion" where:nil];
  XCTAssertEqual(lions.count, (NSUInteger)2, @"two pages, the second from a 4.01 @nextLink");
  XCTAssertTrue([_transport.hits containsObject:@"lions.json"]);
  XCTAssertTrue([_transport.hits containsObject:@"lions-2.json"]);
  for (NSManagedObject *lion in lions) XCTAssertEqualObjects(lion.entity.name, @"Lion");
}

- (void)testEnumerationLiteralsAreQualified
{
  NSArray *carnivores = [self fetch:@"Animal" where:[NSPredicate predicateWithFormat:@"diet == %@", @"Carnivore"]];
  XCTAssertEqual(carnivores.count, (NSUInteger)1);
  NSArray *manes = [self fetch:@"Animal" where:[NSPredicate predicateWithFormat:@"features == 4"]];
  XCTAssertEqual(manes.count, (NSUInteger)1);
  XCTAssertTrue([_transport.hits containsObject:@"carnivores.json"]);
  XCTAssertTrue([_transport.hits containsObject:@"manes.json"]);
}

- (void)testANewObjectOfADerivedTypeSaysSo
{
  NSManagedObject *nala = [NSEntityDescription insertNewObjectForEntityForName:@"Lion" inManagedObjectContext:_context];
  [nala setValue:@"Nala" forKey:@"name"];
  [nala setValue:@"Carnivore" forKey:@"diet"];
  [nala setValue:@2 forKey:@"features"];
  [nala setValue:ODataDateFromString(@"2021-06-01") forKey:@"born"];
  [nala setValue:@100 forKey:@"maxRoar"];
  NSError *error = nil;
  XCTAssertTrue([_context save:&error], @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"lion-create.json"]);
  XCTAssertEqualObjects(nala.entity.name, @"Lion");
}

#pragma mark - Complex values and collections

- (NSManagedObject *)animalNamed:(NSString *)name in:(NSArray *)animals
{
  for (NSManagedObject *animal in animals) {
    if ([[animal valueForKey:@"name"] isEqual:name]) return animal;
  }
  return nil;
}

- (void)testComplexValuesAndCollectionsAreDictionariesAndArrays
{
  NSArray *animals = [self fetch:@"Animal" where:nil];
  NSDictionary *home = [[self animalNamed:@"Zebra" in:animals] valueForKey:@"home"];
  XCTAssertTrue([home isKindOfClass:[NSDictionary class]]);
  XCTAssertEqualObjects(home[@"Zone"], @"Savanna");
  XCTAssertEqualObjects(ODataDateString(home[@"Opened"]), @"2015-03-01", @"members are read by their types");
  XCTAssertEqualObjects(home[@"Area"], [NSDecimalNumber decimalNumberWithString:@"1200.5"]);
  XCTAssertTrue([home[@"Area"] isKindOfClass:[NSDecimalNumber class]]);
  XCTAssertEqualObjects([[self animalNamed:@"Zebra" in:animals] valueForKey:@"nicknames"], @[ @"Stripes" ]);

  NSManagedObject *leo = [self animalNamed:@"Leo" in:animals];
  XCTAssertEqualObjects([leo valueForKey:@"nicknames"], (@[ @"King", @"Simba" ]));
  NSArray *pastHomes = [leo valueForKey:@"pastHomes"];
  XCTAssertEqual(pastHomes.count, (NSUInteger)1);
  XCTAssertEqualObjects(ODataDateString(pastHomes.firstObject[@"Opened"]), @"2018-03-01");

  NSManagedObject *okapi = [self animalNamed:@"Okapi" in:animals];
  NSDictionary *aviary = [okapi valueForKey:@"home"];
  XCTAssertEqualObjects(aviary[@"@odata.type"], @"#Zoo.Aviary", @"a derived complex value keeps its type");
  XCTAssertEqualObjects(aviary[@"Height"], @12.5, @"and its own members");
  XCTAssertEqualObjects(aviary[@"Opened"], [NSNull null], @"null members stay");
  XCTAssertEqualObjects([okapi valueForKey:@"nicknames"], @[]);
  XCTAssertNil([okapi valueForKey:@"pastHomes"]);
}

- (void)testPredicatesReachIntoComplexValuesAndCollections
{
  NSPredicate *predicate = [NSPredicate predicateWithFormat:@"home.zone == %@ AND ANY nicknames == %@ AND ANY pastHomes.opened < %@",
                                                            @"Pride Rock", @"King", ODataDateFromString(@"2018-06-01")];
  NSArray *animals = [self fetch:@"Animal" where:predicate];
  XCTAssertEqual(animals.count, (NSUInteger)1);
  XCTAssertTrue([_transport.hits containsObject:@"animals-structured-filter.json"]);
}

- (void)testAChangedComplexValueIsWrittenWhole
{
  NSManagedObject *zebra = [self animalNamed:@"Zebra" in:[self fetch:@"Animal" where:nil]];
  NSMutableDictionary *home = [[zebra valueForKey:@"home"] mutableCopy];
  home[@"Zone"] = @"Savanna North";
  home[@"Area"] = [NSDecimalNumber decimalNumberWithString:@"1250"];
  [zebra setValue:home forKey:@"home"];
  [zebra setValue:@[ @"Stripes", @"Zed" ] forKey:@"nicknames"];
  NSError *error = nil;
  XCTAssertTrue([_context save:&error], @"%@", error);
  XCTAssertTrue([_transport.hits containsObject:@"zebra-rehome.json"]);
}

#pragma mark - A model that does not match

- (void)testMismatchesAreReported
{
  NSError *error = nil;
  NSAttributeDescription *wingspan = OISAttribute(@"wingspan", NSDoubleAttributeType);
  ODataIncrementalStore *store = [self openZoo:OISZooModel(@[ wingspan ]) options:nil error:&error];
  XCTAssertNotNil(store, @"%@", error);
  // Once, on Animal, though Lion inherits it.
  XCTAssertEqual(store.metadataProblems.count, (NSUInteger)1, @"%@", store.metadataProblems);
  XCTAssertTrue([store.metadataProblems.firstObject rangeOfString:@"Animal.wingspan"].location != NSNotFound, @"%@", store.metadataProblems);
}

- (void)testRequireMatchingModelFailsTheOpen
{
  NSError *error = nil;
  ODataIncrementalStore *store = [self openZoo:OISZooModel(@[ OISAttribute(@"wingspan", NSDoubleAttributeType) ])
                                       options:@{ ODataIncrementalStoreRequireMatchingModelOption: @YES } error:&error];
  XCTAssertNil(store);
  NSError *cause = error.userInfo[NSUnderlyingErrorKey] ?: error;
  XCTAssertTrue([cause.localizedDescription rangeOfString:@"wingspan"].location != NSNotFound, @"%@", error);
}

@end
