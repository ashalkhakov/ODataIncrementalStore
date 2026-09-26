// Snapshot HTTP transport — no network.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Each JSON file is one OData v4 request/response pair. Matching is
// method + path relative to the service root + query dictionary.
// Bodies (POST/PATCH) are compared as JSON objects.

#pragma once
#import "ODataClient.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataSnapshotTransport : NSObject <ODataTransport>
@property (nonatomic, copy) NSURL *serviceRoot;
@property (nonatomic, readonly) NSArray<NSString *> *snapshotNames;
@property (nonatomic, readonly) NSArray<NSString *> *hits;
// Requests answered with an error a real service would send: missing
// version headers, a body that is not JSON, an Accept it cannot meet.
@property (nonatomic, readonly) NSArray<NSString *> *refusals;
// $batch, as a service implements it: each request of the change set is
// answered from the snapshots, and the change set fails whole if any of
// them does. One entry per batch: the number of requests in it.
@property (nonatomic, readonly) NSArray<NSNumber *> *batches;
// Answer $batch with 404, as a service without it does.
@property (nonatomic) BOOL refusesBatches;

- (nullable instancetype)initWithDirectory:(NSString *)directory
                               serviceRoot:(NSURL *)serviceRoot
                                     error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable NSDictionary *)snapshotNamed:(NSString *)name;
// The answer to one request, synchronously; -startExchange: is built on it.
- (nullable NSData *)sendRequest:(NSURLRequest *)request
               returningResponse:(NSURLResponse * _Nullable * _Nullable)response
                           error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
