// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"
#import <ODataKit/ODataExpression.h>
#import <ODataService/ODataService.h>
#import <objc/message.h>

NSString * const ODataSyncDirectionKey = @"ODataSync.direction";
NSString * const ODataSyncErrorDomain = @"org.gnu.ois.ODataSync";
NSString * const ODataSyncDownAuthorPrefix = @"ODataSync.down.";
NSString * const ODataSyncBookkeepingAuthor = @"ODataSync.bookkeeping";
NSString * const ODataSyncReplicaHeader = @"ODataSync-Replica";
NSString * const ODataSyncPeerConfiguration = @"ODataSync.peer";

NSString * const ODSRemoteStateEntity = @"ODSRemoteState";
NSString * const ODSOutboxEntity = @"ODSOutboxEntry";
NSString * const ODSShadowEntity = @"ODSShadow";
NSString * const ODSTombstoneEntity = @"ODSTombstone";

NSError *ODSError(NSInteger code, NSString *message)
{
  return [NSError errorWithDomain:ODataSyncErrorDomain code:code userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}

NSData *ODSArchive(id plist)
{
  if (!plist) return nil;
  return [NSKeyedArchiver archivedDataWithRootObject:plist requiringSecureCoding:NO error:NULL];
}

id ODSUnarchive(NSData *data)
{
  if (!data.length) return nil;
  NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], [NSNumber class], [NSDate class],
                                         [NSUUID class], [NSDecimalNumber class], [NSData class], [NSNull class], [NSSet class], nil];
  return [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:data error:NULL];
}

#pragma mark - Remote

@implementation ODataSyncRemote

+ (instancetype)remoteWithServiceRoot:(NSURL *)serviceRoot
{
  return [[self alloc] initWithServiceRoot:serviceRoot];
}

+ (instancetype)peerWithServiceRoot:(NSURL *)serviceRoot
{
  ODataSyncRemote *remote = [[self alloc] initWithServiceRoot:serviceRoot];
  remote->_peer = YES;
  NSString *replica = serviceRoot.path.lastPathComponent;
  if (replica.length) remote.identifier = replica;
  return remote;
}

- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [serviceRoot copy];
  _identifier = [serviceRoot.absoluteString copy];
  _configuration = [[ODataConfiguration alloc] initWithURL:serviceRoot options:nil];
  _filters = @{};
  _batchSize = 50;
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncRemote %@%@>", _peer ? @"peer " : @"", _identifier];
}

@end

#pragma mark - Issues, results

@implementation ODataSyncChange

- (instancetype)initWithEntry:(NSManagedObject *)entry objectID:(NSManagedObjectID *)objectID
{
  self = [super init];
  if (!self) return nil;
  _entryID = entry.objectID;
  _remoteIdentifier = [entry valueForKey:@"remote"] ?: @"";
  _entityName = [entry valueForKey:@"entityType"] ?: @"";
  _key = ODSUnarchive([entry valueForKey:@"key"]) ?: @{};
  _operation = [[entry valueForKey:@"operation"] integerValue];
  _properties = ODSUnarchive([entry valueForKey:@"properties"]);
  _attempts = [[entry valueForKey:@"attempts"] integerValue];
  _objectID = objectID;
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncChange %@ %@ %ld>", _entityName, _key, (long)_operation];
}

@end

@implementation ODataSyncIssue

- (instancetype)initWithEntry:(NSManagedObject *)entry objectID:(NSManagedObjectID *)objectID
{
  self = [super initWithEntry:entry objectID:objectID];
  if (!self) return nil;
  _status = [[entry valueForKey:@"status"] integerValue];
  _message = [entry valueForKey:@"message"] ?: @"";
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncIssue %@ %@ %ld: %@>", self.entityName, self.key, (long)_status, _message];
}

@end

@implementation ODataSyncResult

- (instancetype)initWithTally:(NSDictionary<NSString *, NSNumber *> *)tally
{
  self = [super init];
  if (!self) return nil;
  _downloaded = [tally[@"downloaded"] unsignedIntegerValue];
  _removed = [tally[@"removed"] unsignedIntegerValue];
  _uploaded = [tally[@"uploaded"] unsignedIntegerValue];
  _refused = [tally[@"refused"] unsignedIntegerValue];
  _conflicts = [tally[@"conflicts"] unsignedIntegerValue];
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncResult down %lu, removed %lu, up %lu, refused %lu, conflicts %lu>",
                                    (unsigned long)_downloaded, (unsigned long)_removed, (unsigned long)_uploaded,
                                    (unsigned long)_refused, (unsigned long)_conflicts];
}

@end

#pragma mark - Codec

@implementation ODSCodec {
  NSMutableDictionary<NSString *, NSArray *> *_attributes;
  NSMutableDictionary<NSString *, NSArray *> *_toOnes;
}

- (instancetype)initWithModel:(NSManagedObjectModel *)model
{
  self = [super init];
  if (!self) return nil;
  _model = model;
  _mapper = [[ODataPropertyMapper alloc] init];
  _attributes = [NSMutableDictionary dictionary];
  _toOnes = [NSMutableDictionary dictionary];
  return self;
}

- (NSEntityDescription *)rootOf:(NSEntityDescription *)entity
{
  while (entity.superentity) entity = entity.superentity;
  return entity;
}

- (ODataSyncDirection)directionOfEntity:(NSEntityDescription *)entity
{
  for (NSEntityDescription *e = entity; e; e = e.superentity) {
    NSString *direction = [e.userInfo[ODataSyncDirectionKey] lowercaseString];
    if ([direction isEqualToString:@"down"]) return ODataSyncDirectionDown;
    if ([direction isEqualToString:@"up"]) return ODataSyncDirectionUp;
    if ([direction isEqualToString:@"both"]) return ODataSyncDirectionBoth;
  }
  return ODataSyncDirectionNone;
}

- (ODataSyncDirection)directionOfEntity:(NSEntityDescription *)entity toward:(ODataSyncRemote *)remote
{
  ODataSyncDirection direction = [self directionOfEntity:entity];
  return remote.peer && direction == ODataSyncDirectionUp ? ODataSyncDirectionBoth : direction;
}

- (NSArray<NSEntityDescription *> *)rootEntitiesGoing:(NSSet<NSNumber *> *)directions toward:(ODataSyncRemote *)remote
{
  NSMutableArray *roots = [NSMutableArray array];
  for (NSEntityDescription *entity in [self.model.entities sortedArrayUsingComparator:^NSComparisonResult(NSEntityDescription *a, NSEntityDescription *b) {
         return [a.name compare:b.name];
       }]) {
    if (entity.superentity || ![directions containsObject:@([self directionOfEntity:entity toward:remote])]) continue;
    if (![self.mapper keyAttributesForEntity:entity].count) continue;
    [roots addObject:entity];
  }
  // Parents first: depth-first, an entity after the destinations of its to-ones.
  NSMutableArray *ordered = [NSMutableArray array];
  NSMutableSet *visiting = [NSMutableSet set];
  __block void (^visit)(NSEntityDescription *);
  __weak __block void (^weakVisit)(NSEntityDescription *);
  weakVisit = visit = ^(NSEntityDescription *entity) {
    if ([ordered containsObject:entity] || [visiting containsObject:entity.name]) return;
    [visiting addObject:entity.name];
    for (NSRelationshipDescription *toOne in [self toOnesOf:entity]) {
      NSEntityDescription *destination = [self rootOf:toOne.destinationEntity];
      if ([roots containsObject:destination]) weakVisit(destination);
    }
    [ordered addObject:entity];
  };
  for (NSEntityDescription *entity in roots) visit(entity);
  return ordered;
}

- (NSArray<NSAttributeDescription *> *)attributesOf:(NSEntityDescription *)entity
{
  NSArray *known = _attributes[entity.name];
  if (known) return known;
  NSMutableArray *attributes = [NSMutableArray array];
  NSAttributeDescription *bag = [self.mapper dynamicPropertiesAttributeOfEntity:entity];
  for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attribute = entity.attributesByName[name];
    if (attribute.isTransient || attribute == bag || ![self.mapper servesProperty:attribute]) continue;
    [attributes addObject:attribute];
  }
  _attributes[entity.name] = attributes;
  return attributes;
}

- (NSArray<NSRelationshipDescription *> *)toOnesOf:(NSEntityDescription *)entity
{
  NSArray *known = _toOnes[entity.name];
  if (known) return known;
  NSMutableArray *toOnes = [NSMutableArray array];
  for (NSString *name in [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSRelationshipDescription *relationship = entity.relationshipsByName[name];
    if (relationship.isToMany || relationship.isTransient || !relationship.destinationEntity) continue;
    if ([self directionOfEntity:relationship.destinationEntity] == ODataSyncDirectionNone) continue;
    if (![self.mapper servesProperty:relationship]) continue;
    [toOnes addObject:relationship];
  }
  _toOnes[entity.name] = toOnes;
  return toOnes;
}

- (NSArray<NSAttributeDescription *> *)keyAttributesOf:(NSEntityDescription *)entity
{
  return [self.mapper keyAttributesForEntity:[self rootOf:entity]];
}

- (NSDictionary *)keyOfObject:(NSManagedObject *)object
{
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self keyAttributesOf:object.entity]) {
    id value = [object valueForKey:attribute.name];
    if (value) key[attribute.name] = value;
  }
  return key;
}

- (NSDictionary *)keyFromJSON:(NSDictionary *)json entity:(NSEntityDescription *)entity
{
  if (![json isKindOfClass:[NSDictionary class]]) return nil;
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self keyAttributesOf:entity]) {
    id raw = json[[self.mapper propertyForAttribute:attribute]];
    id value = raw && raw != [NSNull null] ? [self.mapper.values coreDataValueForJSON:raw attribute:attribute] : nil;
    if (!value) return nil;
    key[attribute.name] = value;
  }
  return key;
}

- (NSDictionary *)keyFromValues:(NSDictionary *)values entity:(NSEntityDescription *)entity
{
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self keyAttributesOf:entity]) {
    id value = values[attribute.name];
    if (!value || value == [NSNull null]) return nil;
    key[attribute.name] = value;
  }
  return key;
}

- (NSDictionary *)keyFromID:(NSString *)identifier entity:(NSEntityDescription **)found among:(NSArray<NSEntityDescription *> *)entities
{
  NSString *text = [identifier stringByRemovingPercentEncoding] ?: identifier;
  // A whole URL: from the entity set's name on.
  for (NSEntityDescription *entity in entities) {
    NSString *set = [self.mapper entitySetForEntity:entity];
    NSRange at = [text rangeOfString:[NSString stringWithFormat:@"/%@(", set] options:NSBackwardsSearch];
    if (at.location != NSNotFound) {
      text = [text substringFromIndex:at.location + 1];
      break;
    }
  }
  ODataResourcePath *path = [ODataResourcePath pathWithString:text error:NULL];
  ODataPathSegment *segment = path.segments.firstObject;
  if (!segment.keys) return nil;
  NSEntityDescription *entity = nil;
  for (NSEntityDescription *candidate in entities) {
    if ([[self.mapper entitySetForEntity:candidate] isEqualToString:segment.name]) entity = candidate;
  }
  if (!entity) return nil;
  NSArray<NSAttributeDescription *> *attributes = [self keyAttributesOf:entity];
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in attributes) {
    ODataExpression *part = segment.keys[[self.mapper propertyForAttribute:attribute]];
    if (!part && attributes.count == 1) part = segment.keys[@""];
    id value = part.value ? [self.mapper.values coreDataValueForJSON:part.value attribute:attribute] : nil;
    if (!value) return nil;
    key[attribute.name] = value;
  }
  if (found) *found = entity;
  return key;
}

- (NSString *)keyTextOf:(NSDictionary *)key entity:(NSEntityDescription *)entity
{
  NSMutableArray *parts = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self keyAttributesOf:entity]) {
    [parts addObject:[NSString stringWithFormat:@"%@=%@", attribute.name, [self.mapper.values literalForValue:key[attribute.name] attribute:attribute]]];
  }
  return [parts componentsJoinedByString:@","];
}

- (NSString *)pathOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key
{
  NSArray<NSAttributeDescription *> *attributes = [self keyAttributesOf:entity];
  NSMutableArray *parts = [NSMutableArray array];
  for (NSAttributeDescription *attribute in attributes) {
    NSString *literal = [self.mapper.values literalForValue:key[attribute.name] attribute:attribute];
    [parts addObject:attributes.count == 1 ? literal
                                           : [NSString stringWithFormat:@"%@=%@", [self.mapper propertyForAttribute:attribute], literal]];
  }
  return [NSString stringWithFormat:@"%@(%@)", [self.mapper entitySetForEntity:[self rootOf:entity]], [parts componentsJoinedByString:@","]];
}

- (NSManagedObject *)objectOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key inContext:(NSManagedObjectContext *)context
{
  NSEntityDescription *root = [self rootOf:entity];
  NSMutableArray *conditions = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self keyAttributesOf:root]) {
    if (!key[attribute.name]) return nil;
    [conditions addObject:[NSPredicate predicateWithFormat:@"%K == %@", attribute.name, key[attribute.name]]];
  }
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:root.name];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:conditions];
  fetch.includesSubentities = YES;
  fetch.fetchLimit = 1;
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

static BOOL ODSSame(id a, id b)
{
  return a == b || [a isEqual:b];
}

- (void)applyJSON:(NSDictionary *)json toObject:(NSManagedObject *)object
{
  ODataValueCoder *values = self.mapper.values;
  for (NSAttributeDescription *attribute in [self attributesOf:object.entity]) {
    id raw = json[[self.mapper propertyForAttribute:attribute]];
    if (!raw) continue;
    id value = raw == [NSNull null] ? nil : [values coreDataValueForJSON:raw attribute:attribute];
    // Set only what differs: an unchanged value is no change in history.
    if (!ODSSame([object valueForKey:attribute.name], value)) [object setValue:value forKey:attribute.name];
  }
  for (NSRelationshipDescription *toOne in [self toOnesOf:object.entity]) {
    id raw = json[[self.mapper propertyForRelationship:toOne]];
    if (!raw) continue;
    NSManagedObject *related = nil;
    if ([raw isKindOfClass:[NSDictionary class]]) {
      NSDictionary *key = [self keyFromJSON:raw entity:toOne.destinationEntity];
      related = key ? [self objectOfEntity:toOne.destinationEntity key:key inContext:object.managedObjectContext] : nil;
    }
    if ([object valueForKey:toOne.name] != related) [object setValue:related forKey:toOne.name];
  }
}

- (NSDictionary *)JSONOfObject:(NSManagedObject *)object properties:(NSSet<NSString *> *)properties
{
  ODataValueCoder *values = self.mapper.values;
  NSMutableDictionary *json = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self attributesOf:object.entity]) {
    if (properties && ![properties containsObject:attribute.name]) continue;
    if ([self.mapper attributeIsComputed:attribute]) continue;
    id value = [object valueForKey:attribute.name];
    json[[self.mapper propertyForAttribute:attribute]] = value ? [values JSONForCoreDataValue:value attribute:attribute] : [NSNull null];
  }
  for (NSRelationshipDescription *toOne in [self toOnesOf:object.entity]) {
    if (properties && ![properties containsObject:toOne.name]) continue;
    NSManagedObject *related = [object valueForKey:toOne.name];
    NSString *name = [self.mapper propertyForRelationship:toOne];
    if (related) {
      json[[name stringByAppendingString:@"@odata.bind"]] = [self pathOfEntity:related.entity key:[self keyOfObject:related]];
    } else if (properties) {
      json[name] = [NSNull null];  // unlinked (a deep update's null)
    }
  }
  return json;
}

- (NSDictionary *)valuesOfObject:(NSManagedObject *)object
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self attributesOf:object.entity]) {
    values[attribute.name] = [object valueForKey:attribute.name] ?: [NSNull null];
  }
  for (NSRelationshipDescription *toOne in [self toOnesOf:object.entity]) {
    NSManagedObject *related = [object valueForKey:toOne.name];
    values[toOne.name] = related ? [self keyOfObject:related] : [NSNull null];
  }
  return values;
}

- (NSDictionary *)valuesFromJSON:(NSDictionary *)json entity:(NSEntityDescription *)entity
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self attributesOf:entity]) {
    id raw = json[[self.mapper propertyForAttribute:attribute]];
    if (!raw) continue;
    id value = raw == [NSNull null] ? nil : [self.mapper.values coreDataValueForJSON:raw attribute:attribute];
    values[attribute.name] = value ?: [NSNull null];
  }
  for (NSRelationshipDescription *toOne in [self toOnesOf:entity]) {
    id raw = json[[self.mapper propertyForRelationship:toOne]];
    if (!raw) continue;
    NSDictionary *key = [raw isKindOfClass:[NSDictionary class]] ? [self keyFromJSON:raw entity:toOne.destinationEntity] : nil;
    values[toOne.name] = key ?: [NSNull null];
  }
  return values;
}

- (void)applyValues:(NSDictionary *)values toObject:(NSManagedObject *)object
{
  for (NSAttributeDescription *attribute in [self attributesOf:object.entity]) {
    id value = values[attribute.name];
    if (!value) continue;
    if (value == [NSNull null]) value = nil;
    if (!ODSSame([object valueForKey:attribute.name], value)) [object setValue:value forKey:attribute.name];
  }
  for (NSRelationshipDescription *toOne in [self toOnesOf:object.entity]) {
    id key = values[toOne.name];
    if (!key) continue;
    NSManagedObject *related = [key isKindOfClass:[NSDictionary class]]
        ? [self objectOfEntity:toOne.destinationEntity key:key inContext:object.managedObjectContext] : nil;
    if ([object valueForKey:toOne.name] != related) [object setValue:related forKey:toOne.name];
  }
}

- (NSDictionary *)rowOfObject:(NSManagedObject *)object
{
  ODataValueCoder *coder = self.mapper.values;
  NSMutableDictionary *row = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in [self attributesOf:object.entity]) {
    id value = [object valueForKey:attribute.name];
    row[[self.mapper propertyForAttribute:attribute]] = value ? [coder JSONForCoreDataValue:value attribute:attribute] : [NSNull null];
  }
  for (NSRelationshipDescription *toOne in [self toOnesOf:object.entity]) {
    NSManagedObject *related = [object valueForKey:toOne.name];
    NSMutableDictionary *key = related ? [NSMutableDictionary dictionary] : nil;
    for (NSAttributeDescription *attribute in related ? [self keyAttributesOf:related.entity] : @[]) {
      key[[self.mapper propertyForAttribute:attribute]] = [coder JSONForCoreDataValue:[related valueForKey:attribute.name] attribute:attribute];
    }
    row[[self.mapper propertyForRelationship:toOne]] = key ?: [NSNull null];
  }
  return row;
}

NSSet<NSString *> *ODSChangedNames(NSDictionary *before, NSDictionary *after)
{
  NSMutableSet *names = [NSMutableSet setWithArray:before.allKeys ?: @[]];
  [names addObjectsFromArray:after.allKeys ?: @[]];
  NSMutableSet *changed = [NSMutableSet set];
  for (NSString *name in names) {
    id a = before[name] ?: [NSNull null], b = after[name] ?: [NSNull null];
    if (!ODSSame(a, b)) [changed addObject:name];
  }
  return changed;
}

- (NSAttributeDescription *)versionAttributeOf:(NSEntityDescription *)entity
{
  for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
    id flag = attribute.userInfo[ODataUserInfoETag];
    if (!([flag isEqual:@"YES"] || [flag isEqual:@YES])) continue;
    switch (attribute.attributeType) {
      case NSInteger16AttributeType:
      case NSInteger32AttributeType:
      case NSInteger64AttributeType:
        return attribute;
      default:
        return nil;
    }
  }
  return nil;
}

- (NSAttributeDescription *)modifiedAttributeOf:(NSEntityDescription *)entity
{
  for (NSEntityDescription *e = entity; e; e = e.superentity) {
    NSString *name = e.userInfo[ODataSyncModifiedKey];
    if (name) {
      NSAttributeDescription *attribute = entity.attributesByName[name];
      return attribute.attributeType == NSStringAttributeType ? attribute : nil;
    }
  }
  return nil;
}

- (NSString *)expandOfEntity:(NSEntityDescription *)entity
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSRelationshipDescription *toOne in [self toOnesOf:entity]) {
    [items addObject:[NSString stringWithFormat:@"%@($select=%@)", [self.mapper propertyForRelationship:toOne],
                                                [self selectOfKeyOfEntity:toOne.destinationEntity]]];
  }
  return items.count ? [items componentsJoinedByString:@","] : nil;
}

- (NSString *)selectOfKeyOfEntity:(NSEntityDescription *)entity
{
  NSMutableArray *names = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self keyAttributesOf:entity]) [names addObject:[self.mapper propertyForAttribute:attribute]];
  return [names componentsJoinedByString:@","];
}

- (NSString *)filterOfKeys:(NSArray<NSDictionary *> *)keys entity:(NSEntityDescription *)entity
{
  NSArray<NSAttributeDescription *> *attributes = [self keyAttributesOf:entity];
  NSMutableArray *alternatives = [NSMutableArray array];
  for (NSDictionary *key in keys) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSAttributeDescription *attribute in attributes) {
      [parts addObject:[NSString stringWithFormat:@"%@ eq %@", [self.mapper propertyForAttribute:attribute],
                                                  [self.mapper.values literalForValue:key[attribute.name] attribute:attribute]]];
    }
    NSString *all = [parts componentsJoinedByString:@" and "];
    [alternatives addObject:parts.count > 1 ? [NSString stringWithFormat:@"(%@)", all] : all];
  }
  return [alternatives componentsJoinedByString:@" or "];
}

@end

#pragma mark - Engine

static NSAttributeDescription *ODSAttribute(NSString *name, NSAttributeType type)
{
  NSAttributeDescription *attribute = [[NSAttributeDescription alloc] init];
  attribute.name = name;
  attribute.attributeType = type;
  attribute.optional = YES;
  // A flag or a count is NO or 0, never NULL (which a predicate's != YES
  // does not take).
  if (type == NSBooleanAttributeType) attribute.defaultValue = @NO;
  if (type == NSInteger16AttributeType || type == NSInteger32AttributeType || type == NSInteger64AttributeType) attribute.defaultValue = @0;
  return attribute;
}

static NSEntityDescription *ODSEntity(NSString *name, NSArray<NSAttributeDescription *> *attributes)
{
  NSEntityDescription *entity = [[NSEntityDescription alloc] init];
  entity.name = name;
  entity.managedObjectClassName = NSStringFromClass([NSManagedObject class]);
  entity.properties = attributes;
  return entity;
}

@implementation ODataSyncEngine {
  NSMutableArray<ODataSyncRemote *> *_remotes;
  NSLock *_running;
  NSMutableDictionary<NSString *, NSNumber *> *_tally;
  NSMutableDictionary<NSString *, id<ODataSyncResolving>> *_resolvers;
  NSString *_replicaID;
  // The hybrid logical clock: the latest wall time (ms) and its counter.
  int64_t _clockTime;
  int32_t _clockCounter;
}

+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(NSString *)configuration
{
  if (model.entitiesByName[ODSRemoteStateEntity]) return;
  NSArray *added = @[
    ODSEntity(ODSRemoteStateEntity, @[ ODSAttribute(@"remote", NSStringAttributeType), ODSAttribute(@"deltaLinks", NSBinaryDataAttributeType),
                                       ODSAttribute(@"filters", NSBinaryDataAttributeType), ODSAttribute(@"historyToken", NSBinaryDataAttributeType) ]),
    ODSEntity(ODSOutboxEntity, @[ ODSAttribute(@"remote", NSStringAttributeType), ODSAttribute(@"entityType", NSStringAttributeType),
                                  ODSAttribute(@"key", NSBinaryDataAttributeType), ODSAttribute(@"keyText", NSStringAttributeType),
                                  ODSAttribute(@"operation", NSInteger16AttributeType), ODSAttribute(@"properties", NSBinaryDataAttributeType),
                                  ODSAttribute(@"sequence", NSInteger64AttributeType), ODSAttribute(@"attempts", NSInteger32AttributeType),
                                  ODSAttribute(@"status", NSInteger32AttributeType), ODSAttribute(@"message", NSStringAttributeType),
                                  ODSAttribute(@"setAside", NSBooleanAttributeType), ODSAttribute(@"relayed", NSBooleanAttributeType) ]),
    ODSEntity(ODSShadowEntity, @[ ODSAttribute(@"remote", NSStringAttributeType), ODSAttribute(@"entityType", NSStringAttributeType),
                                  ODSAttribute(@"keyText", NSStringAttributeType), ODSAttribute(@"etag", NSStringAttributeType),
                                  ODSAttribute(@"values", NSBinaryDataAttributeType) ]),
    ODSEntity(ODSTombstoneEntity, @[ ODSAttribute(@"entityType", NSStringAttributeType), ODSAttribute(@"keyText", NSStringAttributeType),
                                     ODSAttribute(@"deleted", NSDateAttributeType) ]),
  ];
  // What a peer server serves: the synced entities, with their sub-entities.
  NSMutableArray *synced = [NSMutableArray array];
  ODSCodec *codec = [[ODSCodec alloc] initWithModel:model];
  for (NSEntityDescription *entity in model.entities) {
    if ([codec directionOfEntity:entity] != ODataSyncDirectionNone) [synced addObject:entity];
  }
  model.entities = [model.entities arrayByAddingObjectsFromArray:added];
  [model setEntities:synced forConfiguration:ODataSyncPeerConfiguration];
  if (configuration) {
    NSArray *entities = [model entitiesForConfiguration:configuration] ?: @[];
    [model setEntities:[entities arrayByAddingObjectsFromArray:added] forConfiguration:configuration];
  }
}

- (instancetype)initWithCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
  self = [super init];
  if (!self) return nil;
  _coordinator = coordinator;
  _codec = [[ODSCodec alloc] initWithModel:coordinator.managedObjectModel];
  _remotes = [NSMutableArray array];
  _running = [[NSLock alloc] init];
  _tally = [NSMutableDictionary dictionary];
  _tracer = [OTTracer tracerNamed:@"ODataSync" version:nil];
  _resolvers = [NSMutableDictionary dictionary];
  _tombstoneRetention = 30 * 24 * 3600;
  // Last writer wins: every save but the engine's stamps what it changed.
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(contextWillSave:)
                                               name:NSManagedObjectContextWillSaveNotification object:nil];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark Conflicts

- (id<ODataSyncResolving>)resolverForEntityName:(NSString *)entityName
{
  @synchronized (_resolvers) {
    return _resolvers[entityName];
  }
}

- (void)setResolver:(id<ODataSyncResolving>)resolver forEntityName:(NSString *)entityName
{
  @synchronized (_resolvers) {
    _resolvers[entityName] = resolver;
  }
}

- (NSString *)replicaID
{
  @synchronized (self) {
    if (_replicaID) return _replicaID;
    NSPersistentStore *store = self.coordinator.persistentStores.firstObject;
    NSDictionary *metadata = store ? [self.coordinator metadataForPersistentStore:store] : nil;
    _replicaID = metadata[@"ODataSync.replica"];
    if (!_replicaID) {
      _replicaID = [NSUUID UUID].UUIDString.lowercaseString;
      if (store) {
        NSMutableDictionary *changed = [metadata mutableCopy] ?: [NSMutableDictionary dictionary];
        changed[@"ODataSync.replica"] = _replicaID;
        [self.coordinator setMetadata:changed forPersistentStore:store];
      }
    }
    return _replicaID;
  }
}

// 0001701234567890.0003.ab12cd34: ordered as text, as the clock orders.
- (NSString *)tick
{
  NSString *replica = [[self replicaID] substringToIndex:8];
  @synchronized (self) {
    int64_t now = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);
    if (now > _clockTime) {
      _clockTime = now;
      _clockCounter = 0;
    } else {
      _clockCounter++;
    }
    return [NSString stringWithFormat:@"%016lld.%04d.%@", (long long)_clockTime, _clockCounter, replica];
  }
}

- (void)witness:(NSString *)stamp
{
  if (![stamp isKindOfClass:[NSString class]]) return;
  NSArray *parts = [stamp componentsSeparatedByString:@"."];
  if (parts.count < 2) return;
  int64_t time = [parts[0] longLongValue];
  int32_t counter = [parts[1] intValue];
  @synchronized (self) {
    if (time > _clockTime || (time == _clockTime && counter > _clockCounter)) {
      _clockTime = time;
      _clockCounter = counter;
    }
  }
}

- (NSFetchRequest *)tombstonesOf:(NSString *)entityName keyText:(NSString *)keyText
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSTombstoneEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"entityType == %@ AND keyText == %@", entityName, keyText];
  return fetch;
}

- (BOOL)isDeleted:(NSString *)entityName keyText:(NSString *)keyText inContext:(NSManagedObjectContext *)context
{
  return [context countForFetchRequest:[self tombstonesOf:entityName keyText:keyText] error:NULL] > 0;
}

// Deletions remembered (docs/offline-sync.md, 7): whoever deleted a synced
// object, its key is kept, so that a peer that has not heard yet cannot
// bring it back (an insert passed on late, round and round). An object made
// here again, or by a service (the authority), is not deleted any more.
- (void)noteDeletionsIn:(NSManagedObjectContext *)context author:(NSString *)author
{
  ODSCodec *codec = self.codec;
  BOOL authority = ![author hasPrefix:@"ODataSync."];
  if ([author hasPrefix:ODataSyncDownAuthorPrefix]) {
    ODataSyncRemote *from = [self remoteWithIdentifier:[author substringFromIndex:ODataSyncDownAuthorPrefix.length]];
    authority = from && !from.peer;
  }
  for (NSManagedObject *object in context.deletedObjects) {
    NSEntityDescription *root = [codec rootOf:object.entity];
    if ([codec directionOfEntity:root] == ODataSyncDirectionNone) continue;
    NSString *keyText = [codec keyTextOf:[codec keyOfObject:object] entity:root];
    if (!keyText || [self isDeleted:root.name keyText:keyText inContext:context]) continue;
    NSManagedObject *tombstone = [NSEntityDescription insertNewObjectForEntityForName:ODSTombstoneEntity inManagedObjectContext:context];
    [tombstone setValue:root.name forKey:@"entityType"];
    [tombstone setValue:keyText forKey:@"keyText"];
    [tombstone setValue:[NSDate date] forKey:@"deleted"];
  }
  if (!authority) return;
  for (NSManagedObject *object in context.insertedObjects) {
    NSEntityDescription *root = [codec rootOf:object.entity];
    if ([codec directionOfEntity:root] == ODataSyncDirectionNone) continue;
    NSString *keyText = [codec keyTextOf:[codec keyOfObject:object] entity:root];
    if (!keyText) continue;
    for (NSManagedObject *tombstone in [context executeFetchRequest:[self tombstonesOf:root.name keyText:keyText] error:NULL]) {
      [context deleteObject:tombstone];
    }
  }
}

- (void)pruneTombstones
{
  if (self.tombstoneRetention <= 0) return;
  NSManagedObjectContext *context = [self contextWritingAs:ODataSyncBookkeepingAuthor];
  NSDate *before = [NSDate dateWithTimeIntervalSinceNow:-self.tombstoneRetention];
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSTombstoneEntity];
    fetch.predicate = [NSPredicate predicateWithFormat:@"deleted < %@", before];
    for (NSManagedObject *tombstone in [context executeFetchRequest:fetch error:NULL]) [context deleteObject:tombstone];
    if (context.hasChanges) [context save:NULL];
  }];
}

- (void)contextWillSave:(NSNotification *)notification
{
  NSManagedObjectContext *context = notification.object;
  if (context.persistentStoreCoordinator != self.coordinator) return;
  NSString *author = [context respondsToSelector:@selector(transactionAuthor)] ? context.transactionAuthor : nil;
  if (context.deletedObjects.count || context.insertedObjects.count) [self noteDeletionsIn:context author:author];
  if ([author hasPrefix:@"ODataSync."]) return;
  NSMutableSet *changed = [NSMutableSet setWithSet:context.insertedObjects];
  [changed unionSet:context.updatedObjects];
  for (NSManagedObject *object in changed) {
    NSAttributeDescription *stamp = [self.codec modifiedAttributeOf:object.entity];
    if (!stamp) continue;
    NSDictionary *changes = object.changedValues;
    if (!object.isInserted && (!changes.count || (changes.count == 1 && changes[stamp.name]))) continue;
    [object setValue:[self tick] forKey:stamp.name];
  }
}

- (NSArray<ODataSyncRemote *> *)remotes
{
  @synchronized (self) {
    return [_remotes copy];
  }
}

- (void)addRemote:(ODataSyncRemote *)remote
{
  @synchronized (self) {
    [_remotes addObject:remote];
  }
}

- (NSMutableDictionary<NSString *, NSNumber *> *)tally
{
  return _tally;
}

- (void)count:(NSString *)what by:(NSUInteger)n
{
  @synchronized (_tally) {
    _tally[what] = @([_tally[what] unsignedIntegerValue] + n);
  }
}

- (void)setAside:(ODataSyncIssue *)issue
{
  [self count:@"refused" by:1];
  id<ODataSyncDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(syncEngine:didSetAside:)]) [delegate syncEngine:self didSetAside:issue];
}

- (void)ignoredLocalChangeTo:(NSManagedObjectID *)objectID
{
  id<ODataSyncDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(syncEngine:ignoredLocalChangeToObject:)]) [delegate syncEngine:self ignoredLocalChangeToObject:objectID];
}

- (ODataClient *)clientOf:(ODataSyncRemote *)remote
{
  ODataConfiguration *configuration = remote.configuration;
  configuration.version = @"4.01";
  ODataClient *client = [[ODataClient alloc] initWithConfiguration:configuration];
  client.transport = remote.transport;
  return client;
}

- (NSDictionary<NSString *, NSString *> *)headersFor:(ODataSyncRemote *)remote
{
  return remote.peer ? @{ ODataSyncReplicaHeader: self.replicaID } : @{};
}

- (ODataSyncRemote *)remoteWithIdentifier:(NSString *)identifier
{
  for (ODataSyncRemote *remote in self.remotes) {
    if ([remote.identifier isEqualToString:identifier]) return remote;
  }
  return nil;
}

- (NSManagedObjectContext *)contextWritingAs:(NSString *)author
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = self.coordinator;
  context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
  if ([context respondsToSelector:@selector(setTransactionAuthor:)]) context.transactionAuthor = author;
  return context;
}

- (NSManagedObject *)stateOf:(ODataSyncRemote *)remote inContext:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSRemoteStateEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@", remote.identifier];
  fetch.fetchLimit = 1;
  NSManagedObject *state = [[context executeFetchRequest:fetch error:NULL] firstObject];
  if (!state) {
    state = [NSEntityDescription insertNewObjectForEntityForName:ODSRemoteStateEntity inManagedObjectContext:context];
    [state setValue:remote.identifier forKey:@"remote"];
  }
  return state;
}

- (NSManagedObject *)entryOf:(NSString *)entityName keyText:(NSString *)keyText remote:(ODataSyncRemote *)remote
                   inContext:(NSManagedObjectContext *)context
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND entityType == %@ AND keyText == %@", remote.identifier, entityName, keyText];
  fetch.fetchLimit = 1;
  return [[context executeFetchRequest:fetch error:NULL] firstObject];
}

- (NSManagedObject *)shadowOf:(NSString *)entityName keyText:(NSString *)keyText remote:(ODataSyncRemote *)remote
                    inContext:(NSManagedObjectContext *)context make:(BOOL)make
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSShadowEntity];
  fetch.predicate = [NSPredicate predicateWithFormat:@"remote == %@ AND entityType == %@ AND keyText == %@", remote.identifier, entityName, keyText];
  fetch.fetchLimit = 1;
  NSManagedObject *shadow = [[context executeFetchRequest:fetch error:NULL] firstObject];
  if (!shadow && make) {
    shadow = [NSEntityDescription insertNewObjectForEntityForName:ODSShadowEntity inManagedObjectContext:context];
    [shadow setValue:remote.identifier forKey:@"remote"];
    [shadow setValue:entityName forKey:@"entityType"];
    [shadow setValue:keyText forKey:@"keyText"];
  }
  return shadow;
}

- (NSURL *)URLOf:(NSString *)relative remote:(ODataSyncRemote *)remote
{
  NSString *root = remote.serviceRoot.absoluteString;
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
  [allowed removeCharactersInString:@"+"];
  NSString *encoded = [relative stringByAddingPercentEncodingWithAllowedCharacters:allowed];
  return [NSURL URLWithString:[root stringByAppendingString:encoded]];
}

#pragma mark Syncing

- (BOOL)syncWithError:(NSError **)error
{
  [_running lock];
  @synchronized (_tally) {
    [_tally removeAllObjects];
  }
  OTSpan *span = [self.tracer startSpanNamed:@"sync" attributes:nil];
  [self pruneTombstones];
  BOOL ok = YES;
  for (ODataSyncRemote *remote in self.remotes) {
    if (![self downloadFromRemote:remote error:error] || ![self uploadToRemote:remote error:error]) {
      ok = NO;
      break;
    }
  }
  @synchronized (_tally) {
    _lastResult = [[ODataSyncResult alloc] initWithTally:_tally];
  }
  if (!ok && error) [span recordError:*error];
  [span end];
  [_running unlock];
  return ok;
}

- (void)syncWithTarget:(id)target action:(SEL)action
{
  [NSThread detachNewThreadSelector:@selector(runSyncFor:) toTarget:self withObject:@[ target, NSStringFromSelector(action) ]];
}

- (void)runSyncFor:(NSArray *)reply
{
  @autoreleasepool {
    NSError *error = nil;
    BOOL ok = [self syncWithError:&error];
    ODataSyncResult *result = ok ? self.lastResult : nil;
    id target = reply[0];
    SEL action = NSSelectorFromString(reply[1]);
    dispatch_async(dispatch_get_main_queue(), ^{
      void (*send)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
      send(target, action, result, ok ? nil : error);
    });
  }
}

- (BOOL)downloadFromRemote:(ODataSyncRemote *)remote error:(NSError **)error
{
  // What the device changed and has not sent, known first.
  return [[[ODSUploader alloc] initWithEngine:self remote:remote] collect:error] &&
         [[[ODSDownloader alloc] initWithEngine:self remote:remote] download:error];
}

- (BOOL)uploadToRemote:(ODataSyncRemote *)remote error:(NSError **)error
{
  return [[[ODSUploader alloc] initWithEngine:self remote:remote] upload:error];
}

- (BOOL)reconcileWithRemote:(ODataSyncRemote *)remote error:(NSError **)error
{
  return [[[ODSUploader alloc] initWithEngine:self remote:remote] collect:error] &&
         [[[ODSDownloader alloc] initWithEngine:self remote:remote] reconcile:error];
}

#pragma mark Issues

- (NSArray<ODataSyncChange *> *)pendingChanges
{
  // Not while a sync runs (it collects too, and the main thread should not
  // wait for it): what is in the outbox then.
  if ([_running tryLock]) {
    for (ODataSyncRemote *remote in self.remotes) [[[ODSUploader alloc] initWithEngine:self remote:remote] collect:NULL];
    [_running unlock];
  }
  NSManagedObjectContext *context = [self contextWritingAs:ODataSyncBookkeepingAuthor];
  NSMutableArray *changes = [NSMutableArray array];
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"sequence" ascending:YES] ];
    for (NSManagedObject *entry in [context executeFetchRequest:fetch error:NULL]) {
      NSEntityDescription *entity = self.coordinator.managedObjectModel.entitiesByName[[entry valueForKey:@"entityType"]];
      NSDictionary *key = ODSUnarchive([entry valueForKey:@"key"]);
      NSManagedObject *object = entity && key ? [self.codec objectOfEntity:entity key:key inContext:context] : nil;
      Class kind = [[entry valueForKey:@"setAside"] boolValue] ? [ODataSyncIssue class] : [ODataSyncChange class];
      [changes addObject:[[kind alloc] initWithEntry:entry objectID:object.objectID]];
    }
  }];
  return changes;
}

- (NSArray<ODataSyncIssue *> *)issues
{
  NSManagedObjectContext *context = [self contextWritingAs:ODataSyncBookkeepingAuthor];
  NSMutableArray *issues = [NSMutableArray array];
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
    fetch.predicate = [NSPredicate predicateWithFormat:@"setAside == YES"];
    fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"sequence" ascending:YES] ];
    for (NSManagedObject *entry in [context executeFetchRequest:fetch error:NULL]) {
      NSEntityDescription *entity = self.coordinator.managedObjectModel.entitiesByName[[entry valueForKey:@"entityType"]];
      NSDictionary *key = ODSUnarchive([entry valueForKey:@"key"]);
      NSManagedObject *object = entity && key ? [self.codec objectOfEntity:entity key:key inContext:context] : nil;
      [issues addObject:[[ODataSyncIssue alloc] initWithEntry:entry objectID:object.objectID]];
    }
  }];
  return issues;
}

- (void)changeIssue:(ODataSyncIssue *)issue discarding:(BOOL)discard
{
  NSManagedObjectContext *context = [self contextWritingAs:ODataSyncBookkeepingAuthor];
  [context performBlockAndWait:^{
    NSManagedObject *entry = [context existingObjectWithID:issue.entryID error:NULL];
    if (!entry) return;
    if (discard && [[entry valueForKey:@"status"] integerValue] == 409) {
      // A conflict given up: the remote's version, read again at the next sync.
      [entry setValue:@(ODataSyncOperationRefresh) forKey:@"operation"];
      [entry setValue:@NO forKey:@"setAside"];
    } else if (discard) {
      [context deleteObject:entry];
    } else {
      [entry setValue:@NO forKey:@"setAside"];
      [entry setValue:@0 forKey:@"attempts"];
    }
    [context save:NULL];
  }];
}

- (void)retryIssue:(ODataSyncIssue *)issue
{
  [self changeIssue:issue discarding:NO];
}

- (void)discardIssue:(ODataSyncIssue *)issue
{
  [self changeIssue:issue discarding:YES];
}

@end
