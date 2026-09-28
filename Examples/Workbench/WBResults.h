// The Workbench's results: a query's answer, a screenful at a time, and
// what can be done with it: edits and saves, the service's operations,
// application time's actions, streams, and the service's own changes. No
// views: the window controller shows them.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "WBConnection.h"

NS_ASSUME_NONNULL_BEGIN

@interface WBResults : NSObject

- (instancetype)initWithConnection:(WBConnection *)connection NS_DESIGNATED_INITIALIZER;
@property (nonatomic, readonly) WBConnection *connection;

#pragma mark The rows

// Managed objects, object IDs, dictionaries, or a count, as the request
// asked; new objects not yet saved first.
@property (nonatomic, readonly) NSArray *rows;
// How many there are in all ($count, within $skip and $top), where asked.
@property (nonatomic, readonly, nullable) NSNumber *total;
@property (nonatomic, readonly) BOOL hasMore;
// Why the last fetch failed; nil when it did not.
@property (nonatomic, readonly, copy, nullable) NSString *lastError;

// No rows, and no request.
- (void)clear;
// A request's answer: its count, or its first page of so many rows. NO,
// with lastError, when it fails.
- (BOOL)fetch:(NSFetchRequest *)request pageSize:(NSUInteger)pageSize;
// A query sent as written (ODataQuery): all its rows at once, objects or
// dictionaries, a dictionary's nested paths flattened (SalesOrganization/ID).
- (BOOL)runQuery:(ODataQuery *)query;
// The next page, after the rows there are.
- (BOOL)loadPageOfSize:(NSUInteger)pageSize;
// 20 of 77 Product — scroll for more; count = 3.
- (NSString *)statusFor:(NSString *)entityName;
// The object a row stands for, where it stands for one.
- (nullable NSManagedObject *)objectAtRow:(NSInteger)row;

#pragma mark Writing

- (NSUInteger)pendingCount;
// Unsaved: 1 new, 0 changed, 0 deleted. …; nil when there is nothing.
- (nullable NSString *)pendingSummary;
// A new object, first among the rows, with an empty value for each
// required attribute.
- (NSManagedObject *)insertObjectOf:(NSEntityDescription *)entity;
- (void)deleteObject:(NSManagedObject *)object;
// A row's attribute set, typed from what a cell holds; nil, or why not.
- (nullable NSString *)setValue:(id)value forKey:(NSString *)key ofRow:(NSInteger)row;
// The changes saved; nil when they are, else why not. A save refused for
// conflicts gives them.
- (nullable NSString *)save:(NSArray<NSMergeConflict *> * _Nullable * _Nullable)conflicts;
- (void)revert;
// Each conflict: what is yours, what the service has now.
- (NSString *)describeConflicts:(NSArray<NSMergeConflict *> *)conflicts;

#pragma mark Operations

// What can be called now: an object's bound operations, its entity's
// collection-bound ones, Temporal's actions on an entity with application
// time, the service's own. Each [title, what to call].
- (NSArray<NSArray *> *)operationsForObject:(nullable NSManagedObject *)object entity:(nullable NSEntityDescription *)entity;
// One of them called; the inspector's text, or nil and why not.
- (nullable NSString *)invoke:(NSDictionary *)what object:(nullable NSManagedObject *)object
                   parameters:(NSDictionary *)parameters status:(NSString * _Nullable * _Nonnull)status;
// name=value, name=value: numbers as numbers, true and false, 'quoted' or
// bare text as strings.
+ (NSDictionary *)parametersFromText:(NSString *)text;

#pragma mark Streams

// An entity's streams: "" for its media resource ($value), then its
// stream properties, as $metadata names them.
- (NSArray<NSString *> *)streamNamesOf:(nullable NSEntityDescription *)entity;
// A stream downloaded: the inspector's text, and its data and content
// type; nil, and why not.
- (nullable NSString *)download:(NSString *)stream of:(NSManagedObject *)object data:(NSData * _Nullable * _Nonnull)data
                    contentType:(NSString * _Nullable * _Nonnull)contentType status:(NSString * _Nullable * _Nonnull)status;
// A file into an object's stream (PUT, with its media ETag), or, with no
// object, a new media entity of the entity (POST), first among the rows.
- (BOOL)upload:(NSURL *)file into:(NSString *)stream of:(nullable NSManagedObject *)object entity:(NSEntityDescription *)entity
        status:(NSString * _Nullable * _Nonnull)status;

#pragma mark Changes at the service

// Merged into the context; the status line's words.
- (NSString *)mergeRemoteChanges:(BOOL * _Nullable)changed;

@end

NS_ASSUME_NONNULL_END
