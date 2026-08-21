// Last-resort Core Data types when FreeCoreData is not installed.
// Prefer https://github.com/ashalkhakov/FreeCoreData on GNUstep.
// Zeroing weak refs require the modern runtime — that is intentional.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, NSAttributeType) {
  NSUndefinedAttributeType = 0,
  NSInteger16AttributeType = 100,
  NSInteger32AttributeType = 200,
  NSInteger64AttributeType = 300,
  NSDecimalAttributeType = 400,
  NSDoubleAttributeType = 500,
  NSFloatAttributeType = 600,
  NSStringAttributeType = 700,
  NSBooleanAttributeType = 800,
  NSDateAttributeType = 900,
  NSBinaryDataAttributeType = 1000,
  NSUUIDAttributeType_Stub = 2400
};

typedef NS_ENUM(NSUInteger, NSPersistentStoreRequestType) {
  NSFetchRequestType = 1,
  NSSaveRequestType = 2
};

typedef NS_ENUM(NSUInteger, NSFetchRequestResultType) {
  NSManagedObjectResultType = 0x00,
  NSManagedObjectIDResultType = 0x01,
  NSDictionaryResultType = 0x02,
  NSCountResultType = 0x04
};

FOUNDATION_EXPORT NSString * const NSStoreTypeKey;
FOUNDATION_EXPORT NSString * const NSStoreUUIDKey;

@class NSEntityDescription;
@class NSManagedObject;
@class NSManagedObjectID;
@class NSManagedObjectContext;
@class NSManagedObjectModel;
@class NSPersistentStoreCoordinator;
@class NSPersistentStore;

@interface NSAttributeDescription : NSObject
@property (copy) NSString *name;
@property NSAttributeType attributeType;
@property (nullable, copy) NSDictionary *userInfo;
@end

@interface NSRelationshipDescription : NSObject
@property (copy) NSString *name;
@property (nullable, weak) NSEntityDescription *destinationEntity;
@property BOOL isToMany;
@property (nullable, copy) NSDictionary *userInfo;
@end

@interface NSEntityDescription : NSObject
@property (copy) NSString *name;
@property (copy) NSDictionary<NSString *, NSAttributeDescription *> *attributesByName;
@property (copy) NSDictionary<NSString *, NSRelationshipDescription *> *relationshipsByName;
@property (nullable, copy) NSDictionary *userInfo;
@property (nullable, copy) NSArray *uniquenessConstraints;
@end

@interface NSManagedObjectID : NSObject
@property (nonatomic, readonly) NSEntityDescription *entity;
@property (nonatomic, readonly, getter=isTemporaryID) BOOL temporaryID;
@end

@interface NSManagedObject : NSObject
@property (nonatomic, strong) NSEntityDescription *entity;
@property (nonatomic, strong) NSManagedObjectID *objectID;
@property (nonatomic, getter=isInserted) BOOL inserted;
- (nullable id)primitiveValueForKey:(NSString *)key;
- (void)setPrimitiveValue:(nullable id)value forKey:(NSString *)key;
- (NSDictionary *)changedValues;
@end

@interface NSManagedObjectModel : NSObject
@property (copy) NSDictionary<NSString *, NSEntityDescription *> *entitiesByName;
@end

@interface NSPersistentStoreRequest : NSObject
@property (nonatomic, readonly) NSPersistentStoreRequestType requestType;
@end

@interface NSFetchRequest : NSPersistentStoreRequest
@property (nullable, strong) NSEntityDescription *entity;
@property (nullable, copy) NSString *entityName;
@property (nullable, strong) NSPredicate *predicate;
@property (nullable, copy) NSArray<NSSortDescriptor *> *sortDescriptors;
@property NSUInteger fetchLimit;
@property NSUInteger fetchOffset;
@property NSFetchRequestResultType resultType;
@property (nullable, copy) NSArray *propertiesToFetch;
@property (nullable, copy) NSArray<NSString *> *relationshipKeyPathsForPrefetching;
@property BOOL returnsObjectsAsFaults;
+ (instancetype)fetchRequestWithEntityName:(NSString *)entityName;
@end

@interface NSSaveChangesRequest : NSPersistentStoreRequest
@property (nullable, copy) NSSet<NSManagedObject *> *insertedObjects;
@property (nullable, copy) NSSet<NSManagedObject *> *updatedObjects;
@property (nullable, copy) NSSet<NSManagedObject *> *deletedObjects;
- (instancetype)initWithInsertedObjects:(nullable NSSet *)inserted
                         updatedObjects:(nullable NSSet *)updated
                         deletedObjects:(nullable NSSet *)deleted
                           lockedObjects:(nullable NSSet *)locked;
@end

@interface NSPersistentStore : NSObject
@property (nullable, readonly, weak) NSPersistentStoreCoordinator *persistentStoreCoordinator;
@property (nullable, copy) NSURL *URL;
@property (nullable, copy) NSDictionary *options;
@property (nullable, copy) NSDictionary *metadata;
@property (copy) NSString *type;
- (instancetype)initWithPersistentStoreCoordinator:(nullable NSPersistentStoreCoordinator *)root
                                 configurationName:(nullable NSString *)name
                                               URL:(NSURL *)url
                                           options:(nullable NSDictionary *)options NS_DESIGNATED_INITIALIZER;
- (BOOL)loadMetadata:(NSError **)error;
@end

@interface NSPersistentStoreCoordinator : NSObject
@property (nonatomic, strong) NSManagedObjectModel *managedObjectModel;
- (instancetype)initWithManagedObjectModel:(NSManagedObjectModel *)model NS_DESIGNATED_INITIALIZER;
+ (void)registerStoreClass:(Class)storeClass forStoreType:(NSString *)storeType;
- (nullable NSPersistentStore *)addPersistentStoreWithType:(NSString *)storeType
                                             configuration:(nullable NSString *)configuration
                                                       URL:(nullable NSURL *)storeURL
                                                   options:(nullable NSDictionary *)options
                                                     error:(NSError **)error;
@end

@interface NSManagedObjectContext : NSObject
@property (nullable, strong) NSPersistentStoreCoordinator *persistentStoreCoordinator;
- (NSManagedObject *)objectWithID:(NSManagedObjectID *)objectID;
@end

@interface NSIncrementalStoreNode : NSObject
@property (nonatomic, readonly) NSManagedObjectID *objectID;
@property (nonatomic, readonly) uint64_t version;
- (instancetype)initWithObjectID:(NSManagedObjectID *)oid
                      withValues:(NSDictionary *)values
                         version:(uint64_t)version NS_DESIGNATED_INITIALIZER;
- (nullable id)valueForPropertyDescription:(id)prop;
@end

@interface NSIncrementalStore : NSPersistentStore
- (id)executeRequest:(NSPersistentStoreRequest *)request
         withContext:(nullable NSManagedObjectContext *)context
               error:(NSError **)error;
- (NSIncrementalStoreNode *)newValuesForObjectWithID:(NSManagedObjectID *)objectID
                                         withContext:(NSManagedObjectContext *)context
                                               error:(NSError **)error;
- (id)newValueForRelationship:(NSRelationshipDescription *)relationship
              forObjectWithID:(NSManagedObjectID *)objectID
                  withContext:(nullable NSManagedObjectContext *)context
                        error:(NSError **)error;
- (NSArray<NSManagedObjectID *> *)obtainPermanentIDsForObjects:(NSArray<NSManagedObject *> *)array
                                                         error:(NSError **)error;
- (NSManagedObjectID *)newObjectIDForEntity:(NSEntityDescription *)entity
                            referenceObject:(id)data;
- (id)referenceObjectForObjectID:(NSManagedObjectID *)objectID;
+ (id)identifierForNewStoreAtURL:(NSURL *)storeURL;
@end

NS_ASSUME_NONNULL_END
