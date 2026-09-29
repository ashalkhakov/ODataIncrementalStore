// ODataIncrementalStore — what the library's own classes may use of the
// store, beyond its public interface.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "ODataIncrementalStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataIncrementalStore ()
@property (nonatomic, readonly) ODataClient *client;
@property (nonatomic, readonly) ODataPropertyMapper *mapper;
// What writes the store's queries, typed, and their URLs.
@property (nonatomic, readonly) ODataQueryBuilder *builder;

// The one way the store reads: typed options, written into a GET of a
// path (by the builder), every page of the answer read (limit and
// pageSize as -rowsAtURL:), and the URL it was, for messages.
- (nullable NSArray *)rowsForPath:(NSString *)path options:(nullable ODataQueryOptions *)options
                            limit:(NSUInteger)limit pageSize:(NSUInteger)pageSize
                              URL:(NSURL * _Nullable * _Nullable)url error:(NSError **)error;
// Rows as the object IDs of entities of an entity (or of the sub-entity
// each names), each row kept, and what it expanded; nil and the error for
// a row that is no entity.
- (nullable NSArray<NSManagedObjectID *> *)objectIDsForRows:(NSArray *)rows entity:(NSEntityDescription *)entity
                                                        URL:(nullable NSURL *)url error:(NSError **)error;

// The object ID for a row, of the sub-entity its @odata.type names; its
// ETag and edit link are remembered.
- (nullable NSManagedObjectID *)objectIDFromPayload:(NSDictionary *)payload
                                             entity:(NSEntityDescription *)entity
                                              error:(NSError **)error;
// Keeps a row, which the object's next fault is filled from.
- (NSIncrementalStoreNode *)cacheNodeForObjectID:(NSManagedObjectID *)objectID
                                          entity:(NSEntityDescription *)entity
                                         payload:(NSDictionary *)payload
                                           error:(NSError **)error;
// Every row of a collection, following next links.
- (nullable NSArray *)rowsAtURL:(NSURL *)url limit:(NSUInteger)limit pageSize:(NSUInteger)pageSize error:(NSError **)error;
// Where an object is read and written: its edit link, else its canonical URL.
- (nullable NSURL *)editURLForObjectID:(NSManagedObjectID *)objectID error:(NSError **)error;
// Its canonical URL, for a reference to it (@odata.id).
- (nullable NSURL *)canonicalURLForObjectID:(NSManagedObjectID *)objectID error:(NSError **)error;

// Streams, for ODataStreamTransfer. A stream is named as $metadata names
// it; @"" is a media entity's media resource.
// The name as the object's type has it, or nil with an error.
- (nullable NSString *)streamNamed:(nullable NSString *)name objectID:(NSManagedObjectID *)objectID error:(NSError **)error;
// What the object's last row said of it: mediaReadLink, mediaEditLink,
// mediaEtag, mediaContentType, as far as it said.
- (NSDictionary<NSString *, NSString *> *)streamInfo:(NSString *)name objectID:(NSManagedObjectID *)objectID;
// Downloaded into the stream directory, or the file already there while
// its media ETag is current; nil with ODataIncrementalStoreErrorNoStream
// when there is nothing in it.
- (nullable NSURL *)fileForStream:(NSString *)name objectID:(NSManagedObjectID *)objectID
                      contentType:(NSString * _Nullable * _Nullable)contentType
                            error:(NSError **)error;
// PUT (data) or DELETE (nil), with If-Match when its media ETag is known.
- (BOOL)putStream:(NSString *)name objectID:(NSManagedObjectID *)objectID data:(nullable NSData *)data
      contentType:(nullable NSString *)contentType error:(NSError **)error;
// POST a new media entity of the entity's set: its object ID, the row the
// service answered with kept.
- (nullable NSManagedObjectID *)postMediaEntity:(NSEntityDescription *)entity data:(NSData *)data
                                    contentType:(NSString *)contentType error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
