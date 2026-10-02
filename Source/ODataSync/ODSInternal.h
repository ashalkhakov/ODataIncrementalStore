// What ODataSync's files share: the bookkeeping entities, how objects are
// written and read as OData, and the two halves.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "ODataSyncEngine.h"
#import <ODataKit/ODataPropertyMapper.h>
#import <ODataKit/ODataValue.h>
#import <ODataIncrementalStore/ODataClient.h>
#import <ODataIncrementalStore/ODataConfiguration.h>
#import <OTelKit/OTTrace.h>

NS_ASSUME_NONNULL_BEGIN

// The bookkeeping entities (docs/offline-sync.md, 3.3).
FOUNDATION_EXPORT NSString * const ODSRemoteStateEntity;   // remote, deltaLinks, filters, historyToken
FOUNDATION_EXPORT NSString * const ODSOutboxEntity;        // remote, entityName, key, operation, properties, ...
FOUNDATION_EXPORT NSString * const ODSShadowEntity;        // remote, entityType, keyText, etag, values (a row's JSON)

FOUNDATION_EXPORT NSError *ODSError(NSInteger code, NSString *message);
FOUNDATION_EXPORT NSData *ODSArchive(id _Nullable plist);
FOUNDATION_EXPORT id _Nullable ODSUnarchive(NSData *_Nullable data);

// How the engine's objects are written and read as OData: by the mapper's
// names, the value coder's values.
@interface ODSCodec : NSObject
- (instancetype)initWithModel:(NSManagedObjectModel *)model;
@property (nonatomic, readonly) NSManagedObjectModel *model;
@property (nonatomic, readonly) ODataPropertyMapper *mapper;
- (ODataSyncDirection)directionOfEntity:(NSEntityDescription *)entity;
// The way it goes with this remote: with a peer, up is both.
- (ODataSyncDirection)directionOfEntity:(NSEntityDescription *)entity toward:(nullable ODataSyncRemote *)remote;
- (NSEntityDescription *)rootOf:(NSEntityDescription *)entity;
// Root entities going these ways (with the remote), parents before
// children (an entity before those whose to-ones point to it).
- (NSArray<NSEntityDescription *> *)rootEntitiesGoing:(NSSet<NSNumber *> *)directions toward:(nullable ODataSyncRemote *)remote;
// The synced attributes (served, not computed, no dynamic bag) and to-one
// relationships to synced entities.
- (NSArray<NSAttributeDescription *> *)attributesOf:(NSEntityDescription *)entity;
- (NSArray<NSRelationshipDescription *> *)toOnesOf:(NSEntityDescription *)entity;
// Keys, by Core Data attribute name.
- (NSDictionary *)keyOfObject:(NSManagedObject *)object;
- (nullable NSDictionary *)keyFromJSON:(NSDictionary *)json entity:(NSEntityDescription *)entity;
- (nullable NSDictionary *)keyFromValues:(NSDictionary *)values entity:(NSEntityDescription *)entity;
// From an @odata.id (Products(5), or a whole URL): the entity it names
// (of those given) and its key.
- (nullable NSDictionary *)keyFromID:(NSString *)identifier entity:(NSEntityDescription *_Nullable *_Nullable)entity
                          among:(NSArray<NSEntityDescription *> *)entities;
// A key as text, the same however it was made: what the outbox and the
// shadows find an object's entry by (with its root entity's name).
- (NSString *)keyTextOf:(NSDictionary *)key entity:(NSEntityDescription *)entity;
// Set(key), not percent-encoded.
- (NSString *)pathOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key;
// The local object of an entity (or one derived from it) with this key.
- (nullable NSManagedObject *)objectOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key
                                   inContext:(NSManagedObjectContext *)context;
// An entity's JSON applied to an object: its attributes; its to-ones, by
// the related keys expanded in it (Nav: {key}), to the local objects
// those name (nil when none is local: the next download may bring it).
- (void)applyJSON:(NSDictionary *)json toObject:(NSManagedObject *)object;
// A body for a PATCH: these properties (nil: all synced), attributes as
// JSON and to-ones as Nav@odata.bind (null to unlink).
- (NSDictionary *)JSONOfObject:(NSManagedObject *)object properties:(nullable NSSet<NSString *> *)properties;
// Values by Core Data property name (an attribute's value, a to-one's
// related key, NSNull for none): an object's; a row's (what it has); and
// back onto an object (what they name).
- (NSDictionary *)valuesOfObject:(NSManagedObject *)object;
- (NSDictionary *)valuesFromJSON:(NSDictionary *)json entity:(NSEntityDescription *)entity;
- (void)applyValues:(NSDictionary *)values toObject:(NSManagedObject *)object;
// An object as a row: what a shadow keeps of a version (wire names, its
// to-ones' keys expanded).
- (NSDictionary *)rowOfObject:(NSManagedObject *)object;
// The properties whose values differ (missing is NSNull).
FOUNDATION_EXPORT NSSet<NSString *> *ODSChangedNames(NSDictionary *_Nullable before, NSDictionary *_Nullable after);
// The String attribute last writer wins orders by (ODataSync.modified).
- (nullable NSAttributeDescription *)modifiedAttributeOf:(NSEntityDescription *)entity;
// The service's version counter (an integer attribute that OData.etag
// names, which the service increments on each update): which of two
// copies is newer.
- (nullable NSAttributeDescription *)versionAttributeOf:(NSEntityDescription *)entity;
// $expand of the to-ones' keys, for reading an entity's rows: nil for none.
- (nullable NSString *)expandOfEntity:(NSEntityDescription *)entity;
// $select of the key, for reading only keys.
- (NSString *)selectOfKeyOfEntity:(NSEntityDescription *)entity;
// $filter text naming these keys (k eq 1 or k eq 2; (a eq 1 and b eq 2) or ...).
- (NSString *)filterOfKeys:(NSArray<NSDictionary *> *)keys entity:(NSEntityDescription *)entity;
@end

@interface ODataSyncEngine ()
@property (nonatomic, readonly) ODSCodec *codec;
@property (nonatomic, readonly) OTTracer *tracer;
// A client of the remote: its configuration, at 4.01, its transport.
- (ODataClient *)clientOf:(ODataSyncRemote *)remote;
// The headers every request to the remote has: to a peer, this replica.
- (NSDictionary<NSString *, NSString *> *)headersFor:(ODataSyncRemote *)remote;
// The remote added with this identifier.
- (nullable ODataSyncRemote *)remoteWithIdentifier:(NSString *)identifier;
// A new private context on the coordinator, writing as this author.
- (NSManagedObjectContext *)contextWritingAs:(NSString *)author;
// The remote's state object (made when there is none), in this context.
- (NSManagedObject *)stateOf:(ODataSyncRemote *)remote inContext:(NSManagedObjectContext *)context;
// An object's outbox entry for the remote, and its shadow (made when asked
// and there is none): by root entity name and key text.
- (nullable NSManagedObject *)entryOf:(NSString *)entityName keyText:(NSString *)keyText remote:(ODataSyncRemote *)remote
                            inContext:(NSManagedObjectContext *)context;
- (nullable NSManagedObject *)shadowOf:(NSString *)entityName keyText:(NSString *)keyText remote:(ODataSyncRemote *)remote
                             inContext:(NSManagedObjectContext *)context make:(BOOL)make;
// A URL under the remote's service root, from a relative path and query,
// not yet percent-encoded.
- (NSURL *)URLOf:(NSString *)relative remote:(ODataSyncRemote *)remote;
@property (nonatomic, readonly) NSMutableDictionary<NSString *, NSNumber *> *tally;  // downloaded, removed, ...
- (void)count:(NSString *)what by:(NSUInteger)n;
- (void)setAside:(ODataSyncIssue *)issue;
- (void)ignoredLocalChangeTo:(NSManagedObjectID *)objectID;
- (nullable id<ODataSyncResolving>)resolverForEntityName:(NSString *)entityName;
// The hybrid logical clock: a stamp for a change made now; a stamp seen
// from elsewhere, so the next is after it.
- (NSString *)tick;
- (void)witness:(nullable NSString *)stamp;
@end

// Conflicts (ODSConflicts.m).
@interface ODataSyncEngine (ODSConflicts)
// A both object changed here (its outbox entry) and at the remote: its
// remote version (nil: deleted there) and ETag. The resolver's resolution
// applied, the outbox entry and the shadow with it.
- (void)settleConflictOf:(NSEntityDescription *)root key:(NSDictionary *)key entry:(NSManagedObject *)entry
               remoteRow:(nullable NSDictionary *)row etag:(nullable NSString *)etag remote:(ODataSyncRemote *)remote
                 context:(NSManagedObjectContext *)context;
// The version both agree on now: the shadow's ETag and row (nil: none, the
// shadow gone).
- (void)agreeOn:(nullable NSDictionary *)row etag:(nullable NSString *)etag of:(NSEntityDescription *)root keyText:(NSString *)keyText
         remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context;
- (id<ODataSyncResolving>)resolverFor:(NSEntityDescription *)root;
@end

@interface ODataSyncConflict ()
- (instancetype)initWithEntity:(NSEntityDescription *)entity key:(NSDictionary *)key base:(nullable NSDictionary *)base
                         local:(nullable NSDictionary *)local remote:(nullable NSDictionary *)remote
                  localChanges:(NSSet *)localChanges remoteChanges:(NSSet *)remoteChanges;
@end

@interface ODataSyncIssue ()
- (instancetype)initWithEntry:(NSManagedObject *)entry objectID:(nullable NSManagedObjectID *)objectID;
@property (nonatomic, readonly, strong) NSManagedObjectID *entryID;
@end

@interface ODataSyncResult ()
- (instancetype)initWithTally:(NSDictionary<NSString *, NSNumber *> *)tally;
@end

// Down: the remote's changes into the local store.
@interface ODSDownloader : NSObject
- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote;
- (BOOL)download:(NSError **)error;
- (BOOL)reconcile:(NSError **)error;
// One object's row at the remote, its to-ones' keys expanded; nil with
// *status 404 when it has none (0: no answer, the error).
- (nullable NSDictionary *)rowOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key status:(NSInteger *)status
                                 error:(NSError **)error;
// One object read again from the remote and applied, and agreed on;
// deleted locally when the remote has none. NO, with the error, when the
// remote did not answer.
- (BOOL)refreshObjectOfEntity:(NSEntityDescription *)entity key:(NSDictionary *)key
                      context:(NSManagedObjectContext *)context error:(NSError **)error;
@end

// Up: history into the outbox, and the outbox to the remote.
@interface ODSUploader : NSObject
- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote;
// History into the outbox only: before a download, so what the device
// changed and has not sent is known (not swept, a conflict when the remote
// changed it too).
- (BOOL)collect:(NSError **)error;
- (BOOL)upload:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
