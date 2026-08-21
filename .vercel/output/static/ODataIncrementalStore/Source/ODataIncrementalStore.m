// ODataIncrementalStore
// Copyright (C) 2026 OIS contributors
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.

#import "ODataIncrementalStore.h"

@implementation ODataIncrementalStore {
  ODataClient *_client;
  ODataPropertyMapper *_mapper;
  ODataQueryBuilder *_builder;
  NSMutableDictionary *_nodeCache;
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

- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root
                                 configurationName:(NSString *)name
                                               URL:(NSURL *)url
                                           options:(NSDictionary *)options
{
  self = [super initWithPersistentStoreCoordinator:root configurationName:name URL:url options:options];
  if (!self) return nil;
  _nodeCache = [NSMutableDictionary dictionary];
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
  _mapper = [[ODataPropertyMapper alloc] init];
  _mapper.naming = configuration.naming;
  _builder = [[ODataQueryBuilder alloc] initWithMapper:_mapper serviceRoot:configuration.serviceRoot];
  if (![ _client metadataWithError:error]) return NO;
  NSString *uuid = [NSIncrementalStore identifierForNewStoreAtURL:url];
  if (![uuid isKindOfClass:[NSString class]]) uuid = [[NSUUID UUID] UUIDString];
  self.metadata = @{ NSStoreUUIDKey: uuid, NSStoreTypeKey: [[self class] storeType] };
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
  NSURL *url = [_builder URLForIdentifier:identifier error:error];
  if (!url) return nil;
  id json = [_client JSONAtURL:url error:error];
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
  id json = [_client JSONAtURL:url error:error];
  NSEntityDescription *destination = relationship.destinationEntity;
  if (!destination) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingEntitySet, relationship.name);
    return nil;
  }
  if (relationship.isToMany) {
    NSArray *values = [json isKindOfClass:[NSDictionary class]] ? json[@"value"] : nil;
    if (![values isKindOfClass:[NSArray class]]) values = @[];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *row in values) {
      if (![row isKindOfClass:[NSDictionary class]]) continue;
      NSManagedObjectID *oid = [self objectIDFromPayload:row entity:destination error:error];
      if (!oid) return nil;
      [ids addObject:oid];
    }
    return ids;
  }
  if (json == [NSNull null] || ![json isKindOfClass:[NSDictionary class]]) return [NSNull null];
  return [self objectIDFromPayload:json entity:destination error:error];
}

- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error
{
  NSMutableArray *ids = [NSMutableArray array];
  for (NSManagedObject *object in array) {
    NSEntityDescription *entity = object.entity;
    if (_client.configuration.postOnObtainPermanentIDs) {
      NSDictionary *body = [self representationOfObject:object includingKeys:NO];
      NSString *set = [_mapper entitySetForEntity:entity];
      NSURL *url = [_client.configuration.serviceRoot URLByAppendingPathComponent:set];
      ODataHTTPResponse *response = [_client sendJSONMethod:@"POST" URL:url body:body etag:nil error:error];
      if (!response) return nil;
      id json = [NSJSONSerialization JSONObjectWithData:response.data options:0 error:nil];
      if (![json isKindOfClass:[NSDictionary class]]) {
        if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"POST %@ did not return an entity", set]);
        return nil;
      }
      NSManagedObjectID *oid = [self objectIDFromPayload:json entity:entity error:error];
      if (!oid) return nil;
      [self cacheNodeForObjectID:oid entity:entity payload:json error:nil];
      [ids addObject:oid];
    } else {
      NSDictionary *keys = [self clientKeysForObject:object error:error];
      if (!keys) return nil;
      ODataResourceIdentifier *identifier = [[ODataResourceIdentifier alloc] initWithEntitySet:[_mapper entitySetForEntity:entity] keys:keys];
      [ids addObject:[self newObjectIDForEntity:entity referenceObject:identifier.data]];
    }
  }
  return ids;
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

  id json = [_client JSONAtURL:url error:error];
  NSArray *rows = nil;
  if ([json isKindOfClass:[NSDictionary class]] && [json[@"value"] isKindOfClass:[NSArray class]]) {
    rows = json[@"value"];
  } else if ([json isKindOfClass:[NSDictionary class]]) {
    rows = @[ json ];
  } else {
    rows = @[];
  }

  if (fetch.resultType == NSDictionaryResultType) {
    NSMutableArray *dicts = [NSMutableArray array];
    for (NSDictionary *row in rows) {
      [dicts addObject:[self dictionaryFromPayload:row entity:entity properties:fetch.propertiesToFetch]];
    }
    return dicts;
  }

  NSMutableArray *objectIDs = [NSMutableArray array];
  BOOL materialize = (fetch.returnsObjectsAsFaults == NO) || (fetch.relationshipKeyPathsForPrefetching.count > 0);
  for (NSDictionary *row in rows) {
    if (![row isKindOfClass:[NSDictionary class]]) continue;
    NSManagedObjectID *oid = [self objectIDFromPayload:row entity:entity error:error];
    if (!oid) return nil;
    if (materialize) [self cacheNodeForObjectID:oid entity:entity payload:row error:nil];
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

- (id)executeSave:(NSSaveChangesRequest *)save error:(NSError **)error
{
  for (NSManagedObject *object in save.insertedObjects) {
    if (!_client.configuration.postOnObtainPermanentIDs) {
      if (![self upsert:object method:@"POST" etag:nil error:error]) return nil;
    }
  }
  for (NSManagedObject *object in save.updatedObjects) {
    if (![self upsert:object method:@"PATCH" etag:[self currentETagForObjectID:object.objectID] error:error]) return nil;
  }
  for (NSManagedObject *object in save.deletedObjects) {
    ODataResourceIdentifier *identifier = [self identifierFromObjectID:object.objectID error:error];
    if (!identifier) return nil;
    NSURL *url = [_builder URLForIdentifier:identifier error:error];
    if (!url) return nil;
    if (![_client sendJSONMethod:@"DELETE" URL:url body:nil etag:[self currentETagForObjectID:object.objectID] error:error]) {
      return nil;
    }
    [_lock lock];
    [_nodeCache removeObjectForKey:object.objectID];
    [_lock unlock];
  }
  return @[];
}

- (BOOL)upsert:(NSManagedObject *)object method:(NSString *)method etag:(NSString *)etag error:(NSError **)error
{
  ODataResourceIdentifier *identifier = [self identifierFromObjectID:object.objectID error:error];
  if (!identifier) return NO;
  NSURL *url = [_builder URLForIdentifier:identifier error:error];
  if (!url) return NO;
  NSDictionary *body = [self representationOfObject:object includingKeys:[method isEqualToString:@"POST"]];
  ODataHTTPResponse *response = [_client sendJSONMethod:method URL:url body:body etag:etag error:error];
  if (!response) return NO;
  if (response.status != 204) {
    id json = [NSJSONSerialization JSONObjectWithData:response.data options:0 error:nil];
    if ([json isKindOfClass:[NSDictionary class]]) {
      [self cacheNodeForObjectID:object.objectID entity:object.entity payload:json error:nil];
    }
  } else {
    [_lock lock];
    [_nodeCache removeObjectForKey:object.objectID];
    [_lock unlock];
  }
  return YES;
}

#pragma mark - Mapping

- (NSDictionary *)representationOfObject:(NSManagedObject *)object includingKeys:(BOOL)includingKeys
{
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  NSMutableSet *keyNames = [NSMutableSet set];
  for (NSAttributeDescription *attr in [_mapper keyAttributesForEntity:object.entity]) {
    [keyNames addObject:attr.name];
  }
  NSDictionary *changed = [object changedValues];
  [object.entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSAttributeDescription *attr, BOOL *stop) {
    (void)stop;
    if (!includingKeys && [keyNames containsObject:name]) return;
    if (!changed[name] && !object.isInserted) return;
    body[[self->_mapper propertyForAttribute:attr]] = [self odataJSON:[object primitiveValueForKey:name]];
  }];
  if (object.isInserted) {
    [object.entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSAttributeDescription *attr, BOOL *stop) {
      (void)name; (void)stop;
      NSString *wire = [self->_mapper propertyForAttribute:attr];
      if (!body[wire]) body[wire] = [self odataJSON:[object primitiveValueForKey:name]];
    }];
  }
  return body;
}

- (id)odataJSON:(id)value
{
  if (!value || value == [NSNull null]) return [NSNull null];
  if ([value isKindOfClass:[NSDate class]]) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return [f stringFromDate:value];
  }
  if ([value isKindOfClass:[NSUUID class]]) return [value UUIDString];
  if ([value isKindOfClass:[NSDecimalNumber class]]) return value;
  return value;
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
    id value = payload[[_mapper propertyForAttribute:attr]];
    if (value) out[name] = value;
  }
  return out;
}

- (NSManagedObjectID *)objectIDFromPayload:(NSDictionary *)payload
                                    entity:(NSEntityDescription *)entity
                                     error:(NSError **)error
{
  NSArray *keyAttrs = [_mapper keyAttributesForEntity:entity];
  if (!keyAttrs.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingKey, entity.name ?: @"?");
    return nil;
  }
  NSMutableDictionary *keys = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attr in keyAttrs) {
    NSString *wire = [_mapper propertyForAttribute:attr];
    id value = payload[wire] ?: payload[attr.name];
    if (!value) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Missing key %@", wire]);
      return nil;
    }
    keys[wire] = value;
  }
  ODataResourceIdentifier *identifier = [[ODataResourceIdentifier alloc] initWithEntitySet:[_mapper entitySetForEntity:entity] keys:keys];
  return [self newObjectIDForEntity:entity referenceObject:identifier.data];
}

- (NSIncrementalStoreNode *)cacheNodeForObjectID:(NSManagedObjectID *)objectID
                                          entity:(NSEntityDescription *)entity
                                         payload:(NSDictionary *)payload
                                           error:(NSError **)error
{
  (void)error;
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  [entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSAttributeDescription *attr, BOOL *stop) {
    (void)stop;
    id raw = payload[[self->_mapper propertyForAttribute:attr]];
    if (raw) values[name] = [self coerce:raw attribute:attr];
  }];
  uint64_t version = [self versionFromETag:payload[@"@odata.etag"]];
  NSIncrementalStoreNode *node = [[NSIncrementalStoreNode alloc] initWithObjectID:objectID withValues:values version:version];
  [_lock lock];
  _nodeCache[objectID] = node;
  [_lock unlock];
  return node;
}

- (id)coerce:(id)raw attribute:(NSAttributeDescription *)attribute
{
  if (raw == [NSNull null]) return [NSNull null];
  switch (attribute.attributeType) {
    case NSDateAttributeType:
      if ([raw isKindOfClass:[NSString class]]) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        NSDate *d = [f dateFromString:raw];
        return d ?: raw;
      }
      return raw;
    case NSBooleanAttributeType:
      if ([raw isKindOfClass:[NSNumber class]]) return @([raw boolValue]);
      return raw;
    case NSDecimalAttributeType:
      if ([raw isKindOfClass:[NSNumber class]]) return [NSDecimalNumber decimalNumberWithDecimal:[raw decimalValue]];
      return raw;
    default:
      if (attribute.attributeType == NSUUIDAttributeType && [raw isKindOfClass:[NSString class]]) {
        NSUUID *u = [[NSUUID alloc] initWithUUIDString:raw];
        return u ?: raw;
      }
      return raw;
  }
}

- (uint64_t)versionFromETag:(NSString *)etag
{
  if (!etag.length) return 1;
  NSMutableString *digits = [NSMutableString string];
  for (NSUInteger i = 0; i < etag.length; i++) {
    unichar c = [etag characterAtIndex:i];
    if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
  }
  if (digits.length) return (uint64_t)[digits longLongValue];
  return (uint64_t)(etag.hash & 0x7fffffff);
}

- (NSString *)currentETagForObjectID:(NSManagedObjectID *)objectID
{
  [_lock lock];
  NSIncrementalStoreNode *node = _nodeCache[objectID];
  uint64_t version = node.version;
  [_lock unlock];
  if (!node) return nil;
  return [NSString stringWithFormat:@"W/\"%llu\"", (unsigned long long)version];
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
    if (value) {
      keys[[_mapper propertyForAttribute:attr]] = value;
    } else if (attr.attributeType == NSUUIDAttributeType) {
      NSUUID *uuid = [NSUUID UUID];
      [object setPrimitiveValue:uuid forKey:attr.name];
      keys[[_mapper propertyForAttribute:attr]] = uuid;
    }
  }
  return keys;
}

- (NSEntityDescription *)resolvedEntity:(NSFetchRequest *)fetch
{
  if (fetch.entity) return fetch.entity;
  if (fetch.entityName) return self.persistentStoreCoordinator.managedObjectModel.entitiesByName[fetch.entityName];
  return nil;
}

@end
