// ODataIncrementalStore — streams: media entities and stream properties.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Streams (Part 1 section 11.1.2) are blobs: a media entity's media
// resource (HasStream="true", at Entity(1)/$value) and stream properties
// (Edm.Stream, at Entity(1)/Photo). They stay out of Core Data: a row
// keeps only what the service says of each, its links, media ETag and
// content type, and a transfer downloads one into a file or uploads one
// from a file.
//
//   ODataStreamTransfer *photo = [[ODataStreamTransfer alloc] initWithObject:person stream:@"Photo"];
//   NSURL *file = [photo download:&error];
//
//   ODataStreamTransfer *upload = [[ODataStreamTransfer alloc] initWithEntityName:@"Picture" context:context];
//   [upload uploadFile:png contentType:@"image/png" error:&error];   // a new media entity: upload.object
//
// A download goes into the store's stream directory
// (ODataIncrementalStoreStreamDirectoryOption) and is kept there while the
// stream's media ETag is current: downloading again costs nothing, or, when
// the row gave no ETag, a request answered 304. An upload is a PUT with
// If-Match when the media ETag is known. A new media entity is POSTed with
// its stream; its other properties are then set on the object and saved as
// any change is.
//
// Each call waits, or, with a target and action, does not: the action
// arrives on the context's queue with the transfer, its fileURL or error
// set. Call either on the context's queue.

#pragma once
#import <ODataKit/OISCoreData.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataStreamTransfer : NSObject

// A stream of a saved object: its media resource (name nil), or a stream
// property by its name in $metadata.
- (instancetype)initWithObject:(NSManagedObject *)object stream:(nullable NSString *)name;
// A media entity of the entity, made by the first upload.
- (instancetype)initWithEntityName:(NSString *)entityName context:(NSManagedObjectContext *)context;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly, strong, nullable) NSManagedObject *object;
@property (nonatomic, readonly, copy, nullable) NSString *name;
@property (nonatomic, readonly, strong) NSManagedObjectContext *context;
// What the object's row said of the stream, or the last transfer found.
@property (nonatomic, readonly, copy, nullable) NSString *mediaETag;
@property (nonatomic, readonly, copy, nullable) NSString *contentType;
// The file a download left the stream in.
@property (nonatomic, readonly, copy, nullable) NSURL *fileURL;
@property (nonatomic, readonly, strong, nullable) NSError *error;

// nil with ODataIncrementalStoreErrorNoStream when there is nothing in it.
- (nullable NSURL *)download:(NSError **)error;
- (void)downloadWithTarget:(id)target action:(SEL)action;
- (BOOL)uploadFile:(NSURL *)file contentType:(NSString *)contentType error:(NSError **)error;
- (void)uploadFile:(NSURL *)file contentType:(NSString *)contentType target:(id)target action:(SEL)action;
// A stream property emptied (DELETE); a media entity is deleted whole, as
// any object is.
- (BOOL)remove:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
