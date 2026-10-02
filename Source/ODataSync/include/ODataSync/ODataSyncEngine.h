// ODataSyncEngine — a Core Data store that works offline, kept in sync
// with an OData service (docs/offline-sync.md).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The app works against one local store, as any Core Data app; the engine
// brings down what the service owns and sends up what the app collects:
//
//   NSManagedObjectModel *model = ...;      // entities say ODataSync.direction
//   [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
//   ... a coordinator; its SQLite store with NSPersistentHistoryTrackingKey ...
//   ODataSyncEngine *sync = [[ODataSyncEngine alloc] initWithCoordinator:coordinator];
//   [sync addRemote:[ODataSyncRemote remoteWithServiceRoot:url]];
//   NSError *error = nil;
//   [sync syncWithError:&error];            // off the main thread
//
// Each entity says which way it goes, in its userInfo:
//
//   ODataSync.direction  down: the service owns it; the app reads it.
//                        up: the app owns it (a UUID key it makes); sent
//                        by upsert, so sending it again is harmless.
//                        both: either changes it; a change made on both
//                        sides since they last agreed is a conflict,
//                        settled by a resolver (below).
//                        Absent: local only.
//   ODataSync.conflicts  of a both entity: remote (the default), local,
//                        lastWriter or merge; a resolver set in code
//                        (-setResolver:forEntityName:) comes first.
//   ODataSync.modified   the String attribute last writer wins orders by:
//                        the engine stamps it, on every save of the
//                        object's changes but its own, with a hybrid
//                        logical clock (wall time, a counter, this store),
//                        which the service keeps like any attribute. A
//                        change made at the service should stamp it too.
//
// Keys and entity sets are the mapper's (OData.key, OData.entitySet). Keep
// an up or both entity's key attributes in history on deletion
// (preservesValueInHistoryOnDeletion): a deletion is sent by its key.

#pragma once
#import <Foundation/Foundation.h>
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataTransport.h>

@class ODataConfiguration, ODataSyncEngine;

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ODataSyncDirectionKey;    // @"ODataSync.direction"
FOUNDATION_EXPORT NSString * const ODataSyncConflictsKey;    // @"ODataSync.conflicts"
FOUNDATION_EXPORT NSString * const ODataSyncModifiedKey;     // @"ODataSync.modified"
FOUNDATION_EXPORT NSString * const ODataSyncErrorDomain;
// The transaction author of what the engine writes: what came down from a
// remote (ODataSyncDownAuthorPrefix and the remote's identifier), and its
// own bookkeeping. What they write is never sent up.
FOUNDATION_EXPORT NSString * const ODataSyncDownAuthorPrefix;  // @"ODataSync.down."
FOUNDATION_EXPORT NSString * const ODataSyncBookkeepingAuthor; // @"ODataSync.bookkeeping"

typedef NS_ENUM(NSInteger, ODataSyncDirection) {
  ODataSyncDirectionNone = 0,
  ODataSyncDirectionDown,
  ODataSyncDirectionUp,
  ODataSyncDirectionBoth,
};

// A both entity's object changed on the device and at the service since
// they last agreed: whose version stands.
typedef NS_ENUM(NSInteger, ODataSyncConflictPolicy) {
  ODataSyncPolicyRemoteWins = 0,  // the service's: the device's change is dropped
  ODataSyncPolicyLocalWins,       // the device's: sent again over the service's
};

// A service to sync with.
@interface ODataSyncRemote : NSObject
+ (instancetype)remoteWithServiceRoot:(NSURL *)serviceRoot;
- (instancetype)initWithServiceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
// What its state is kept under. Default: the service root.
@property (nonatomic, copy) NSString *identifier;
// Credentials, headers, timeouts, as ODataIncrementalStore takes them.
@property (nonatomic, strong) ODataConfiguration *configuration;
// nil: the network. An ODataService (in the process), or a transport of
// the app's own.
@property (nonatomic, strong, nullable) id<ODataTransport> transport;
// Of a down or both entity (by entity name): only its rows that match, as
// $filter text (Region eq 'North'). A set whose filter changes is read
// again.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *filters;
// How many changes go in one $batch. Default: 50.
@property (nonatomic) NSUInteger batchSize;
@end

typedef NS_ENUM(NSInteger, ODataSyncOperation) {
  ODataSyncOperationInsert = 1,
  ODataSyncOperationUpdate,
  ODataSyncOperationDelete,
  ODataSyncOperationRefresh,  // the remote's version read again (a conflict discarded)
};

// A both object changed here and at the remote since the version both last
// agreed on. Values by Core Data property name: an attribute's value, a
// to-one's related key (by its attributes' names), NSNull for none.
@interface ODataSyncConflict : NSObject
@property (nonatomic, readonly) NSEntityDescription *entity;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *key;
// The version both last agreed on; nil when not known (an object made on
// both sides, or before the engine kept versions).
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *base;
// This side's, and the remote's; nil when deleted there.
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *local;
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *remote;
// What each side changed since the base (every property when there is none).
@property (nonatomic, readonly, copy) NSSet<NSString *> *localChanges;
@property (nonatomic, readonly, copy) NSSet<NSString *> *remoteChanges;
@end

typedef NS_ENUM(NSInteger, ODataSyncResolutionKind) {
  ODataSyncTakeRemote,  // the remote's version here; this side's change dropped
  ODataSyncKeepLocal,   // this side's version sent over the remote's
  ODataSyncMerge,       // these values here, and sent
  ODataSyncDefer,       // set aside for the user (an issue, status 409)
};

@interface ODataSyncResolution : NSObject
+ (instancetype)takeRemote;
+ (instancetype)keepLocal;
// The values to have (by property name, as a conflict has them); the
// properties not named keep this side's.
+ (instancetype)mergedValues:(NSDictionary<NSString *, id> *)values;
+ (instancetype)defer;
@property (nonatomic, readonly) ODataSyncResolutionKind kind;
@property (nonatomic, readonly, copy, nullable) NSDictionary<NSString *, id> *values;
@end

// How conflicts are settled: given one, the resolution. On the engine's
// thread, during a sync.
@protocol ODataSyncResolving <NSObject>
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict;
@end

// The remote's version stands.
@interface ODataSyncRemoteWins : NSObject <ODataSyncResolving>
@end

// This side's version stands.
@interface ODataSyncLocalWins : NSObject <ODataSyncResolving>
@end

// The version changed last stands, by the ODataSync.modified stamps (a
// hybrid logical clock's, which order changes across devices whatever
// their clocks say); a tie, or a side without one, goes to the remote.
@interface ODataSyncLastWriterWins : NSObject <ODataSyncResolving>
@end

// Three-way, property by property: what only one side changed is taken
// from it; what both changed to different values, the fallback decides
// (as it would the whole object). A delete on either side, or no base, is
// the fallback's.
@interface ODataSyncMergeFields : NSObject <ODataSyncResolving>
- (instancetype)initWithFallback:(id<ODataSyncResolving>)fallback NS_DESIGNATED_INITIALIZER;
// Falling back to RemoteWins.
- (instancetype)init;
@property (nonatomic, readonly) id<ODataSyncResolving> fallback;
@end

// A change the service refused (400, 403, 409, 422...): it stays in the
// outbox, set aside, until the app retries or discards it.
@interface ODataSyncIssue : NSObject
@property (nonatomic, readonly, copy) NSString *remoteIdentifier;
@property (nonatomic, readonly, copy) NSString *entityName;
@property (nonatomic, readonly, copy) NSDictionary<NSString *, id> *key;   // by Core Data attribute name
@property (nonatomic, readonly) ODataSyncOperation operation;
@property (nonatomic, readonly) NSInteger status;
// The service's own words: its OData error's message.
@property (nonatomic, readonly, copy) NSString *message;
// The object, while it exists.
@property (nonatomic, readonly, strong, nullable) NSManagedObjectID *objectID;
@end

// What one sync did, for the app to say.
@interface ODataSyncResult : NSObject
@property (nonatomic, readonly) NSUInteger downloaded;  // objects inserted or changed from remotes
@property (nonatomic, readonly) NSUInteger removed;     // objects deleted because remotes did
@property (nonatomic, readonly) NSUInteger uploaded;    // changes remotes took
@property (nonatomic, readonly) NSUInteger refused;     // changes set aside (issues)
@property (nonatomic, readonly) NSUInteger conflicts;   // settled by the policy
@end

@protocol ODataSyncDelegate <NSObject>
@optional
// A change set aside; its issue says why. On the engine's thread.
- (void)syncEngine:(ODataSyncEngine *)engine didSetAside:(ODataSyncIssue *)issue;
// A local change to a down entity, which is not sent.
- (void)syncEngine:(ODataSyncEngine *)engine ignoredLocalChangeToObject:(NSManagedObjectID *)objectID;
@end

@interface ODataSyncEngine : NSObject

// The engine's own entities, added to the model before a coordinator uses
// it, in the configuration the synced entities' store has (nil: the
// default one).
+ (void)addBookkeepingToModel:(NSManagedObjectModel *)model configuration:(nullable NSString *)configuration;

// The coordinator's store (the one with the synced entities) must keep
// persistent history (NSPersistentHistoryTrackingKey).
- (instancetype)initWithCoordinator:(NSPersistentStoreCoordinator *)coordinator NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSPersistentStoreCoordinator *coordinator;
@property (nonatomic, readonly, copy) NSArray<ODataSyncRemote *> *remotes;
- (void)addRemote:(ODataSyncRemote *)remote;
// How a both entity's conflicts are settled, when neither code nor its
// ODataSync.conflicts says: the resolver, else the policy.
@property (nonatomic) ODataSyncConflictPolicy conflictPolicy;
@property (nonatomic, strong, nullable) id<ODataSyncResolving> resolver;
- (void)setResolver:(nullable id<ODataSyncResolving>)resolver forEntityName:(NSString *)entityName;
// This store's replica ID: in its metadata, made the first time.
@property (nonatomic, readonly, copy) NSString *replicaID;
@property (nonatomic, weak, nullable) id<ODataSyncDelegate> delegate;

// Each remote in turn: what changed there brought down, then what changed
// here sent up. Synchronous: call it off the main thread. NO, with the
// error, when a remote cannot be reached or refuses as a whole (401); what
// was done until then is kept, and the next sync goes on from there. One
// at a time: a call made while one runs waits for it.
- (BOOL)syncWithError:(NSError **)error;
// The same, on a thread of its own; the action gets the result, or the
// error, on the main thread:
//   - (void)syncDidFinish:(ODataSyncResult *)result error:(NSError *)error;
- (void)syncWithTarget:(id)target action:(SEL)action;
@property (nonatomic, readonly, strong, nullable) ODataSyncResult *lastResult;

// The halves, for one remote.
- (BOOL)downloadFromRemote:(ODataSyncRemote *)remote error:(NSError **)error;
- (BOOL)uploadToRemote:(ODataSyncRemote *)remote error:(NSError **)error;
// Each scoped set's keys read again, and compared: local rows the remote
// no longer gives deleted, rows it gives that are missing read
// (docs/offline-sync.md, 4.1). After a change of user, or now and then.
- (BOOL)reconcileWithRemote:(ODataSyncRemote *)remote error:(NSError **)error;

// The changes set aside, oldest first.
- (NSArray<ODataSyncIssue *> *)issues;
// Sent again at the next sync (after the app put the object right; a new
// change to the object does this too).
- (void)retryIssue:(ODataSyncIssue *)issue;
// Forgotten: never sent. The object stays as it is locally; a conflict's
// object is read again from the remote at the next sync.
- (void)discardIssue:(ODataSyncIssue *)issue;

@end

NS_ASSUME_NONNULL_END
