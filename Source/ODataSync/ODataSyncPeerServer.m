// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Peers (docs/offline-sync.md, 7): the engine's store as an ODataService,
// each synced root a set whose writes are made as coming from the peer
// that sent them.

#import "ODataSyncPeerServer.h"
#import "ODataSyncService.h"
#import "ODSInternal.h"
#import <ODataKit/ODataError.h>
#import <ODataService/ODataService.h>
#import <ODataService/ODataServer.h>
#import <HTTPServerKit/HSServer.h>

// A replica ID as a peer names it: letters, digits and dashes (a UUID).
static BOOL ODSIsReplica(NSString *text)
{
  if (!text.length || text.length > 64) return NO;
  NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                                                @"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-"];
  return [text rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

// A peer's write is made as coming from the replica the request names, so
// that the engine passes it on but not back; its stamp kept, and
// witnessed. Deletions kept and histories compared as at a service.
@interface ODSPeerSetHandler : ODataSyncSetHandler
@end

@implementation ODSPeerSetHandler

- (NSString *)authorOfRequest:(ODataRequest *)request values:(NSDictionary<NSString *, id> *)values
{
  NSString *replica = [request valueForHeader:ODataSyncReplicaHeader];
  return ODSIsReplica(replica) ? [ODataSyncDownAuthorPrefix stringByAppendingString:replica] : [super authorOfRequest:request values:values];
}

- (void)witness:(NSManagedObject *)object
{
  ODataSyncEngine *engine = self.engine;
  NSAttributeDescription *stamp = object ? [engine.codec modifiedAttributeOf:object.entity] : nil;
  if (stamp) [engine witness:[object valueForKey:stamp.name]];
}

- (NSManagedObject *)insertObjectWithValues:(NSDictionary<NSString *, id> *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSManagedObject *object = [super insertObjectWithValues:values request:request reply:reply];
  [self witness:object];
  return object;
}

- (NSManagedObject *)updateObject:(NSManagedObject *)object values:(NSDictionary<NSString *, id> *)values request:(ODataRequest *)request
                            reply:(ODataReply *)reply
{
  NSManagedObject *updated = [super updateObject:object values:values request:request reply:reply];
  [self witness:updated];
  return updated;
}

@end

@implementation ODataSyncPeerServer {
  HSServer *_server;
  NSUInteger _port;
}

- (instancetype)initWithEngine:(ODataSyncEngine *)engine host:(NSString *)host port:(NSUInteger)port
{
  self = [super init];
  if (!self) return nil;
  _engine = engine;
  _port = port;
  NSString *root = [NSString stringWithFormat:@"http://%@:%lu/sync/%@/", host, (unsigned long)port, engine.replicaID];
  _serviceRoot = [NSURL URLWithString:root];
  _service = [[ODataService alloc] initWithPersistentStoreCoordinator:engine.coordinator serviceRoot:_serviceRoot];
  // The synced entities only (the configuration +addBookkeepingToModel:
  // made): not the bookkeeping, nor what is the app's alone.
  _service.configurationName = ODataSyncPeerConfiguration;
  ODSCodec *codec = engine.codec;
  for (NSEntityDescription *entity in engine.coordinator.managedObjectModel.entities) {
    if (entity.superentity) continue;
    ODataSyncDirection direction = [codec directionOfEntity:entity];
    if (direction == ODataSyncDirectionNone) continue;
    ODSPeerSetHandler *handler = [[ODSPeerSetHandler alloc] initWithEntity:entity];
    handler.engine = engine;
    // The service's alone: a peer reads them.
    BOOL writes = direction != ODataSyncDirectionDown;
    handler.allowsInsert = writes;
    handler.allowsUpdate = writes;
    handler.allowsDelete = writes;
    handler.allowsUpsert = writes;
    [_service setHandler:handler forEntitySet:[_service.mapper entitySetForEntity:entity]];
  }
  return self;
}

- (BOOL)start:(NSError **)error
{
  if (_server.running) return YES;
  _server = [[HSServer alloc] initWithService:_service];
  return [_server startOnPort:_port error:error];
}

- (void)stop
{
  [_server stop];
  _server = nil;
}

- (BOOL)isRunning
{
  return _server.running;
}

@end
