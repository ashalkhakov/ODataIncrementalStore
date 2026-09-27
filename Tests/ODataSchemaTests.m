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
  XCTAssertEqualObjects(_store.schema.version, @"4.0");
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

#pragma mark Annotations

// CSDL section 14: inline and targeted, under a vocabulary's own alias or
// another, with qualifiers, records, collections, paths and a dynamic
// expression.
static NSString * const OISAnnotatedCSDL =
  @"<?xml version=\"1.0\"?>"
  @"<edmx:Edmx xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\" Version=\"4.01\">"
  @"<edmx:Reference Uri=\"https://oasis-tcs.github.io/odata-vocabularies/vocabularies/Org.OData.Core.V1.xml\">"
  @"<edmx:Include Namespace=\"Org.OData.Core.V1\" Alias=\"C\"/></edmx:Reference>"
  @"<edmx:Reference Uri=\"https://oasis-tcs.github.io/odata-vocabularies/vocabularies/Org.OData.Validation.V1.xml\">"
  @"<edmx:Include Namespace=\"Org.OData.Validation.V1\" Alias=\"Validation\"/></edmx:Reference>"
  @"<edmx:DataServices><Schema xmlns=\"http://docs.oasis-open.org/odata/ns/edm\" Namespace=\"Shop\" Alias=\"Self\">"
  @"<EntityType Name=\"Product\">"
  @"<Annotation Term=\"C.Description\" String=\"Something for sale\"/>"
  @"<Key><PropertyRef Name=\"ID\"/></Key>"
  @"<Property Name=\"ID\" Type=\"Edm.Int32\" Nullable=\"false\"><Annotation Term=\"C.Computed\"/></Property>"
  @"<Property Name=\"Name\" Type=\"Edm.String\" MaxLength=\"40\">"
  @"<Annotation Term=\"C.Description\" String=\"The name\"/>"
  @"<Annotation Term=\"C.Description\" Qualifier=\"fr\" String=\"Le nom\"/>"
  @"<Annotation Term=\"Validation.Pattern\" String=\"^[A-Z]\"/>"
  @"<Annotation Term=\"C.Permissions\" EnumMember=\"C.Permission/Read C.Permission/Write\"/>"
  @"</Property>"
  @"<Property Name=\"Price\" Type=\"Edm.Decimal\">"
  @"<Annotation Term=\"Validation.Minimum\" Decimal=\"0\"><Annotation Term=\"Validation.Exclusive\" Bool=\"true\"/></Annotation>"
  @"<Annotation Term=\"Validation.Maximum\"><Decimal>100.5</Decimal></Annotation>"
  @"<Annotation Term=\"C.Description\" Qualifier=\"dyn\"><If><Path>IsNew</Path><String>new</String><String>old</String></If></Annotation>"
  @"</Property>"
  @"</EntityType>"
  @"<EntityType Name=\"Special\" BaseType=\"Self.Product\"/>"
  @"<EnumType Name=\"Colour\"><Member Name=\"Red\" Value=\"1\"><Annotation Term=\"C.Description\" String=\"Warm\"/></Member></EnumType>"
  @"<EntityContainer Name=\"Container\">"
  @"<Annotation Term=\"Org.OData.Capabilities.V1.KeyAsSegmentSupported\"/>"
  @"<EntitySet Name=\"Products\" EntityType=\"Self.Product\"/>"
  @"</EntityContainer>"
  @"<Annotations Target=\"Self.Product/Name\"><Annotation Term=\"C.LongDescription\"><String>Long text</String></Annotation></Annotations>"
  @"<Annotations Target=\"Self.Container/Products\">"
  @"<Annotation Term=\"Org.OData.Capabilities.V1.InsertRestrictions\"><Record>"
  @"<PropertyValue Property=\"Insertable\" Bool=\"false\"/>"
  @"<PropertyValue Property=\"NonInsertableProperties\"><Collection><PropertyPath>ID</PropertyPath><PropertyPath>Name</PropertyPath></Collection></PropertyValue>"
  @"</Record></Annotation>"
  @"</Annotations>"
  @"</Schema></edmx:DataServices></edmx:Edmx>";

- (void)testAnnotations
{
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:[OISAnnotatedCSDL dataUsingEncoding:NSUTF8StringEncoding] error:&error];
  XCTAssertNotNil(schema, @"%@", error);

  XCTAssertEqualObjects([schema annotation:@"Core.Description" forTarget:@"Shop.Product"], @"Something for sale");
  XCTAssertEqualObjects([schema annotation:@"Org.OData.Core.V1.Computed" forTarget:@"Shop.Product/ID"], @YES, @"a tag is true");
  XCTAssertEqualObjects([schema annotation:@"C.Description" forTarget:@"Self.Product/Name"], @"The name", @"the document's alias, both places");
  XCTAssertEqualObjects([schema annotation:@"Core.Description#fr" forTarget:@"Shop.Product/Name"], @"Le nom");
  XCTAssertEqualObjects([schema annotation:@"Validation.Pattern" forTarget:@"Shop.Product/Name"], @"^[A-Z]");
  XCTAssertEqualObjects([schema annotation:@"Core.Permissions" forTarget:@"Shop.Product/Name"], @"Read,Write");
  XCTAssertEqualObjects([schema annotation:@"Core.LongDescription" forTarget:@"Shop.Product/Name"], @"Long text", @"targeted");
  XCTAssertEqualObjects([schema annotation:@"Validation.Minimum" forTarget:@"Shop.Product/Price"], [NSDecimalNumber decimalNumberWithString:@"0"]);
  XCTAssertEqualObjects([schema annotation:@"Validation.Maximum" forTarget:@"Shop.Product/Price"], [NSDecimalNumber decimalNumberWithString:@"100.5"]);
  NSDictionary *dynamic = [schema annotation:@"Core.Description#dyn" forTarget:@"Shop.Product/Price"];
  XCTAssertEqualObjects(dynamic, (@{ @"$If": @[ @{ @"$Path": @"IsNew" }, @"new", @"old" ] }));
  XCTAssertEqualObjects([schema annotation:@"Core.Description" forTarget:@"Shop.Colour/Red"], @"Warm");

  NSDictionary *insert = [schema annotation:@"Capabilities.InsertRestrictions" forTarget:@"Shop.Container/Products"];
  XCTAssertEqualObjects(insert[@"Insertable"], @NO);
  XCTAssertEqualObjects(insert[@"NonInsertableProperties"], (@[ @{ @"$PropertyPath": @"ID" }, @{ @"$PropertyPath": @"Name" } ]));
  XCTAssertTrue(schema.keyAsSegmentSupported, @"read as any other annotation now");

  ODataSchemaEntityType *special = [schema entityTypeNamed:@"Shop.Special"];
  XCTAssertEqualObjects([schema annotation:@"Core.Computed" forProperty:@"ID" ofEntityType:special], @YES, @"through the base type");
  XCTAssertNil([schema annotation:@"Core.Computed" forProperty:@"Name" ofEntityType:special]);
  XCTAssertEqualObjects([schema annotation:@"Validation.Minimum@Validation.Exclusive" forTarget:@"Shop.Product/Price"], @YES,
                        @"an annotation of an annotation, as JSON CSDL keys it");
  XCTAssertEqual([schema annotationsForTarget:@"Shop.Product/Price"].count, 4u);
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"Shop.Product"];
  XCTAssertEqualObjects([schema property:@"Name" ofEntityType:product].maxLength, @40);
  XCTAssertNil([schema property:@"Price" ofEntityType:product].maxLength);
}

- (void)testModelsCarryTheVocabularies
{
  // Core in userInfo, Validation as Core Data's own validation: an object
  // that breaks it fails at -save:, before the service is asked.
  ODataSchema *schema = [ODataSchema schemaWithData:[OISAnnotatedCSDL dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  NSEntityDescription *product = model.entitiesByName[@"Product"];
  XCTAssertEqualObjects(product.userInfo[ODataUserInfoDescription], @"Something for sale");
  NSAttributeDescription *identifier = product.attributesByName[@"id"];
  XCTAssertEqualObjects(identifier.userInfo[ODataUserInfoComputed], @"YES");
  NSAttributeDescription *name = product.attributesByName[@"name"];
  XCTAssertEqualObjects(name.userInfo[ODataUserInfoDescription], @"The name");
  XCTAssertEqualObjects(name.userInfo[ODataUserInfoPermissions], @"Read,Write");
  XCTAssertNotNil(name.userInfo[ODataUserInfoAnnotations], @"every annotation, for the application");
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  XCTAssertTrue([mapper attributeIsComputed:identifier]);
  XCTAssertFalse([mapper attributeIsComputed:name]);

  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  [coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:NULL];
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] init];
  context.persistentStoreCoordinator = coordinator;
  NSManagedObject *item = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:context];
  [item setValue:@1 forKey:@"id"];
  NSError *error = nil;
  NSString *good = @"Anvil";
  XCTAssertTrue([item validateValue:&good forKey:@"name" error:&error], @"%@", error);
  NSString *lowercase = @"anvil";
  XCTAssertFalse([item validateValue:&lowercase forKey:@"name" error:NULL], @"Validation.Pattern ^[A-Z]");
  NSString *longName = [@"A" stringByPaddingToLength:41 withString:@"a" startingAtIndex:0];
  XCTAssertFalse([item validateValue:&longName forKey:@"name" error:NULL], @"MaxLength 40");
  NSDecimalNumber *zero = [NSDecimalNumber zero], *some = [NSDecimalNumber decimalNumberWithString:@"50"];
  NSDecimalNumber *most = [NSDecimalNumber decimalNumberWithString:@"100.5"], *more = [NSDecimalNumber decimalNumberWithString:@"100.6"];
  XCTAssertFalse([item validateValue:&zero forKey:@"price" error:NULL], @"Minimum 0, exclusive");
  XCTAssertTrue([item validateValue:&some forKey:@"price" error:NULL]);
  XCTAssertTrue([item validateValue:&most forKey:@"price" error:NULL], @"Maximum 100.5, inclusive");
  XCTAssertFalse([item validateValue:&more forKey:@"price" error:NULL]);
}

#pragma mark - OData 4.01 (Part 1 section 13.3, items 16-18)

// What 4.01 CSDL adds to 4.0: Edm.Untyped and the abstract Edm types as
// property types, Scale variable and floating, SRID, key aliases for a
// complex key member, a nullable singleton, entity sets left out of the
// service document, an enumeration over Edm.Int64, ContainsTarget with
// OnDelete, action overloads with EntitySetPath, terms of its own, and
// annotations built of UrlRef, LabeledElement and Apply.
static NSString *const OIS401CSDL =
  @"<edmx:Edmx Version=\"4.01\" xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\">"
  @"<edmx:Reference Uri=\"https://oasis-tcs.github.io/odata-vocabularies/vocabularies/Org.OData.Core.V1.xml\">"
  @"<edmx:Include Namespace=\"Org.OData.Core.V1\" Alias=\"Core\"/>"
  @"<edmx:IncludeAnnotations TermNamespace=\"Org.OData.Core.V1\" Qualifier=\"Tablet\"/></edmx:Reference>"
  @"<edmx:DataServices><Schema Namespace=\"Shop\" Alias=\"S\" xmlns=\"http://docs.oasis-open.org/odata/ns/edm\">"
  @"<Term Name=\"Rating\" Type=\"Edm.Int32\" AppliesTo=\"EntityType Property\" Nullable=\"false\" DefaultValue=\"3\"/>"
  @"<TypeDefinition Name=\"Weight\" UnderlyingType=\"Edm.Decimal\" Precision=\"10\" Scale=\"variable\">"
  @"<Annotation Term=\"Core.Description\" String=\"kg\"/></TypeDefinition>"
  @"<EnumType Name=\"Size\" UnderlyingType=\"Edm.Int64\" IsFlags=\"true\">"
  @"<Member Name=\"Small\" Value=\"1\"/><Member Name=\"Large\" Value=\"4294967296\"/></EnumType>"
  @"<ComplexType Name=\"Address\" OpenType=\"true\"><Property Name=\"Zip\" Type=\"Edm.String\" Nullable=\"false\"/>"
  @"<Property Name=\"Where\" Type=\"Edm.GeographyPoint\" SRID=\"variable\"/></ComplexType>"
  @"<EntityType Name=\"Store\"><Key><PropertyRef Name=\"Address/Zip\" Alias=\"Zip\"/></Key>"
  @"<Property Name=\"Address\" Type=\"S.Address\" Nullable=\"false\"/>"
  @"<Property Name=\"Extra\" Type=\"Edm.Untyped\"/>"
  @"<Property Name=\"Anything\" Type=\"Edm.PrimitiveType\"/>"
  @"<Property Name=\"Tags\" Type=\"Collection(Edm.String)\" Nullable=\"true\"/>"
  @"<Property Name=\"Ratio\" Type=\"Edm.Decimal\" Scale=\"floating\" Precision=\"7\"/>"
  @"<Property Name=\"Weight\" Type=\"S.Weight\"/>"
  @"<Property Name=\"Size\" Type=\"S.Size\"/>"
  @"<Property Name=\"Opened\" Type=\"Edm.DateTimeOffset\" Precision=\"3\"/>"
  @"<NavigationProperty Name=\"Shelves\" Type=\"Collection(S.Shelf)\" ContainsTarget=\"true\"><OnDelete Action=\"Cascade\"/></NavigationProperty>"
  @"<Annotation Term=\"S.Rating\" Int=\"5\"/>"
  @"<Annotation Term=\"Core.LongDescription\"><Apply Function=\"odata.concat\"><String>Store </String><Path>Address/Zip</Path></Apply></Annotation>"
  @"</EntityType>"
  @"<EntityType Name=\"Shelf\"><Key><PropertyRef Name=\"Id\"/></Key><Property Name=\"Id\" Type=\"Edm.Int32\" Nullable=\"false\"/>"
  @"<Property Name=\"Anything\" Type=\"Edm.ComplexType\"/></EntityType>"
  @"<Action Name=\"Restock\" IsBound=\"true\" EntitySetPath=\"store/Shelves\"><Parameter Name=\"store\" Type=\"S.Store\"/>"
  @"<ReturnType Type=\"Collection(S.Shelf)\" Nullable=\"false\"/></Action>"
  @"<Action Name=\"Restock\" IsBound=\"true\"><Parameter Name=\"stores\" Type=\"Collection(S.Store)\"/>"
  @"<Parameter Name=\"size\" Type=\"S.Size\" Nullable=\"true\"><Annotation Term=\"Core.OptionalParameter\"/></Parameter></Action>"
  @"<Function Name=\"Nearest\" IsComposable=\"true\"><Parameter Name=\"at\" Type=\"Edm.GeographyPoint\"/>"
  @"<ReturnType Type=\"S.Store\" Nullable=\"true\"/></Function>"
  @"<EntityContainer Name=\"Container\">"
  @"<EntitySet Name=\"Stores\" EntityType=\"S.Store\"/>"
  @"<EntitySet Name=\"Hidden\" EntityType=\"S.Shelf\" IncludeInServiceDocument=\"false\"/>"
  @"<Singleton Name=\"Flagship\" Type=\"S.Store\" Nullable=\"true\"/>"
  @"<FunctionImport Name=\"Nearest\" Function=\"S.Nearest\" EntitySet=\"Stores\" IncludeInServiceDocument=\"true\"/>"
  @"<Annotation Term=\"Core.ODataVersions\" String=\"4.0 4.01\"/>"
  @"<Annotation Term=\"Core.Links\"><Collection><Record><PropertyValue Property=\"rel\" String=\"help\"/>"
  @"<PropertyValue Property=\"href\"><UrlRef><String>https://example.test/help</String></UrlRef></PropertyValue></Record></Collection></Annotation>"
  @"<Annotation Term=\"Core.Description\"><LabeledElement Name=\"Label\"><String>The shop</String></LabeledElement></Annotation>"
  @"</EntityContainer></Schema></edmx:DataServices></edmx:Edmx>";

- (void)testReadsAny401CSDL
{
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:[OIS401CSDL dataUsingEncoding:NSUTF8StringEncoding] error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  XCTAssertEqualObjects(schema.version, @"4.01");
  ODataSchemaEntityType *store = [schema entityTypeNamed:@"S.Store"];
  XCTAssertEqualObjects([schema property:@"Extra" ofEntityType:store].type, @"Edm.Untyped");
  XCTAssertEqualObjects([schema property:@"Weight" ofEntityType:store].type, @"Edm.Decimal");
  XCTAssertEqualObjects([schema enumTypeNamed:@"S.Size"].values[@"Large"], @4294967296LL);
  XCTAssertTrue([schema navigationProperty:@"Shelves" ofEntityType:store].containsTarget);
  XCTAssertEqualObjects(schema.entitySets[@"Hidden"], @"Shop.Shelf");
  XCTAssertEqual(schema.operations[@"Shop.Restock"].count, 2u, @"two overloads");
  XCTAssertEqualObjects([schema annotation:@"Shop.Rating" forTarget:@"Shop.Store"], @5);

  // And a model can be made of it: what Core Data has no type for is left
  // out or kept whole, never a failure.
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  NSEntityDescription *entity = model.entitiesByName[@"Store"];
  XCTAssertNotNil(entity);
  XCTAssertNotNil(entity.attributesByName[@"size"]);
  XCTAssertNotNil(model.entitiesByName[@"Shelf"]);
}

- (void)testTheServiceSaysWhichVersionsItSpeaks
{
  NSString *(^csdl)(NSString *, NSString *) = ^NSString *(NSString *edmx, NSString *annotation) {
    return [NSString stringWithFormat:
      @"<edmx:Edmx Version=\"%@\" xmlns:edmx=\"http://docs.oasis-open.org/odata/ns/edmx\">"
      @"<edmx:DataServices><Schema Namespace=\"S\" xmlns=\"http://docs.oasis-open.org/odata/ns/edm\">"
      @"<EntityType Name=\"T\"><Key><PropertyRef Name=\"Id\"/></Key><Property Name=\"Id\" Type=\"Edm.Int32\"/></EntityType>"
      @"<EntityContainer Name=\"C\"><EntitySet Name=\"Ts\" EntityType=\"S.T\"/>%@</EntityContainer>"
      @"</Schema></edmx:DataServices></edmx:Edmx>", edmx, annotation];
  };
  ODataSchema *(^read)(NSString *) = ^ODataSchema *(NSString *xml) {
    return [ODataSchema schemaWithData:[xml dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
  };
  XCTAssertEqualObjects(read(csdl(@"4.0", @"")).version, @"4.0");
  XCTAssertEqualObjects(read(csdl(@"4.0", @"<Annotation Term=\"Org.OData.Core.V1.ODataVersions\" String=\"4.0 4.01\"/>")).version, @"4.01",
                        @"4.0 CSDL, and the service speaks 4.01 too");
  XCTAssertEqualObjects(read(csdl(@"4.01", @"<Annotation Term=\"Org.OData.Core.V1.ODataVersions\" String=\"4.0\"/>")).version, @"4.0",
                        @"what it advertises wins");

  // ODataService advertises both.
  ODataConfiguration *configuration = [[ODataConfiguration alloc] initWithURL:[NSURL URLWithString:@"https://example.test/"] options:nil];
  XCTAssertEqualObjects([configuration versionForService:read(csdl(@"4.0", @"<Annotation Term=\"Org.OData.Core.V1.ODataVersions\" String=\"4.0 4.01\"/>")).version], @"4.01");
}

// What a schema knows, to compare two readings of one document.
static NSDictionary *OISSchemaFacts(ODataSchema *schema)
{
  NSMutableDictionary *facts = [NSMutableDictionary dictionary];
  facts[@"version"] = schema.version ?: @"";
  facts[@"sets"] = schema.entitySets ?: @{};
  facts[@"container"] = schema.containerName ?: @"";
  for (NSString *name in schema.entityTypes) {
    ODataSchemaEntityType *type = schema.entityTypes[name];
    NSMutableDictionary *t = [NSMutableDictionary dictionary];
    t[@"key"] = [schema keyOfEntityType:type];
    t[@"base"] = type.baseType ?: @"";
    t[@"abstract"] = @(type.isAbstract);
    t[@"stream"] = @(type.hasStream);
    for (NSString *p in type.declaredProperties) {
      ODataSchemaProperty *property = type.declaredProperties[p];
      t[p] = [NSString stringWithFormat:@"%@ %d %@", property.type, property.nullable, property.maxLength];
    }
    for (NSString *n in type.declaredNavigationProperties) {
      ODataSchemaNavigationProperty *navigation = type.declaredNavigationProperties[n];
      t[n] = [NSString stringWithFormat:@"%@ %d %@ %d", navigation.type, navigation.isCollection, navigation.partner, navigation.containsTarget];
    }
    facts[name] = t;
  }
  for (NSString *name in schema.enumTypes) facts[name] = schema.enumTypes[name].values;
  for (NSString *name in schema.complexTypes) {
    NSMutableDictionary *t = [NSMutableDictionary dictionary];
    for (NSString *p in schema.complexTypes[name].declaredProperties) t[p] = schema.complexTypes[name].declaredProperties[p].type;
    facts[name] = t;
  }
  for (NSString *name in schema.operations) {
    NSMutableArray *overloads = [NSMutableArray array];
    for (ODataSchemaOperation *operation in schema.operations[name]) {
      [overloads addObject:[NSString stringWithFormat:@"%d %d %@ %@", operation.isAction, operation.isBound, operation.returnType,
                            [[operation.parameters valueForKey:@"name"] componentsJoinedByString:@","]]];
    }
    facts[name] = [overloads sortedArrayUsingSelector:@selector(compare:)];
  }
  facts[@"imports"] = [schema.operationImports.allKeys sortedArrayUsingSelector:@selector(compare:)];
  facts[@"annotations"] = schema.annotations ?: @{};
  return facts;
}

// CSDL JSON (4.01): the same schema as the XML it is turned from, and back.
- (void)testCSDLInJSON
{
  NSString *zoo = [[NSString alloc] initWithData:[NSData dataWithContentsOfFile:[OISSnapshotDirectory() stringByAppendingPathComponent:@"Zoo/metadata.json"]] encoding:NSUTF8StringEncoding];
  NSString *zooXML = [NSJSONSerialization JSONObjectWithData:[zoo dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL][@"response"][@"bodyXML"];
  for (NSString *xml in @[ OIS401CSDL, OISAnnotatedCSDL, zooXML ]) {
    NSData *data = [xml dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    NSData *json = [ODataCSDL JSONDataForXMLData:data error:&error];
    XCTAssertNotNil(json, @"%@", error);
    ODataSchema *direct = [ODataSchema schemaWithData:data error:&error];
    ODataSchema *throughJSON = [ODataSchema schemaWithData:json error:&error];
    XCTAssertNotNil(throughJSON, @"%@\n%@", error, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    NSDictionary *a = OISSchemaFacts(direct), *b = OISSchemaFacts(throughJSON);
    for (NSString *key in a) XCTAssertEqualObjects(b[key], a[key], @"%@", key);
    XCTAssertEqualObjects([NSSet setWithArray:b.allKeys], [NSSet setWithArray:a.allKeys]);
  }

  NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[ODataCSDL JSONDataForXMLData:[OIS401CSDL dataUsingEncoding:NSUTF8StringEncoding] error:NULL] options:0 error:NULL];
  XCTAssertEqualObjects(json[@"$Version"], @"4.01");
  XCTAssertEqualObjects(json[@"$EntityContainer"], @"Shop.Container");
  NSDictionary *store = json[@"Shop"][@"Store"];
  XCTAssertEqualObjects(store[@"$Kind"], @"EntityType");
  XCTAssertEqualObjects(store[@"$Key"], (@[ @{ @"Zip": @"Address/Zip" } ]));
  XCTAssertEqualObjects(store[@"Tags"], (@{ @"$Collection": @YES, @"$Nullable": @YES }), @"Edm.String is the default type");
  XCTAssertEqualObjects(store[@"Address"], (@{ @"$Type": @"S.Address" }), @"not nullable: the default");
  XCTAssertEqualObjects(store[@"Ratio"][@"$Scale"], @"floating");
  XCTAssertEqualObjects(store[@"@S.Rating"], @5);
  XCTAssertEqualObjects(store[@"Shelves"][@"$OnDelete"], @"Cascade");
  XCTAssertEqual([json[@"Shop"][@"Restock"] count], 2u, @"overloads");
  XCTAssertEqualObjects(json[@"Shop"][@"Container"][@"Hidden"][@"$IncludeInServiceDocument"], @NO);
  XCTAssertEqualObjects(json[@"Shop"][@"Container"][@"@Core.ODataVersions"], @"4.0 4.01");

  // As the specification writes it (CSDL JSON section 3).
  NSString *spec = @"{\"$Version\":\"4.01\",\"$EntityContainer\":\"ODataDemo.DemoService\","
    @"\"$Reference\":{\"https://oasis-tcs.github.io/odata-vocabularies/vocabularies/Org.OData.Core.V1.json\":{\"$Include\":[{\"$Namespace\":\"Org.OData.Core.V1\",\"$Alias\":\"Core\"}]}},"
    @"\"ODataDemo\":{\"$Alias\":\"self\","
    @"\"Product\":{\"$Kind\":\"EntityType\",\"$HasStream\":true,\"$Key\":[\"ID\"],\"ID\":{},\"Description\":{\"$Nullable\":true,\"@Core.IsLanguageDependent\":true},"
    @"\"ReleaseDate\":{\"$Nullable\":true,\"$Type\":\"Edm.Date\"},\"Rating\":{\"$Nullable\":true,\"$Type\":\"Edm.Int32\"},\"Price\":{\"$Nullable\":true,\"$Type\":\"Edm.Decimal\",\"$Scale\":\"variable\"},"
    @"\"Category\":{\"$Kind\":\"NavigationProperty\",\"$Type\":\"self.Category\",\"$Partner\":\"Products\"}},"
    @"\"Category\":{\"$Kind\":\"EntityType\",\"$Key\":[\"ID\"],\"ID\":{\"$Type\":\"Edm.Int32\"},\"Name\":{\"$Nullable\":true,\"@Core.IsLanguageDependent\":true},"
    @"\"Products\":{\"$Kind\":\"NavigationProperty\",\"$Partner\":\"Category\",\"$Collection\":true,\"$Type\":\"self.Product\",\"$OnDelete\":\"Cascade\"}},"
    @"\"ShippingMethod\":{\"$Kind\":\"EnumType\",\"FirstClass\":0,\"TwoDay\":1,\"Overnight\":2},"
    @"\"ProductsByRating\":[{\"$Kind\":\"Function\",\"$Parameter\":[{\"$Name\":\"Rating\",\"$Type\":\"Edm.Int32\",\"$Nullable\":true}],\"$ReturnType\":{\"$Collection\":true,\"$Type\":\"self.Product\"}}],"
    @"\"DemoService\":{\"$Kind\":\"EntityContainer\",\"Products\":{\"$Collection\":true,\"$Type\":\"self.Product\",\"$NavigationPropertyBinding\":{\"Category\":\"Categories\"}},"
    @"\"Categories\":{\"$Collection\":true,\"$Type\":\"self.Category\",\"$NavigationPropertyBinding\":{\"Products\":\"Products\"},\"@Core.Description\":\"Product Categories\"},"
    @"\"ProductsByRating\":{\"$EntitySet\":\"Products\",\"$Function\":\"self.ProductsByRating\"}}}}";
  NSError *error = nil;
  ODataSchema *schema = [ODataSchema schemaWithData:[spec dataUsingEncoding:NSUTF8StringEncoding] error:&error];
  XCTAssertNotNil(schema, @"%@", error);
  ODataSchemaEntityType *product = [schema entityTypeNamed:@"ODataDemo.Product"];
  XCTAssertTrue(product.hasStream);
  XCTAssertEqualObjects([schema keyOfEntityType:product], @[ @"ID" ]);
  XCTAssertEqualObjects([schema property:@"ID" ofEntityType:product].type, @"Edm.String");
  XCTAssertFalse([schema property:@"ID" ofEntityType:product].nullable);
  XCTAssertTrue([schema property:@"Rating" ofEntityType:product].nullable);
  XCTAssertEqualObjects([schema navigationProperty:@"Category" ofEntityType:product].partner, @"Products");
  XCTAssertEqualObjects(schema.entitySets[@"Categories"], @"ODataDemo.Category");
  XCTAssertEqualObjects([schema enumTypeNamed:@"ODataDemo.ShippingMethod"].values[@"Overnight"], @2);
  XCTAssertEqualObjects([schema annotation:@"Core.Description" forTarget:@"ODataDemo.DemoService/Categories"], @"Product Categories");
  XCTAssertEqualObjects([schema annotation:@"Core.IsLanguageDependent" forTarget:@"ODataDemo.Category/Name"], @YES);
  XCTAssertEqual(schema.operations[@"ODataDemo.ProductsByRating"].count, 1u);
  XCTAssertNil([ODataSchema schemaWithData:[@"{\"nothing\":1}" dataUsingEncoding:NSUTF8StringEncoding] error:&error]);
}

- (void)testIdentifiersAreSpelledAsTheSchemaSpellsThem
{
  ODataSchema *schema = _store.schema;
  XCTAssertEqualObjects(ODataSchemaSpelling(@"animals", schema.entitySets), @"Animals");
  XCTAssertEqualObjects(ODataSchemaSpelling(@"Nothing", schema.entitySets), @"Nothing");
  XCTAssertEqualObjects([schema entityTypeNamed:@"zoo.lion"].qualifiedName, @"Zoo.Lion");
  XCTAssertEqualObjects([schema entityTypeWithSimpleName:@"LION"].qualifiedName, @"Zoo.Lion");

  NSEntityDescription *keeper = [[NSEntityDescription alloc] init];
  keeper.name = @"Keeper";
  keeper.userInfo = @{ ODataUserInfoEntitySet: @"staff" };
  NSAttributeDescription *name = OISAttribute(@"name", NSStringAttributeType);
  name.userInfo = @{ ODataUserInfoProperty: @"NAME" };
  keeper.properties = @[ name ];
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = schema;
  XCTAssertEqualObjects([mapper entitySetForEntity:keeper], @"Staff");
  XCTAssertEqualObjects([mapper propertyForAttribute:name], @"Name");

  ODataValueCoder *values = [[ODataValueCoder alloc] init];
  values.schema = schema;
  XCTAssertEqualObjects([values literalForValue:@"mane,STRIPES" typeName:@"Zoo.Features"], @"Zoo.Features'Mane,Stripes'");
}

@end
