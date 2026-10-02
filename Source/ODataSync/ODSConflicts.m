// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Conflicts (docs/offline-sync.md, 6): a both object changed here and at
// a remote since the version both last agreed on (the shadow's). Found on
// download (a row of an object with an outbox entry) and on upload (412);
// settled here, the same way, by the entity's resolver.

#import "ODSInternal.h"

NSString * const ODataSyncConflictsKey = @"ODataSync.conflicts";
NSString * const ODataSyncModifiedKey = @"ODataSync.modified";

#pragma mark - Conflicts and resolutions

@implementation ODataSyncConflict

- (instancetype)initWithEntity:(NSEntityDescription *)entity key:(NSDictionary *)key base:(NSDictionary *)base
                         local:(NSDictionary *)local remote:(NSDictionary *)remote
                  localChanges:(NSSet *)localChanges remoteChanges:(NSSet *)remoteChanges withPeer:(BOOL)withPeer
{
  self = [super init];
  if (!self) return nil;
  _entity = entity;
  _key = [key copy];
  _base = [base copy];
  _local = [local copy];
  _remote = [remote copy];
  _localChanges = [localChanges copy];
  _remoteChanges = [remoteChanges copy];
  _withPeer = withPeer;
  return self;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataSyncConflict %@ %@: here %@, there %@>", _entity.name, _key,
                                    _local ? _localChanges : @"deleted", _remote ? _remoteChanges : @"deleted"];
}

@end

@implementation ODataSyncResolution

- (instancetype)initWithKind:(ODataSyncResolutionKind)kind values:(NSDictionary *)values
{
  self = [super init];
  if (!self) return nil;
  _kind = kind;
  _values = [values copy];
  return self;
}

+ (instancetype)takeRemote
{
  return [[self alloc] initWithKind:ODataSyncTakeRemote values:nil];
}

+ (instancetype)keepLocal
{
  return [[self alloc] initWithKind:ODataSyncKeepLocal values:nil];
}

+ (instancetype)mergedValues:(NSDictionary *)values
{
  return [[self alloc] initWithKind:ODataSyncMerge values:values ?: @{}];
}

+ (instancetype)defer
{
  return [[self alloc] initWithKind:ODataSyncDefer values:nil];
}

@end

#pragma mark - Resolvers

@implementation ODataSyncRemoteWins
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  return [ODataSyncResolution takeRemote];
}
@end

@implementation ODataSyncLocalWins
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  return [ODataSyncResolution keepLocal];
}
@end

// Values as text, in the order of their names: the same on every side.
static NSString *ODSFingerprint(NSDictionary *values)
{
  NSMutableString *text = [NSMutableString string];
  for (NSString *name in [values.allKeys sortedArrayUsingSelector:@selector(compare:)]) [text appendFormat:@"%@=%@;", name, values[name]];
  return text;
}

@implementation ODataSyncLastWriterWins
- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  NSString *name = conflict.entity.userInfo[ODataSyncModifiedKey];
  for (NSEntityDescription *e = conflict.entity.superentity; !name && e; e = e.superentity) name = e.userInfo[ODataSyncModifiedKey];
  id local = name ? conflict.local[name] : nil;
  id remote = name ? conflict.remote[name] : nil;
  // A delete has no stamp of its own: the other side's change stands.
  if (!conflict.local && conflict.remote) return [ODataSyncResolution takeRemote];
  if (!conflict.remote && conflict.local) return [ODataSyncResolution keepLocal];
  NSComparisonResult order = [local isKindOfClass:[NSString class]] && [remote isKindOfClass:[NSString class]] ? [local compare:remote]
                                                                                                           : NSOrderedSame;
  // No stamps to tell (or the same): the service's, from a service; from a
  // peer, the same side whichever asks, by the values.
  if (order == NSOrderedSame && conflict.withPeer) order = [ODSFingerprint(conflict.local) compare:ODSFingerprint(conflict.remote)];
  return order == NSOrderedDescending ? [ODataSyncResolution keepLocal] : [ODataSyncResolution takeRemote];
}
@end

@implementation ODataSyncMergeFields

- (instancetype)initWithFallback:(id<ODataSyncResolving>)fallback
{
  self = [super init];
  if (!self) return nil;
  _fallback = fallback;
  return self;
}

- (instancetype)init
{
  return [self initWithFallback:[[ODataSyncRemoteWins alloc] init]];
}

- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  if (!conflict.base || !conflict.local || !conflict.remote) return [self.fallback resolveConflict:conflict];
  NSMutableDictionary *merged = [NSMutableDictionary dictionary];
  ODataSyncResolution *overlap = nil;
  NSMutableSet *names = [NSMutableSet setWithSet:conflict.localChanges];
  [names unionSet:conflict.remoteChanges];
  for (NSString *name in names) {
    BOOL here = [conflict.localChanges containsObject:name], there = [conflict.remoteChanges containsObject:name];
    id local = conflict.local[name] ?: [NSNull null], remote = conflict.remote[name] ?: [NSNull null];
    if (here && there && ![local isEqual:remote]) {
      // Both changed it, differently: as the fallback has the whole object.
      if (!overlap) overlap = [self.fallback resolveConflict:conflict];
      if (overlap.kind == ODataSyncDefer) return overlap;
      if (overlap.kind == ODataSyncMerge) merged[name] = overlap.values[name] ?: local;
      else merged[name] = overlap.kind == ODataSyncKeepLocal ? local : remote;
    } else {
      merged[name] = here ? local : remote;
    }
  }
  return [ODataSyncResolution mergedValues:merged];
}

@end

#pragma mark - Settling

@implementation ODataSyncEngine (ODSConflicts)

// Between peers neither side is the authority, and each asks in turn: a
// rule must choose the same version whichever side asks, or the two swap
// forever. The remote's or this side's are not such; last writer wins is.
- (id<ODataSyncResolving>)resolverFor:(NSEntityDescription *)root remote:(ODataSyncRemote *)remote
{
  id<ODataSyncResolving> resolver = [self resolverFor:root];
  if (!remote.peer) return resolver;
  BOOL (^sided)(id) = ^BOOL(id rule) {
    return [rule isKindOfClass:[ODataSyncRemoteWins class]] || [rule isKindOfClass:[ODataSyncLocalWins class]];
  };
  if (sided(resolver)) return [[ODataSyncLastWriterWins alloc] init];
  if ([resolver isKindOfClass:[ODataSyncMergeFields class]] && sided(((ODataSyncMergeFields *)resolver).fallback)) {
    return [[ODataSyncMergeFields alloc] initWithFallback:[[ODataSyncLastWriterWins alloc] init]];
  }
  return resolver;
}

- (id<ODataSyncResolving>)resolverFor:(NSEntityDescription *)root
{
  id<ODataSyncResolving> resolver = [self resolverForEntityName:root.name];
  if (resolver) return resolver;
  NSString *named = [root.userInfo[ODataSyncConflictsKey] lowercaseString];
  if ([named isEqualToString:@"local"]) return [[ODataSyncLocalWins alloc] init];
  if ([named isEqualToString:@"lastwriter"]) return [[ODataSyncLastWriterWins alloc] init];
  if ([named isEqualToString:@"merge"]) return [[ODataSyncMergeFields alloc] init];
  if ([named isEqualToString:@"remote"]) return [[ODataSyncRemoteWins alloc] init];
  if (self.resolver) return self.resolver;
  return self.conflictPolicy == ODataSyncPolicyLocalWins ? [[ODataSyncLocalWins alloc] init] : [[ODataSyncRemoteWins alloc] init];
}

- (void)agreeOn:(NSDictionary *)row etag:(NSString *)etag of:(NSEntityDescription *)root keyText:(NSString *)keyText
         remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context
{
  NSManagedObject *shadow = [self shadowOf:root.name keyText:keyText remote:remote inContext:context make:row != nil];
  if (!row) {
    if (shadow) [context deleteObject:shadow];
    return;
  }
  if (etag) [shadow setValue:etag forKey:@"etag"];
  [shadow setValue:[NSJSONSerialization dataWithJSONObject:row options:0 error:NULL] forKey:@"values"];
}

// The outbox entry, after a resolution: what this side still has to send
// over the remote's version (nothing: gone).
- (void)sendWhatDiffers:(NSManagedObject *)object from:(NSDictionary *)remoteValues entry:(NSManagedObject *)entry
                context:(NSManagedObjectContext *)context
{
  if (!remoteValues) {
    // Deleted there: made again, whole.
    [entry setValue:@(ODataSyncOperationInsert) forKey:@"operation"];
    [entry setValue:nil forKey:@"properties"];
    return;
  }
  NSSet *differ = ODSChangedNames([self.codec valuesOfObject:object], remoteValues);
  if (!differ.count) {
    [context deleteObject:entry];
    return;
  }
  [entry setValue:@(ODataSyncOperationUpdate) forKey:@"operation"];
  [entry setValue:ODSArchive(differ.allObjects) forKey:@"properties"];
}

- (BOOL)keepNewerThan:(NSDictionary *)row etag:(NSString *)etag of:(NSEntityDescription *)root key:(NSDictionary *)key
               remote:(ODataSyncRemote *)remote context:(NSManagedObjectContext *)context
{
  ODSCodec *codec = self.codec;
  NSAttributeDescription *stamp = [codec modifiedAttributeOf:root];
  NSManagedObject *object = stamp && remote.peer ? [codec objectOfEntity:root key:key inContext:context] : nil;
  id ours = [object valueForKey:stamp.name], theirs = row[[codec.mapper propertyForAttribute:stamp]];
  if (![ours isKindOfClass:[NSString class]] || ![theirs isKindOfClass:[NSString class]] || [ours compare:theirs] != NSOrderedDescending) return NO;
  // Older than this side's: a peer a step behind (what it has came round
  // from where this side's went). Taken, it would go round again.
  NSString *keyText = [codec keyTextOf:key entity:root];
  [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
  NSManagedObject *entry = [NSEntityDescription insertNewObjectForEntityForName:ODSOutboxEntity inManagedObjectContext:context];
  NSFetchRequest *last = [NSFetchRequest fetchRequestWithEntityName:ODSOutboxEntity];
  last.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"sequence" ascending:NO] ];
  last.fetchLimit = 1;
  int64_t sequence = [[[[context executeFetchRequest:last error:NULL] firstObject] valueForKey:@"sequence"] longLongValue] + 1;
  [entry setValue:remote.identifier forKey:@"remote"];
  [entry setValue:root.name forKey:@"entityType"];
  [entry setValue:ODSArchive(key) forKey:@"key"];
  [entry setValue:keyText forKey:@"keyText"];
  [entry setValue:@(sequence) forKey:@"sequence"];
  [self sendWhatDiffers:object from:[codec valuesFromJSON:row entity:root] entry:entry context:context];
  return YES;
}

- (void)settleConflictOf:(NSEntityDescription *)root key:(NSDictionary *)key entry:(NSManagedObject *)entry
               remoteRow:(NSDictionary *)row etag:(NSString *)etag remote:(ODataSyncRemote *)remote
                 context:(NSManagedObjectContext *)context
{
  ODSCodec *codec = self.codec;
  NSString *keyText = [codec keyTextOf:key entity:root];
  NSManagedObject *shadow = [self shadowOf:root.name keyText:keyText remote:remote inContext:context make:NO];
  NSData *kept = [shadow valueForKey:@"values"];
  id baseRow = kept.length ? [NSJSONSerialization JSONObjectWithData:kept options:0 error:NULL] : nil;
  NSDictionary *base = [baseRow isKindOfClass:[NSDictionary class]] ? [codec valuesFromJSON:baseRow entity:root] : nil;
  BOOL deletedHere = [[entry valueForKey:@"operation"] integerValue] == ODataSyncOperationDelete;
  NSManagedObject *object = deletedHere ? nil : [codec objectOfEntity:root key:key inContext:context];
  NSDictionary *local = object ? [codec valuesOfObject:object] : nil;
  NSDictionary *remoteValues = row ? [codec valuesFromJSON:row entity:root] : nil;
  NSAttributeDescription *stamp = [codec modifiedAttributeOf:root];
  if (stamp && remoteValues) [self witness:remoteValues[stamp.name]];

  // The same on both sides: nothing to settle; that is the version agreed on.
  if ((!local && !remoteValues) || (local && remoteValues && !ODSChangedNames(local, remoteValues).count)) {
    [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
    [context deleteObject:entry];
    return;
  }
  // Only this side changed it (the remote's is the version agreed on, read
  // again): no conflict; the change goes as it is, over that version.
  if (base && remoteValues && !ODSChangedNames(base, remoteValues).count) {
    [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
    return;
  }
  NSArray *all = [[[codec attributesOf:root] valueForKey:@"name"] arrayByAddingObjectsFromArray:[[codec toOnesOf:root] valueForKey:@"name"]];
  NSSet *everything = [NSSet setWithArray:all];
  NSSet *localChanges = base && local ? ODSChangedNames(base, local) : everything;
  NSSet *remoteChanges = base && remoteValues ? ODSChangedNames(base, remoteValues) : everything;
  ODataSyncConflict *conflict = [[ODataSyncConflict alloc] initWithEntity:root key:key base:base local:local remote:remoteValues
                                                             localChanges:localChanges remoteChanges:remoteChanges
                                                                 withPeer:remote.peer];
  ODataSyncResolution *resolution = [[self resolverFor:root remote:remote] resolveConflict:conflict] ?: [ODataSyncResolution takeRemote];
  [self count:@"conflicts" by:1];
  switch (resolution.kind) {
    case ODataSyncTakeRemote:
      if (row) {
        if (!object) {
          object = [codec objectOfEntity:root key:key inContext:context];
          if (!object) {
            object = [[NSManagedObject alloc] initWithEntity:root insertIntoManagedObjectContext:context];
            for (NSString *name in key) [object setValue:key[name] forKey:name];
          }
        }
        [codec applyJSON:row toObject:object];
      } else if ((object = [codec objectOfEntity:root key:key inContext:context])) {
        [context deleteObject:object];
      }
      [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
      [context deleteObject:entry];
      break;
    case ODataSyncKeepLocal:
      [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
      if (!object) {
        // Deleted here: a deletion, now of the remote's version; nothing when gone there too.
        if (row) [entry setValue:@(ODataSyncOperationDelete) forKey:@"operation"]; else [context deleteObject:entry];
      } else {
        [self sendWhatDiffers:object from:remoteValues entry:entry context:context];
      }
      break;
    case ODataSyncMerge: {
      if (!object) {
        object = [codec objectOfEntity:root key:key inContext:context];
        if (!object) {
          object = [[NSManagedObject alloc] initWithEntity:root insertIntoManagedObjectContext:context];
          for (NSString *name in key) [object setValue:key[name] forKey:name];
        }
      }
      [codec applyValues:resolution.values ?: @{} toObject:object];
      if (stamp && [resolution.values objectForKey:stamp.name] == nil) [object setValue:[self tick] forKey:stamp.name];
      [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
      [self sendWhatDiffers:object from:remoteValues entry:entry context:context];
      break;
    }
    case ODataSyncDefer:
      // The remote's version is the one a retry goes over.
      [self agreeOn:row etag:etag of:root keyText:keyText remote:remote context:context];
      [entry setValue:@YES forKey:@"setAside"];
      [entry setValue:@409 forKey:@"status"];
      [entry setValue:@"Changed here and at the service: a conflict to settle" forKey:@"message"];
      [self setAside:[[ODataSyncIssue alloc] initWithEntry:entry objectID:object.objectID]];
      break;
  }
}

@end
