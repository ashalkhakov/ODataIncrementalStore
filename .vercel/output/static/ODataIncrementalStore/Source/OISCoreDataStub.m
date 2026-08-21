// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#if !defined(__APPLE__) || defined(OIS_FORCE_STUB_COREDATA)

#import "OISCoreDataStub.h"

NSString * const NSStoreTypeKey = @"NSStoreTypeKey";
NSString * const NSStoreUUIDKey = @"NSStoreUUIDKey";

@implementation NSAttributeDescription
@end

@implementation NSRelationshipDescription
@end

@implementation NSEntityDescription
- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _attributesByName = @{};
  _relationshipsByName = @{};
  return self;
}
@end

@implementation NSManagedObjectID
@end

@implementation NSManagedObject
- (id)primitiveValueForKey:(NSString *)key { (void)key; return nil; }
- (void)setPrimitiveValue:(id)value forKey:(NSString *)key { (void)value; (void)key; }
- (NSDictionary *)changedValues { return @{}; }
@end

@implementation NSManagedObjectModel
- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _entitiesByName = @{};
  return self;
}
@end

@implementation NSPersistentStoreRequest
- (NSPersistentStoreRequestType)requestType { return 0; }
@end

@implementation NSFetchRequest
- (NSPersistentStoreRequestType)requestType { return NSFetchRequestType; }
+ (instancetype)fetchRequestWithEntityName:(NSString *)entityName
{
  NSFetchRequest *request = [[self alloc] init];
  request.entityName = entityName;
  return request;
}
@end

@implementation NSSaveChangesRequest
- (NSPersistentStoreRequestType)requestType { return NSSaveRequestType; }
@end

@implementation NSPersistentStore
- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root
                                 configurationName:(NSString *)name
                                               URL:(NSURL *)url
                                           options:(NSDictionary *)options
{
  self = [super init];
  if (!self) return nil;
  _persistentStoreCoordinator = root;
  _URL = [url copy];
  _options = [options copy];
  (void)name;
  return self;
}
- (BOOL)loadMetadata:(NSError **)error { (void)error; return YES; }
@end

static NSMutableDictionary *OISRegisteredStoreClasses = nil;

@implementation NSPersistentStoreCoordinator
+ (void)initialize
{
  if (self == [NSPersistentStoreCoordinator class]) {
    OISRegisteredStoreClasses = [NSMutableDictionary dictionary];
  }
}
- (instancetype)initWithManagedObjectModel:(NSManagedObjectModel *)model
{
  self = [super init];
  if (!self) return nil;
  _managedObjectModel = model;
  return self;
}
+ (void)registerStoreClass:(Class)storeClass forStoreType:(NSString *)storeType
{
  @synchronized (self) {
    OISRegisteredStoreClasses[storeType] = storeClass;
  }
}
- (NSPersistentStore *)addPersistentStoreWithType:(NSString *)storeType
                                    configuration:(NSString *)configuration
                                              URL:(NSURL *)storeURL
                                          options:(NSDictionary *)options
                                            error:(NSError **)error
{
  Class cls;
  @synchronized (self) {
    cls = OISRegisteredStoreClasses[storeType];
  }
  if (!cls) {
    if (error) {
      *error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:134000 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Unknown store type %@", storeType]
      }];
    }
    return nil;
  }
  NSPersistentStore *store = [[cls alloc] initWithPersistentStoreCoordinator:self
                                                           configurationName:configuration
                                                                         URL:storeURL
                                                                     options:options];
  if (![store loadMetadata:error]) return nil;
  return store;
}
@end

@implementation NSManagedObjectContext
- (NSManagedObject *)objectWithID:(NSManagedObjectID *)objectID
{
  (void)objectID;
  return [[NSManagedObject alloc] init];
}
@end

@implementation NSIncrementalStoreNode
- (instancetype)initWithObjectID:(NSManagedObjectID *)oid
                      withValues:(NSDictionary *)values
                         version:(uint64_t)version
{
  self = [super init];
  if (!self) return nil;
  _objectID = oid;
  _version = version;
  (void)values;
  return self;
}
- (id)valueForPropertyDescription:(id)prop { (void)prop; return nil; }
@end

@interface OISManagedObjectID : NSManagedObjectID
@property (strong) NSEntityDescription *entityStorage;
@property (strong) id referenceObject;
@end
@implementation OISManagedObjectID
- (NSEntityDescription *)entity { return self.entityStorage; }
@end

@implementation NSIncrementalStore {
  NSMutableDictionary *_ids;
}

- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root
                                 configurationName:(NSString *)name
                                               URL:(NSURL *)url
                                           options:(NSDictionary *)options
{
  self = [super initWithPersistentStoreCoordinator:root configurationName:name URL:url options:options];
  if (!self) return nil;
  _ids = [NSMutableDictionary dictionary];
  return self;
}

- (id)executeRequest:(NSPersistentStoreRequest *)request
         withContext:(NSManagedObjectContext *)context
               error:(NSError **)error
{
  (void)request; (void)context;
  if (error) *error = nil;
  return nil;
}

- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError **)error
{
  (void)objectID; (void)context;
  if (error) *error = nil;
  return nil;
}

- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(NSManagedObjectContext *)context
                        error:(NSError **)error
{
  (void)relationship; (void)objectID; (void)context;
  if (error) *error = nil;
  return nil;
}

- (NSArray *)obtainPermanentIDsForObjects:(NSArray *)array error:(NSError **)error
{
  (void)array;
  if (error) *error = nil;
  return @[];
}

- (NSManagedObjectID *)newObjectIDForEntity:(NSEntityDescription *)entity referenceObject:(id)data
{
  OISManagedObjectID *oid = [[OISManagedObjectID alloc] init];
  oid.entityStorage = entity;
  oid.referenceObject = data;
  return oid;
}

- (id)referenceObjectForObjectID:(NSManagedObjectID *)objectID
{
  if ([objectID isKindOfClass:[OISManagedObjectID class]]) {
    return [(OISManagedObjectID *)objectID referenceObject];
  }
  return nil;
}

+ (id)identifierForNewStoreAtURL:(NSURL *)storeURL
{
  return storeURL.absoluteString ?: [[NSUUID UUID] UUIDString];
}
@end

#endif
