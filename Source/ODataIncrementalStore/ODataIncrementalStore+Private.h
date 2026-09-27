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
@end

NS_ASSUME_NONNULL_END
