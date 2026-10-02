// ODataSyncPeerServer — a device's store, served to its peers
// (docs/offline-sync.md, 7).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// An ODataService over the engine's store, on HTTPServerKit, so that other
// devices can add it as a peer remote (+[ODataSyncRemote
// peerWithServiceRoot:]) and sync with it as with the service:
//
//   ODataSyncPeerServer *peers = [[ODataSyncPeerServer alloc] initWithEngine:sync host:@"192.168.1.20" port:8642];
//   peers.service.authenticator = ...;     // who may sync: the app's to decide
//   [peers start:&error];
//   ... advertise peers.serviceRoot (Bonjour, a QR code) ...
//
// Its sets are the synced entities' (the engine's bookkeeping is not
// served); down sets are read only. What a peer sends is written as coming
// from that peer (ODataSyncReplicaHeader), so it is passed on to the
// service and the other peers, not back; its ODataSync.modified stamps are
// kept, and move this side's clock past them. Discovery and trust are the
// app's.

#pragma once
#import <ODataSync/ODataSyncEngine.h>

@class ODataService;

NS_ASSUME_NONNULL_BEGIN

@interface ODataSyncPeerServer : NSObject
// At http://<host>:<port>/sync/<replica ID>/: the host the peers reach
// this device at.
- (instancetype)initWithEngine:(ODataSyncEngine *)engine host:(NSString *)host port:(NSUInteger)port NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataSyncEngine *engine;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
// Configure it before starting (an authenticator, limits); in the process,
// it is a remote's transport too.
@property (nonatomic, readonly) ODataService *service;
- (BOOL)start:(NSError **)error;
- (void)stop;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@end

NS_ASSUME_NONNULL_END
