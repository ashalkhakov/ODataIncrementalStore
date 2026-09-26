// ODataIncrementalStore
// Copyright (C) 2026 OIS contributors
//
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataIncrementalStore.h"

// One object's share of a save: the entity body, the $ref requests for
// to-many changes a body cannot carry, and the relationships that had to
// wait because their targets were not saved yet.
@interface OISWrite : NSObject
@property (nonatomic, strong) NSMutableDictionary *body;
@property (nonatomic, strong) NSMutableArray *references;  // @[ method, NSURL, body or NSNull ]
@property (nonatomic, strong) NSMutableSet *deferred;      // relationship names
@end

@implementation OISWrite
- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _body = [NSMutableDictionary dictionary];
  _references = [NSMutableArray array];
  _deferred = [NSMutableSet set];
  return self;
}
@end

// One request of a save and what to do with its response. A save is a
// list of these, sent as one $batch change set or one at a time.
@interface OISOperation : NSObject
@property (nonatomic, strong) NSURLRequest *request;
@property (nonatomic, copy) BOOL (^completion)(ODataHTTPResponse *response, NSError **error);
@end

@implementation OISOperation
@end

typedef NS_ENUM(NSInteger, OISWriteMode) {
  OISWriteInsert,    // every set attribute, keys the client chose, every relationship
  OISWriteUpdate,    // what changed since the last save
  OISWriteDeferred   // only the relationships an insert had to leave out
};

@implementation ODataIncrementalStore {
  ODataClient *_client;
  ODataPropertyMapper *_mapper;
  ODataQueryBuilder *_builder;
  NSMutableDictionary *_nodeCache;
  NSMutableDictionary *_etags;      // object ID -> ETag, exactly as the service sent it
  NSMutableDictionary *_versions;   // object ID -> node version, bumped when the ETag changes
  NSMutableDictionary *_deferred;   // object ID -> relationship names to write after insert
  NSMutableDictionary *_editLinks;  // object ID -> @odata.editLink, where the service gave one
  BOOL _batchRefused;               // the service answered $batch itself with an error
  NSLock *_lock;
}

+ (NSString *)storeType
{
  return ODataIncrementalStoreType;
}

+ (void)registerStore
{
  [NSPersistentStoreCoordinator registerStoreClass:self forStoreType:[self storeType]];
}

+ (ODataSchema *)schemaForServiceAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error
{
  ODataConfiguration *configuration = [[ODataConfiguration alloc] initWithURL:url options:options];
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:configuration];
  id transport = options[ODataIncrementalStoreTransportOption];
  if ([transport respondsToSelector:@selector(startExchange:)]) client.transport = transport;
  NSData *metadata = [client metadataWithError:error];
  return metadata ? [ODataSchema schemaWithData:metadata error:error] : nil;
}

+ (NSManagedObjectModel *)modelForServiceAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error
{
  ODataSchema *schema = [self schemaForServiceAtURL:url options:options error:error];
  return schema ? [ODataModelBuilder modelWithSchema:schema] : nil;
}

+ (NSDictionary *)metadataForSchema:(ODataSchema *)schema
{
  NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
  // NSStoreModelVersionHashesVersion is in every store's metadata Core
  // Data writes, though not in its headers; without it, Apple's
  // -isConfiguration:compatibleWithStoreMetadata: takes any model for a
  // match. FreeCoreData compares the hashes either way.
  return @{
    NSStoreTypeKey: [self storeType],
    NSStoreModelVersionHashesKey: model.entityVersionHashesByName,
    NSStoreModelVersionIdentifiersKey: model.versionIdentifiers.allObjects,
    @"NSStoreModelVersionHashesVersion": @3,
  };
}

+ (NSDictionary *)metadataForServiceAtURL:(NSURL *)url options:(NSDictionary *)options error:(NSError **)error
{
  ODataSchema *schema = [self schemaForServiceAtURL:url options:options error:error];
  return schema ? [self metadataForSchema:schema] : nil;
}

- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root
                                 configurationName:(NSString *)name
                                               URL:(NSURL *)url
                                           options:(NSDictionary *)options
{
  self = [super initWithPersistentStoreCoordinator:root configurationName:name URL:url options:options];
  if (!self) return nil;
  _nodeCache = [NSMutableDictionary dictionary];
  _etags = [NSMutableDictionary dictionary];
  _versions = [NSMutableDictionary dictionary];
  _deferred = [NSMutableDictionary dictionary];
  _editLinks = [NSMutableDictionary dictionary];
  _metadataProblems = @[];
  _lock = [[NSLock alloc] init];
  return self;
}

- (BOOL)loadMetadata:(NSError **)error
{
  NSURL *url = self.URL;
  if (!url) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingServiceURL, @"The store URL must be the OData service root.");
    return NO;
  }
  ODataConfiguration *configuration = [[ODataConfiguration alloc] initWithURL:url options:self.options];
  _client = [[ODataClient alloc] initWithConfiguration:configuration];
  id transport = self.options[ODataIncrementalStoreTransportOption];
  if ([transport respondsToSelector:@selector(startExchange:)]) {
    _client.transport = transport;
  }
  _mapper = [[ODataPropertyMapper alloc] init];
  _mapper.naming = configuration.naming;
  _mapper.values.IEEE754Compatible = configuration.IEEE754Compatible;
  _builder = [[ODataQueryBuilder alloc] initWithMapper:_mapper serviceRoot:configuration.serviceRoot];
  // `category == %@` compares keys, which only this store can read out of
  // one of its object IDs.
  __weak ODataIncrementalStore *weakSelf = self;
  _builder.keysForObjectID = ^NSDictionary *(NSManagedObjectID *objectID) {
    ODataIncrementalStore *store = weakSelf;
    if (!store || objectID.persistentStore != store) return nil;
    return [ODataResourceIdentifier identifierFromReference:[store referenceObjectForObjectID:objectID]].keys;
  };
  NSData *metadata = [_client metadataWithError:error];
  if (!metadata) return NO;
  // The schema, where it can be read, fills in what the model leaves
  // unsaid; what does not match is reported, and fails the open only when
  // asked to. A schema that cannot be read is a problem, not a failure.
  NSError *schemaError = nil;
  _schema = [ODataSchema schemaWithData:metadata error:&schemaError];
  _mapper.schema = _schema;
  id keyAsSegment = self.options[ODataIncrementalStoreKeyAsSegmentOption];
  _builder.keyAsSegment = keyAsSegment ? [keyAsSegment boolValue] : _schema.keyAsSegmentSupported;
  NSManagedObjectModel *model = self.persistentStoreCoordinator.managedObjectModel;
  _metadataProblems = _schema ? [_mapper problemsWithModel:model] : @[ schemaError.localizedDescription ?: @"$metadata could not be read" ];
  if (_metadataProblems.count && [self.options[ODataIncrementalStoreRequireMatchingModelOption] boolValue]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorModelMismatch,
                                 [@"The model does not match the service's $metadata: " stringByAppendingString:[_metadataProblems componentsJoinedByString:@"; "]]);
    return NO;
  }
  NSString *uuid = [NSIncrementalStore identifierForNewStoreAtURL:url];
  if (![uuid isKindOfClass:[NSString class]]) uuid = [[NSUUID UUID] UUIDString];
  NSMutableDictionary *storeMetadata = [@{ NSStoreUUIDKey: uuid, NSStoreTypeKey: [[self class] storeType] } mutableCopy];

  // A model generated from a schema is a version of the service's model,
  // and is checked as Core Data checks a model against any store: by the
  // version hashes of the model the service's schema describes now.
  NSString *modelVersion = [ODataModelBuilder versionIdentifierOfModel:model];
  if (modelVersion && _schema) {
    [storeMetadata addEntriesFromDictionary:[[self class] metadataForSchema:_schema]];
    storeMetadata[NSStoreUUIDKey] = uuid;
    if (![model isConfiguration:self.configurationName compatibleWithStoreMetadata:storeMetadata]) {
      NSString *serviceVersion = [ODataModelBuilder versionIdentifierForSchema:_schema];
      NSString *message = [NSString stringWithFormat:@"The service's schema has changed since the model was generated: the model is %@, the service %@. "
                                                     @"Generate a new model version from its $metadata.", modelVersion, serviceVersion];
      if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPersistentStoreIncompatibleVersionHashError
                                          userInfo:@{ NSLocalizedDescriptionKey: message, NSURLErrorKey: url }];
      return NO;
    }
  }
  self.metadata = storeMetadata;
  return YES;
}

- (id)executeRequest:(NSPersistentStoreRequest *)request
         withContext:(NSManagedObjectContext *)context
               error:(NSError **)error
{
  if (request.requestType == NSFetchRequestType) {
    if (![request isKindOfClass:[NSFetchRequest class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, @"Expected NSFetchRequest");
      return nil;
    }
    return [self executeFetch:(NSFetchRequest *)request context:context error:error];
  }
  if (request.requestType == NSSaveRequestType) {
    if (![request isKindOfClass:[NSSaveChangesRequest class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, @"Expected NSSaveChangesRequest");
      return nil;
    }
    return [self executeSave:(NSSaveChangesRequest *)request error:error];
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, @"Unsupported NSPersistentStoreRequest");
  return nil;
}

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError **)error
{
  (void)context;
  [_lock lock];
  NSIncrementalStoreNode *cached = _nodeCache[objectID];
  [_lock unlock];
  if (cached) return cached;

  ODataResourceIdentifier *identifier = [self identifierFromObjectID:objectID error:error];
  if (!identifier) return nil;
  NSURL *url = [_builder URLForReadingIdentifier:identifier entity:objectID.entity error:error];
  if (!url) return nil;
  id json = [_client JSONAtURL:url error:error];
  if (!json) return nil;
  if (![json isKindOfClass:[NSDictionary class]]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Expected entity for %@", identifier.path]);
    return nil;
  }
  return [self cacheNodeForObjectID:objectID entity:objectID.entity payload:json error:error];
}

- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError **)error
{
  (void)context;
  ODataResourceIdentifier *identifier = [self identifierFromObjectID:objectID error:error];
  if (!identifier) return nil;
  NSURL *url = [_builder URLForIdentifier:identifier relationship:relationship error:error];
  if (!url) return nil;
  NSEntityDescription *destination = relationship.destinationEntity;
  if (!destination) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingEntitySet, relationship.name);
    return nil;
  }
  if (relationship.isToMany) {
    NSArray *rows = [self rowsAtURL:url limit:0 pageSize:0 error:error];
    if (!rows) return nil;
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *row in rows) {
      NSManagedObjectID *oid = [self objectIDFromPayload:row entity:destination error:error];
      if (!oid) return nil;
      [self cacheNodeForObjectID:oid entity:oid.entity payload:row error:nil];
      [ids addObject:oid];
    }
    return ids;
  }
  id json = [_client JSONAtURL:url error:error];
  if (!json) return nil;
  // 204 No Content: nothing is related (Part 1 section 11.2.7).
  if (![json isKindOfClass:[NSDictionary class]]) return [NSNull null];
  NSManagedObjectID *oid = [self objectIDFromPayload:json entity:destination error:error];
  if (oid) [self cacheNodeForObjectID:oid entity:oid.entity payload:json error:nil];
  return oid;
}

// With postOnObtainPermanentIDs (the default) inserts are POSTed here, so
// the service assigns the keys. Objects are posted in dependency order, so
// a new Product can bind to a new Category posted just before it; what a
// cycle leaves unbound is written by -executeSave:.
- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error
{
  NSMutableDictionary *assigned = [NSMutableDictionary dictionary];  // temporary ID -> permanent ID
  NSArray *order = _client.configuration.postOnObtainPermanentIDs ? [self insertOrder:array] : array;
  for (NSManagedObject *object in order) {
    NSEntityDescription *entity = object.entity;
    NSManagedObjectID *oid = nil;
    if (_client.configuration.postOnObtainPermanentIDs) {
      OISWrite *write = [self writeForObject:object mode:OISWriteInsert assigned:assigned];
      NSDictionary *payload = [self postWrite:write entity:entity error:error];
      if (!payload) return nil;
      oid = [self objectIDFromPayload:payload entity:entity error:error];
      if (!oid) return nil;
      [self cacheNodeForObjectID:oid entity:entity payload:payload error:nil];
      if (write.deferred.count) {
        [_lock lock];
        _deferred[oid] = [write.deferred copy];
        [_lock unlock];
      }
    } else {
      NSDictionary *keys = [self clientKeysForObject:object error:error];
      if (!keys) return nil;
      ODataResourceIdentifier *identifier = [self identifierForEntity:entity keys:keys];
      oid = [self newObjectIDForEntity:entity referenceObject:identifier.data];
    }
    assigned[object.objectID] = oid;
  }
  NSMutableArray *ids = [NSMutableArray array];
  for (NSManagedObject *object in array) [ids addObject:assigned[object.objectID]];
  return ids;
}

// Inserted objects, each after the inserted objects it refers to. A cycle
// is broken arbitrarily; the reference that closes it is deferred.
- (NSArray *)insertOrder:(NSArray *)objects
{
  NSMutableSet *batch = [NSMutableSet set];
  for (NSManagedObject *o in objects) [batch addObject:o.objectID];
  NSMutableArray *order = [NSMutableArray array];
  NSMutableSet *done = [NSMutableSet set];
  NSMutableSet *visiting = [NSMutableSet set];
  __block void (^visit)(NSManagedObject *) = nil;
  void (^visitor)(NSManagedObject *) = ^(NSManagedObject *object) {
    NSManagedObjectID *oid = object.objectID;
    if ([done containsObject:oid] || [visiting containsObject:oid]) return;
    [visiting addObject:oid];
    for (NSRelationshipDescription *rel in object.entity.relationshipsByName.allValues) {
      if (![self writesRelationship:rel]) continue;
      id value = [object valueForKey:rel.name];
      NSArray *targets = rel.isToMany ? [value allObjects] : (value ? @[ value ] : @[]);
      for (NSManagedObject *target in targets) {
        if ([target isKindOfClass:[NSManagedObject class]] && [batch containsObject:target.objectID]) visit(target);
      }
    }
    [visiting removeObject:oid];
    [done addObject:oid];
    [order addObject:object];
  };
  visit = visitor;
  for (NSManagedObject *object in objects) visit(object);
  visit = nil;
  return order;
}

#pragma mark - Fetch / save

- (id)executeFetch:(NSFetchRequest *)fetch context:(NSManagedObjectContext *)context error:(NSError **)error
{
  NSEntityDescription *entity = [self resolvedEntity:fetch];
  if (!entity) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingEntitySet, fetch.entityName ?: @"Unknown");
    return nil;
  }
  NSURL *url = [_builder URLForFetch:fetch entity:entity error:error];
  if (!url) return nil;

  if (fetch.resultType == NSCountResultType) {
    NSString *text = [_client textAtURL:url error:error];
    if (!text) return nil;
    NSInteger count = [text integerValue];
    return @[ @(count) ];
  }

  NSArray *rows = [self rowsAtURL:url limit:fetch.fetchLimit pageSize:fetch.fetchBatchSize error:error];
  if (!rows) return nil;

  if (fetch.resultType == NSDictionaryResultType) {
    NSMutableArray *dicts = [NSMutableArray array];
    for (NSDictionary *row in rows) {
      [dicts addObject:[self dictionaryFromPayload:row entity:entity properties:fetch.propertiesToFetch]];
    }
    return dicts;
  }

  // Every row is a whole entity, so it is cached whether or not the fetch
  // returns faults: firing the fault then costs nothing, where it used to
  // cost one GET per object.
  NSMutableArray *objectIDs = [NSMutableArray array];
  for (NSDictionary *row in rows) {
    NSManagedObjectID *oid = [self objectIDFromPayload:row entity:entity error:error];
    if (!oid) return nil;
    [self cacheNodeForObjectID:oid entity:oid.entity payload:row error:nil];
    // A set of a base type holds its derived types too; a fetch that does
    // not include sub-entities leaves them out.
    if (!fetch.includesSubentities && oid.entity != entity && ![oid.entity.name isEqualToString:entity.name]) continue;
    [objectIDs addObject:oid];
  }

  if (fetch.resultType == NSManagedObjectIDResultType) return objectIDs;
  if (!context) return objectIDs;
  NSMutableArray *objects = [NSMutableArray array];
  for (NSManagedObjectID *oid in objectIDs) {
    [objects addObject:[context objectWithID:oid]];
  }
  return objects;
}

// The rows of a collection, across every page the service splits it into:
// @odata.nextLink is followed until it stops, or until `limit` rows (0 for
// no limit) are in hand (Part 1 section 11.2.6.7). A failed request fails
// the whole read; it is never an empty result. A page size, from the
// fetch's fetchBatchSize, is asked for with Prefer: odata.maxpagesize
// (section 8.2.8.3); the service may page smaller, never larger.
- (NSArray *)rowsAtURL:(NSURL *)url limit:(NSUInteger)limit pageSize:(NSUInteger)pageSize error:(NSError **)error
{
  NSDictionary *headers = pageSize ? @{ @"Prefer": [NSString stringWithFormat:@"odata.maxpagesize=%lu", (unsigned long)pageSize] } : nil;
  NSMutableArray *rows = [NSMutableArray array];
  NSMutableSet *seen = [NSMutableSet set];
  while (url) {
    NSString *absolute = url.absoluteString ?: @"";
    if ([seen containsObject:absolute]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Next link loops back to %@", absolute]);
      return nil;
    }
    [seen addObject:absolute];
    id json = [_client JSONAtURL:url headers:headers error:error];
    if (!json) return nil;
    if (json == [NSNull null]) break;
    if (![json isKindOfClass:[NSDictionary class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Expected a JSON object from %@", absolute]);
      return nil;
    }
    id value = json[@"value"];
    NSArray *page = [value isKindOfClass:[NSArray class]] ? value : @[ json ];
    for (id row in page) {
      if ([row isKindOfClass:[NSDictionary class]]) [rows addObject:row];
    }
    if (limit && rows.count >= limit) {
      return [rows subarrayWithRange:NSMakeRange(0, limit)];
    }
    NSString *next = json[@"@odata.nextLink"];
    url = [next isKindOfClass:[NSString class]] ? [NSURL URLWithString:next relativeToURL:url].absoluteURL : nil;
  }
  return rows;
}

- (id)executeSave:(NSSaveChangesRequest *)save error:(NSError **)error
{
  NSMutableArray *operations = [NSMutableArray array];
  NSMutableArray *referenced = [NSMutableArray array];  // objects whose $ref requests may change their ETag

  if (!_client.configuration.postOnObtainPermanentIDs) {
    for (NSManagedObject *object in [self insertOrder:save.insertedObjects.allObjects]) {
      OISWrite *write = [self writeForObject:object mode:OISWriteInsert assigned:nil];
      if (![self addPostOf:write object:object to:operations error:error]) return nil;
      if (![self addReferencesOf:write to:operations error:error]) return nil;
    }
  }
  for (NSManagedObject *object in save.insertedObjects) {
    [_lock lock];
    BOOL deferred = _deferred[object.objectID] != nil;
    [_lock unlock];
    if (!deferred) continue;
    OISWrite *write = [self writeForObject:object mode:OISWriteDeferred assigned:nil];
    if (![self addPatchOf:write object:object to:operations error:error]) return nil;
    if (write.references.count) [referenced addObject:object];
  }
  for (NSManagedObject *object in save.updatedObjects) {
    OISWrite *write = [self writeForObject:object mode:OISWriteUpdate assigned:nil];
    if (![self addPatchOf:write object:object to:operations error:error]) return nil;
    if (write.references.count) [referenced addObject:object];
  }
  for (NSManagedObject *object in save.deletedObjects) {
    NSURL *url = [self editURLForObjectID:object.objectID error:error];
    NSMutableURLRequest *request = url ? [_client requestWithMethod:@"DELETE" URL:url body:nil
                                                               etag:[self currentETagForObjectID:object.objectID] error:error] : nil;
    if (!request) return nil;
    NSManagedObjectID *objectID = object.objectID;
    [operations addObject:[self operation:request completion:^BOOL(ODataHTTPResponse *response, NSError **e) {
      [self forgetObjectID:objectID];
      return YES;
    }]];
  }

  if (![self sendOperations:operations error:error]) return nil;

  for (NSManagedObject *object in save.insertedObjects) {
    [_lock lock];
    [_deferred removeObjectForKey:object.objectID];
    [_lock unlock];
  }
  // A $ref request changes the entity, and may change its ETag, without
  // returning it; read it back so the next write does not send a stale one.
  for (NSManagedObject *object in referenced) {
    [_lock lock];
    BOOL hasETag = _etags[object.objectID] != nil;
    [_lock unlock];
    if (!hasETag) continue;
    ODataResourceIdentifier *identifier = [self identifierFromObjectID:object.objectID error:NULL];
    NSURL *url = identifier ? [_builder URLForReadingIdentifier:identifier entity:object.entity error:NULL] : nil;
    id fresh = url ? [_client JSONAtURL:url error:NULL] : nil;
    if ([fresh isKindOfClass:[NSDictionary class]]) {
      [self cacheNodeForObjectID:object.objectID entity:object.entity payload:fresh error:nil];
    } else {
      [_lock lock];
      [_etags removeObjectForKey:object.objectID];
      [_lock unlock];
    }
  }
  return @[];
}

- (OISOperation *)operation:(NSURLRequest *)request completion:(BOOL (^)(ODataHTTPResponse *, NSError **))completion
{
  OISOperation *operation = [[OISOperation alloc] init];
  operation.request = request;
  operation.completion = completion;
  return operation;
}

// A save of two or more requests is one $batch change set, so it takes
// effect whole or not at all (Part 1 section 11.7.4). $batch is required
// only of Advanced services: one that answers the batch request itself
// with 400, 404, 405, 415 or 501 has run none of it, and gets the requests
// one at a time from then on. Any other failure fails the save: TripPin,
// for one, can apply part of a batch and then answer 500.
- (BOOL)sendOperations:(NSArray *)operations error:(NSError **)error
{
  if (!operations.count) return YES;
  BOOL batch = operations.count > 1 && _client.configuration.batchSaves && !_batchRefused;
  if (batch) {
    NSMutableArray *requests = [NSMutableArray array];
    for (OISOperation *operation in operations) [requests addObject:operation.request];
    NSError *batchError = nil;
    NSArray *responses = [_client sendChangeSet:requests error:&batchError];
    if (responses) {
      for (NSUInteger i = 0; i < operations.count; i++) {
        OISOperation *operation = operations[i];
        if (operation.completion && !operation.completion(responses[i], error)) return NO;
      }
      return YES;
    }
    NSURL *failed = batchError.userInfo[NSURLErrorFailingURLErrorKey];
    NSInteger status = [batchError.userInfo[ODataErrorHTTPStatusKey] integerValue];
    BOOL refused = [failed.path hasSuffix:@"$batch"] &&
                   (status == 400 || status == 404 || status == 405 || status == 415 || status == 501);
    if (!refused) {
      if (error) *error = batchError;
      return NO;
    }
    _batchRefused = YES;
  }
  for (OISOperation *operation in operations) {
    ODataHTTPResponse *response = [_client sendRequest:operation.request error:error];
    if (!response) return NO;
    if (operation.completion && !operation.completion(response, error)) return NO;
  }
  return YES;
}

- (BOOL)addPostOf:(OISWrite *)write object:(NSManagedObject *)object to:(NSMutableArray *)operations error:(NSError **)error
{
  NSEntityDescription *entity = object.entity;
  NSManagedObjectID *objectID = object.objectID;
  NSURL *url = [_client.configuration.serviceRoot URLByAppendingPathComponent:[_mapper entitySetForEntity:entity]];
  NSMutableURLRequest *request = [_client requestWithMethod:@"POST" URL:url body:write.body etag:nil error:error];
  if (!request) return NO;
  [operations addObject:[self operation:request completion:^BOOL(ODataHTTPResponse *response, NSError **e) {
    NSDictionary *payload = [self createdEntityFrom:response URL:url error:e];
    if (!payload) return NO;
    [self cacheNodeForObjectID:objectID entity:entity payload:payload error:nil];
    return YES;
  }]];
  return YES;
}

// PATCH the body, if there is one, with the entity's ETag; then the $ref
// requests. Nothing at all for an object with nothing to send, such as the
// to-many side of a relationship whose to-one side was bound.
- (BOOL)addPatchOf:(OISWrite *)write object:(NSManagedObject *)object to:(NSMutableArray *)operations error:(NSError **)error
{
  if (write.body.count) {
    NSURL *url = [self editURLForObjectID:object.objectID error:error];
    NSMutableURLRequest *request = url ? [_client requestWithMethod:@"PATCH" URL:url body:write.body
                                                               etag:[self currentETagForObjectID:object.objectID] error:error] : nil;
    if (!request) return NO;
    [operations addObject:[self operation:request completion:^BOOL(ODataHTTPResponse *response, NSError **e) {
      [self absorbResponse:response object:object URL:url];
      return YES;
    }]];
  }
  return [self addReferencesOf:write to:operations error:error];
}

- (BOOL)addReferencesOf:(OISWrite *)write to:(NSMutableArray *)operations error:(NSError **)error
{
  for (NSArray *reference in write.references) {
    id body = reference[2] == [NSNull null] ? nil : reference[2];
    NSMutableURLRequest *request = [_client requestWithMethod:reference[0] URL:reference[1] body:body etag:nil error:error];
    if (!request) return NO;
    [operations addObject:[self operation:request completion:nil]];
  }
  return YES;
}

// POST to the entity set now, outside any save: the entity as created.
- (NSDictionary *)postWrite:(OISWrite *)write entity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSURL *url = [_client.configuration.serviceRoot URLByAppendingPathComponent:[_mapper entitySetForEntity:entity]];
  ODataHTTPResponse *response = [_client sendJSONMethod:@"POST" URL:url body:write.body etag:nil error:error];
  return response ? [self createdEntityFrom:response URL:url error:error] : nil;
}

// The entity a POST created. Prefer asks for it in the response; a service
// that answers 204 anyway gives its URL in Location (Part 1 section
// 11.4.2), which is read back.
- (NSDictionary *)createdEntityFrom:(ODataHTTPResponse *)response URL:(NSURL *)url error:(NSError **)error
{
  id json = response.data.length ? [response JSONWithError:NULL] : nil;
  if (![json isKindOfClass:[NSDictionary class]]) {
    NSString *location = [response valueForHeader:@"Location"] ?: [response valueForHeader:@"OData-EntityId"];
    NSURL *created = location.length ? [NSURL URLWithString:location relativeToURL:url].absoluteURL : nil;
    if (!created) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"POST %@ returned neither the entity nor its Location", url.lastPathComponent]);
      return nil;
    }
    json = [_client JSONAtURL:created error:error];
    if (!json) return nil;
    if (![json isKindOfClass:[NSDictionary class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Expected an entity at %@", created]);
      return nil;
    }
  }
  if (!json[@"@odata.etag"] && response.etag) {
    NSMutableDictionary *tagged = [json mutableCopy];
    tagged[@"@odata.etag"] = response.etag;
    json = tagged;
  }
  return json;
}

// After a PATCH: the entity as the service now has it. From the body when
// it sent one; else the object's own values, which the service just
// accepted, under the new ETag from the header. With neither body nor
// ETag header, an entity that had an ETag is read back, since sending the
// old one would fail the next write with 412.
- (void)absorbResponse:(ODataHTTPResponse *)response object:(NSManagedObject *)object URL:(NSURL *)url
{
  NSManagedObjectID *objectID = object.objectID;
  NSEntityDescription *entity = object.entity;
  id json = response.data.length ? [response JSONWithError:NULL] : nil;
  if ([json isKindOfClass:[NSDictionary class]]) {
    if (!json[@"@odata.etag"] && response.etag) {
      NSMutableDictionary *tagged = [json mutableCopy];
      tagged[@"@odata.etag"] = response.etag;
      json = tagged;
    }
    [self cacheNodeForObjectID:objectID entity:entity payload:json error:nil];
    return;
  }
  [_lock lock];
  BOOL hadETag = _etags[objectID] != nil;
  [_lock unlock];
  if (!response.etag.length && hadETag) {
    id fresh = [_client JSONAtURL:url error:NULL];
    if ([fresh isKindOfClass:[NSDictionary class]]) {
      [self cacheNodeForObjectID:objectID entity:entity payload:fresh error:nil];
      return;
    }
    [_lock lock];
    [_etags removeObjectForKey:objectID];
    [_lock unlock];
  }
  [self rememberETag:response.etag forObjectID:objectID];
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSString *name in entity.attributesByName) {
    id value = [object valueForKey:name];
    if (value) values[name] = value;
  }
  NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID
                                                                       withValues:values
                                                                          version:[self versionForObjectID:objectID]];
  [_lock lock];
  _nodeCache[objectID] = node;
  [_lock unlock];
}

#pragma mark - Mapping

// Whether this side of a relationship is written. Core Data changes both
// sides of a relationship, and the service needs to hear it once:
// - to-one: always, as a bind;
// - to-many opposite a to-one: never, the to-one side's bind says it;
// - many-to-many: from one side only, the first by entity and then
//   relationship name;
// - to-many with no inverse: always.
- (BOOL)writesRelationship:(NSRelationshipDescription *)rel
{
  if (!rel.isToMany) return YES;
  NSRelationshipDescription *inverse = rel.inverseRelationship;
  if (!inverse) return YES;
  if (!inverse.isToMany) return NO;
  NSComparisonResult order = [rel.entity.name compare:inverse.entity.name];
  if (order == NSOrderedSame) order = [rel.name compare:inverse.name];
  return order != NSOrderedDescending;
}

static BOOL OISKeyIsSet(id value)
{
  if (!value || value == [NSNull null]) return NO;
  if ([value isKindOfClass:[NSNumber class]]) return [value longLongValue] != 0;
  if ([value isKindOfClass:[NSString class]]) return [value length] > 0;
  return YES;
}

// The resource path of a related object ("Categories(2)"), or nil while it
// is unsaved. `assigned` maps the temporary IDs of objects inserted earlier
// in the same batch to their new permanent IDs.
- (NSString *)entityPathForObject:(NSManagedObject *)target assigned:(NSDictionary *)assigned
{
  NSManagedObjectID *oid = target.objectID;
  if (oid.isTemporaryID) oid = assigned[oid];
  if (!oid || oid.isTemporaryID) return nil;
  return [ODataResourceIdentifier identifierFromReference:[self referenceObjectForObjectID:oid]].path;
}

- (NSURL *)absoluteURLForPath:(NSString *)path
{
  return [NSURL URLWithString:path relativeToURL:_client.configuration.serviceRoot].absoluteURL;
}

- (NSManagedObjectID *)objectIDOf:(id)value
{
  return [value isKindOfClass:[NSManagedObject class]] ? [value objectID] : value;
}

- (OISWrite *)writeForObject:(NSManagedObject *)object mode:(OISWriteMode)mode assigned:(NSDictionary *)assigned
{
  OISWrite *write = [[OISWrite alloc] init];
  NSEntityDescription *entity = object.entity;
  NSDictionary *changed = mode == OISWriteUpdate ? [object changedValues] : nil;
  NSSet *only = nil;
  if (mode == OISWriteDeferred) {
    [_lock lock];
    only = _deferred[object.objectID];
    [_lock unlock];
  }

  if (mode == OISWriteInsert && [_mapper entityIsDerivedInItsSet:entity]) {
    write.body[@"@odata.type"] = [@"#" stringByAppendingString:[_mapper qualifiedTypeForEntity:entity]];
  }
  if (mode != OISWriteDeferred) {
    NSMutableSet *keyNames = [NSMutableSet set];
    for (NSAttributeDescription *attr in [_mapper keyAttributesForEntity:entity]) [keyNames addObject:attr.name];
    for (NSAttributeDescription *attr in entity.attributesByName.allValues) {
      NSString *name = attr.name;
      id value = [object primitiveValueForKey:name];
      if ([keyNames containsObject:name]) {
        // A key goes in a POST only when the client chose it; the service
        // assigns the rest. Keys are never PATCHed.
        if (mode == OISWriteInsert && OISKeyIsSet(value)) write.body[[_mapper propertyForAttribute:attr]] = [_mapper.values JSONForCoreDataValue:value attribute:attr];
        continue;
      }
      if (mode == OISWriteUpdate && !changed[name]) continue;
      id json = [_mapper.values JSONForCoreDataValue:value attribute:attr];
      // POST omits unset optional properties (section 11.4.2); PATCH sends
      // null to clear one.
      if (mode == OISWriteInsert && json == [NSNull null]) continue;
      write.body[[_mapper propertyForAttribute:attr]] = json;
    }
  }

  NSURL *entityURL = mode == OISWriteInsert ? nil : [self editURLForObjectID:object.objectID error:NULL];
  NSArray *relationships = [entity.relationshipsByName.allValues sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
    return [[a name] compare:[b name]];
  }];
  for (NSRelationshipDescription *rel in relationships) {
    NSString *name = rel.name;
    if (![self writesRelationship:rel]) continue;
    if (only && ![only containsObject:name]) continue;
    if (mode == OISWriteUpdate && !changed[name]) continue;
    NSString *wire = [_mapper propertyForRelationship:rel];
    NSString *bindKey = [wire stringByAppendingString:@"@odata.bind"];
    NSURL *refURL = entityURL ? [NSURL URLWithString:[entityURL.absoluteString stringByAppendingFormat:@"/%@/$ref", wire]] : nil;

    if (!rel.isToMany) {
      NSManagedObject *target = [object valueForKey:name];
      if (mode == OISWriteInsert) {
        // A bind in the POST: the only way to create an entity whose
        // relationship is required (JSON Format section 8.5).
        if (!target) continue;
        NSString *path = [self entityPathForObject:target assigned:assigned];
        if (path) write.body[bindKey] = path;
        else [write.deferred addObject:name];
        continue;
      }
      // Changing an existing entity's reference: PUT or DELETE its $ref
      // (Part 1 sections 11.4.6.3, 11.4.6.2). A bind in a PATCH is allowed
      // too, but TripPin answers 204 and ignores it.
      if (!refURL) continue;
      if (target) {
        NSString *path = [self entityPathForObject:target assigned:assigned];
        if (!path) continue;
        NSDictionary *reference = @{ @"@odata.id": [self absoluteURLForPath:path].absoluteString };
        [write.references addObject:@[ @"PUT", refURL, reference ]];
      } else {
        [write.references addObject:@[ @"DELETE", refURL, [NSNull null] ]];
      }
      continue;
    }

    NSSet *current = [object valueForKey:name] ?: [NSSet set];
    if (mode == OISWriteInsert) {
      NSMutableArray *paths = [NSMutableArray array];
      for (NSManagedObject *target in current) {
        NSString *path = [self entityPathForObject:target assigned:assigned];
        if (!path) {
          paths = nil;
          [write.deferred addObject:name];
          break;
        }
        [paths addObject:path];
      }
      if (paths.count) write.body[bindKey] = paths;
      continue;
    }
    // Update, or deferred from an insert (where nothing was committed):
    // POST a reference for each addition, DELETE one for each removal.
    NSMutableSet *before = [NSMutableSet set];
    if (mode == OISWriteUpdate) {
      id committed = [object committedValuesForKeys:@[ name ]][name];
      for (id value in ([committed isKindOfClass:[NSSet class]] ? committed : @[])) [before addObject:[self objectIDOf:value]];
    }
    NSMutableSet *after = [NSMutableSet set];
    for (NSManagedObject *target in current) {
      NSManagedObjectID *oid = target.objectID;
      [after addObject:oid];
      if ([before containsObject:oid]) continue;
      NSString *path = [self entityPathForObject:target assigned:assigned];
      if (!path || !refURL) continue;
      NSDictionary *reference = @{ @"@odata.id": [self absoluteURLForPath:path].absoluteString };
      [write.references addObject:@[ @"POST", refURL, reference ]];
    }
    for (NSManagedObjectID *oid in before) {
      if ([after containsObject:oid] || !entityURL) continue;
      ODataResourceIdentifier *gone = [self identifierFromObjectID:oid error:NULL];
      NSURL *url = gone ? [_builder URLForReferenceFromEntityURL:entityURL
                                                    relationship:rel
                                                          target:[self absoluteURLForPath:gone.path]] : nil;
      if (url) [write.references addObject:@[ @"DELETE", url, [NSNull null] ]];
    }
  }
  return write;
}

- (NSDictionary *)dictionaryFromPayload:(NSDictionary *)payload
                                 entity:(NSEntityDescription *)entity
                             properties:(NSArray *)properties
{
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  NSArray *wanted = properties.count ? properties : entity.attributesByName.allKeys;
  for (id prop in wanted) {
    NSString *name = [prop isKindOfClass:[NSAttributeDescription class]] ? [prop name] : prop;
    NSAttributeDescription *attr = entity.attributesByName[name];
    if (!attr) continue;
    id raw = payload[[_mapper propertyForAttribute:attr]];
    id value = raw ? [_mapper.values coreDataValueForJSON:raw attribute:attr] : nil;
    if (value) out[name] = value;
  }
  return out;
}

- (NSManagedObjectID *)objectIDFromPayload:(NSDictionary *)payload
                                    entity:(NSEntityDescription *)entity
                                     error:(NSError **)error
{
  // A row of a derived type says so (JSON Format section 4.5.3): its object
  // is of the sub-entity standing for that type.
  entity = [_mapper entity:entity forTypeName:payload[@"@odata.type"]];
  NSArray *keyAttrs = [_mapper keyAttributesForEntity:entity];
  if (!keyAttrs.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingKey, entity.name ?: @"?");
    return nil;
  }
  NSMutableDictionary *keys = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attr in keyAttrs) {
    NSString *wire = [_mapper propertyForAttribute:attr];
    id raw = payload[wire] ?: payload[attr.name];
    // With IEEE754Compatible an Int64 key arrives as "1": decoded, it is
    // the same key, and the same object ID, as 1.
    id value = raw ? [self referenceValue:[_mapper.values coreDataValueForJSON:raw attribute:attr]] : nil;
    if (!value || value == [NSNull null]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Missing key %@", wire]);
      return nil;
    }
    keys[wire] = value;
  }
  ODataResourceIdentifier *identifier = [self identifierForEntity:entity keys:keys];
  NSManagedObjectID *oid = [self newObjectIDForEntity:entity referenceObject:identifier.data];
  [self rememberETag:payload[@"@odata.etag"] forObjectID:oid];
  // An edit link is sent when writes go somewhere other than the entity's
  // conventional URL (JSON Format section 4.5.8); 4.01 drops the "odata."
  id editLink = payload[@"@odata.editLink"];
  if ([editLink isKindOfClass:[NSString class]]) {
    NSURL *resolved = [NSURL URLWithString:editLink relativeToURL:_client.configuration.serviceRoot].absoluteURL;
    if (resolved) {
      [_lock lock];
      _editLinks[oid] = resolved;
      [_lock unlock];
    }
  }
  return oid;
}

- (NSIncrementalStoreNode *)cacheNodeForObjectID:(NSManagedObjectID *)objectID
                                          entity:(NSEntityDescription *)entity
                                         payload:(NSDictionary *)payload
                                           error:(NSError **)error
{
  (void)error;
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  [entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    // gnustep-base types this block (id, id, BOOL *): no generics to narrow it.
    NSString *name = key;
    NSAttributeDescription *attr = obj;
    (void)stop;
    id raw = payload[[self->_mapper propertyForAttribute:attr]];
    id value = raw ? [self->_mapper.values coreDataValueForJSON:raw attribute:attr] : nil;
    // A value that cannot be this attribute's type (a date that does not
    // parse) is left out rather than stored as the wrong class, and so is
    // null: an attribute that is nil has no value in a node. NSNull there
    // is taken for the value, and a Date attribute holding it crashes.
    if (value && value != [NSNull null]) values[name] = value;
  }];
  // Expanded navigation properties: a to-one's object ID goes in the node,
  // so Core Data need not ask for it; a related entity that came whole is
  // cached in its own right.
  for (NSRelationshipDescription *rel in entity.relationshipsByName.allValues) {
    id inline_ = payload[[_mapper propertyForRelationship:rel]];
    NSEntityDescription *destination = rel.destinationEntity;
    if (!inline_ || !destination) continue;
    if (!rel.isToMany) {
      if (inline_ == [NSNull null]) {
        values[rel.name] = [NSNull null];
      } else if ([inline_ isKindOfClass:[NSDictionary class]]) {
        NSManagedObjectID *related = [self objectIDFromPayload:inline_ entity:destination error:NULL];
        if (!related) continue;
        values[rel.name] = related;
        if ([self payloadIsWhole:inline_ entity:related.entity]) [self cacheNodeForObjectID:related entity:related.entity payload:inline_ error:NULL];
      }
    } else if ([inline_ isKindOfClass:[NSArray class]]) {
      for (NSDictionary *row in inline_) {
        if (![row isKindOfClass:[NSDictionary class]] || ![self payloadIsWhole:row entity:destination]) continue;
        NSManagedObjectID *related = [self objectIDFromPayload:row entity:destination error:NULL];
        if (related) [self cacheNodeForObjectID:related entity:related.entity payload:row error:NULL];
      }
    }
  }
  [self rememberETag:payload[@"@odata.etag"] forObjectID:objectID];
  uint64_t version = [self versionForObjectID:objectID];
  NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:values version:version];
  [_lock lock];
  _nodeCache[objectID] = node;
  [_lock unlock];
  return node;
}

// Whether an inline entity carries more than its key. A key-only one
// ($select=Key) names the entity; caching it would replace a good row
// with an empty one.
- (BOOL)payloadIsWhole:(NSDictionary *)payload entity:(NSEntityDescription *)entity
{
  NSMutableSet *keys = [NSMutableSet set];
  for (NSAttributeDescription *key in [_mapper keyAttributesForEntity:entity]) [keys addObject:key.name];
  for (NSAttributeDescription *attr in entity.attributesByName.allValues) {
    if (![keys containsObject:attr.name] && payload[[_mapper propertyForAttribute:attr]]) return YES;
  }
  return NO;
}

#pragma mark - ETags

// ETags are opaque (Part 1 section 11.4.1.1): kept exactly as the service
// sent them, and sent back unchanged in If-Match. A node's version only has
// to change when the ETag does.
- (void)rememberETag:(id)etag forObjectID:(NSManagedObjectID *)objectID
{
  if (![etag isKindOfClass:[NSString class]] || ![etag length]) return;
  [_lock lock];
  if (![_etags[objectID] isEqualToString:etag]) {
    _etags[objectID] = etag;
    _versions[objectID] = @([_versions[objectID] unsignedLongLongValue] + 1);
  }
  [_lock unlock];
}

- (uint64_t)versionForObjectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  uint64_t version = [_versions[objectID] unsignedLongLongValue];
  [_lock unlock];
  return version ?: 1;
}

// nil when the service has not given one: no If-Match is sent then, rather
// than one the service never issued.
- (NSString *)currentETagForObjectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  NSString *etag = _etags[objectID];
  [_lock unlock];
  return etag;
}

- (void)discardCachedRowsForObjectIDs:(NSArray *)objectIDs
{
  [_lock lock];
  if (objectIDs) [_nodeCache removeObjectsForKeys:objectIDs];
  else [_nodeCache removeAllObjects];
  [_lock unlock];
}

- (void)forgetObjectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  [_nodeCache removeObjectForKey:objectID];
  [_etags removeObjectForKey:objectID];
  [_versions removeObjectForKey:objectID];
  [_deferred removeObjectForKey:objectID];
  [_editLinks removeObjectForKey:objectID];
  [_lock unlock];
}

// Where an object is written: its edit link when the service gave one,
// else its conventional URL. An edit link on the service's own host keeps
// the service root's scheme and port: TripPin, served over HTTPS, writes
// http:// edit links, and a PATCH to one hangs.
- (NSURL *)editURLForObjectID:(NSManagedObjectID *)objectID error:(NSError **)error
{
  [_lock lock];
  NSURL *link = _editLinks[objectID];
  [_lock unlock];
  if (link) {
    NSURL *root = _client.configuration.serviceRoot;
    if ([link.host caseInsensitiveCompare:root.host ?: @""] != NSOrderedSame) return link;
    NSString *s = link.absoluteString;
    NSRange scheme = [s rangeOfString:@"://"];
    NSRange path = [s rangeOfString:@"/" options:0 range:NSMakeRange(NSMaxRange(scheme), s.length - NSMaxRange(scheme))];
    NSString *r = root.absoluteString;
    NSRange rootScheme = [r rangeOfString:@"://"];
    NSRange rootPath = [r rangeOfString:@"/" options:0 range:NSMakeRange(NSMaxRange(rootScheme), r.length - NSMaxRange(rootScheme))];
    if (scheme.location != NSNotFound && path.location != NSNotFound && rootPath.location != NSNotFound) {
      NSURL *rewritten = [NSURL URLWithString:[[r substringToIndex:rootPath.location] stringByAppendingString:[s substringFromIndex:path.location]]];
      if (rewritten) return rewritten;
    }
    return link;
  }
  ODataResourceIdentifier *identifier = [self identifierFromObjectID:objectID error:error];
  return identifier ? [_builder URLForIdentifier:identifier error:error] : nil;
}

- (ODataResourceIdentifier *)identifierFromObjectID:(NSManagedObjectID *)objectID error:(NSError **)error
{
  id ref = [self referenceObjectForObjectID:objectID];
  ODataResourceIdentifier *identifier = [ODataResourceIdentifier identifierFromReference:ref];
  if (!identifier) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, @"Bad reference object");
    return nil;
  }
  return identifier;
}

- (NSDictionary *)clientKeysForObject:(NSManagedObject *)object error:(NSError **)error
{
  NSArray *attrs = [_mapper keyAttributesForEntity:object.entity];
  if (!attrs.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingKey, object.entity.name ?: @"?");
    return nil;
  }
  NSMutableDictionary *keys = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attr in attrs) {
    id value = [object primitiveValueForKey:attr.name];
    if (!value && attr.attributeType == NSUUIDAttributeType) {
      value = [NSUUID UUID];
      [object setPrimitiveValue:value forKey:attr.name];
    }
    value = [self referenceValue:value];
    if (value) keys[[_mapper propertyForAttribute:attr]] = value;
  }
  return keys;
}

// An entity's identifier from its keys by wire name, marking the ones
// whose literal is unquoted.
- (ODataResourceIdentifier *)identifierForEntity:(NSEntityDescription *)entity keys:(NSDictionary *)keys
{
  ODataResourceIdentifier *identifier = [[ODataResourceIdentifier alloc] initWithEntitySet:[_mapper entitySetForEntity:entity] keys:keys];
  NSMutableSet *unquoted = [NSMutableSet set];
  for (NSAttributeDescription *attr in [_mapper keyAttributesForEntity:entity]) {
    switch ([_mapper.values edmTypeOfAttribute:attr]) {
      case ODataEdmGuid:
      case ODataEdmDateTimeOffset:
      case ODataEdmDate:
      case ODataEdmTimeOfDay:
        [unquoted addObject:[_mapper propertyForAttribute:attr]];
        break;
      default:
        break;
    }
  }
  identifier.unquotedKeys = unquoted;
  return identifier;
}

// A key as it goes into an object ID's reference object, which is JSON:
// numbers and strings as they are, anything else in its OData form.
- (id)referenceValue:(id)value
{
  if (!value || [value isKindOfClass:[NSNumber class]] || [value isKindOfClass:[NSString class]]) return value;
  if ([value isKindOfClass:[NSUUID class]]) return [value UUIDString];
  if ([value isKindOfClass:[NSDate class]]) return ODataDateTimeOffsetString(value);
  if ([value isKindOfClass:[NSData class]]) return ODataBase64URLString(value);
  return [value description];
}

- (NSEntityDescription *)resolvedEntity:(NSFetchRequest *)fetch
{
  if (fetch.entity) return fetch.entity;
  if (fetch.entityName) return self.persistentStoreCoordinator.managedObjectModel.entitiesByName[fetch.entityName];
  return nil;
}

@end
