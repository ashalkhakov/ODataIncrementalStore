// ODataIncrementalStore — streams: media entities and stream properties.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataStreamTransfer.h"
#import "ODataIncrementalStore+Private.h"
#import "ODataError.h"

typedef NS_ENUM(NSInteger, OISTransferKind) {
  OISTransferDownload,
  OISTransferUpload,
  OISTransferRemove
};

@implementation ODataStreamTransfer {
  NSString *_entityName;
  // Taken on the context's queue, used on any thread.
  ODataIncrementalStore *_store;
  NSManagedObjectID *_objectID;
  NSEntityDescription *_entity;
  NSString *_stream;
  // The work.
  OISTransferKind _kind;
  NSURL *_upload;
  NSString *_uploadType;
  NSManagedObjectID *_created;
}

- (instancetype)initWithObject:(NSManagedObject *)object stream:(NSString *)name
{
  self = [super init];
  if (!self) return nil;
  _object = object;
  _name = [name copy];
  _context = object.managedObjectContext;
  return self;
}

- (instancetype)initWithEntityName:(NSString *)entityName context:(NSManagedObjectContext *)context
{
  self = [super init];
  if (!self) return nil;
  _entityName = [entityName copy];
  _context = context;
  return self;
}

#pragma mark - Waiting

- (NSURL *)download:(NSError **)error
{
  _kind = OISTransferDownload;
  if ([self prepare]) [self perform];
  [self finish];
  if (_error && error) *error = _error;
  return _error ? nil : _fileURL;
}

- (BOOL)uploadFile:(NSURL *)file contentType:(NSString *)contentType error:(NSError **)error
{
  _kind = OISTransferUpload;
  _upload = [file copy];
  _uploadType = [contentType copy];
  if ([self prepare]) [self perform];
  [self finish];
  if (_error && error) *error = _error;
  return !_error;
}

- (BOOL)remove:(NSError **)error
{
  _kind = OISTransferRemove;
  if ([self prepare]) [self perform];
  [self finish];
  if (_error && error) *error = _error;
  return !_error;
}

#pragma mark - Not waiting

- (void)downloadWithTarget:(id)target action:(SEL)action
{
  _kind = OISTransferDownload;
  [self startWithTarget:target action:action];
}

- (void)uploadFile:(NSURL *)file contentType:(NSString *)contentType target:(id)target action:(SEL)action
{
  _kind = OISTransferUpload;
  _upload = [file copy];
  _uploadType = [contentType copy];
  [self startWithTarget:target action:action];
}

// As ODataOperationCall does: the context at the start and the end, on its
// queue; the requests between on a thread of their own.
- (void)startWithTarget:(id)target action:(SEL)action
{
  BOOL prepared = [self prepare];
  NSManagedObjectContext *context = self.context;
  void (^deliver)(void) = ^{
    [self finish];
    void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:action];
    if (send) send(target, action, self);
  };
  void (^onContext)(void) = ^{
    if (context.concurrencyType == NSPrivateQueueConcurrencyType || context.concurrencyType == NSMainQueueConcurrencyType) {
      [context performBlock:deliver];
    } else {
      [self performSelectorOnMainThread:@selector(run:) withObject:[deliver copy] waitUntilDone:NO];
    }
  };
  if (!prepared) {
    onContext();
    return;
  }
  [NSThread detachNewThreadSelector:@selector(performThen:) toTarget:self withObject:[onContext copy]];
}

- (void)run:(void (^)(void))block
{
  block();
}

- (void)performThen:(void (^)(void))then
{
  @autoreleasepool {
    [self perform];
    then();
  }
}

#pragma mark - The steps

- (BOOL)fail:(ODataIncrementalStoreErrorCode)code message:(NSString *)message
{
  _error = OISError(code, message);
  return NO;
}

// On the context's queue: the store, the object's ID, the stream's name.
- (BOOL)prepare
{
  _error = nil;
  if (_object) {
    _objectID = _object.objectID;
    if (_objectID.isTemporaryID) return [self fail:ODataIncrementalStoreErrorUnsupportedRequest message:@"A stream is of a saved object"];
    _store = [_objectID.persistentStore isKindOfClass:[ODataIncrementalStore class]] ? (ODataIncrementalStore *)_objectID.persistentStore : nil;
  } else {
    _entity = self.context.persistentStoreCoordinator.managedObjectModel.entitiesByName[_entityName ?: @""];
    if (!_entity) return [self fail:ODataIncrementalStoreErrorModelMismatch message:[NSString stringWithFormat:@"No entity %@", _entityName]];
    if (_kind != OISTransferUpload) return [self fail:ODataIncrementalStoreErrorNoStream message:@"A media entity yet to be has no stream to read"];
    for (NSPersistentStore *store in self.context.persistentStoreCoordinator.persistentStores) {
      if ([store isKindOfClass:[ODataIncrementalStore class]]) _store = (ODataIncrementalStore *)store;
    }
  }
  if (!_store) return [self fail:ODataIncrementalStoreErrorUnsupportedRequest message:@"Streams are an ODataIncrementalStore's"];
  if (_objectID) {
    NSError *error = nil;
    _stream = [_store streamNamed:_name objectID:_objectID error:&error];
    if (!_stream) {
      _error = error;
      return NO;
    }
    if (_kind == OISTransferRemove && !_stream.length) return [self fail:ODataIncrementalStoreErrorUnsupportedRequest message:@"A media entity is deleted whole"];
    [self takeInfo];
  }
  return YES;
}

- (void)takeInfo
{
  NSDictionary *info = [_store streamInfo:_stream objectID:_objectID];
  _mediaETag = [info[@"mediaEtag"] copy];
  _contentType = [info[@"mediaContentType"] copy];
}

// Anywhere: the requests.
- (void)perform
{
  NSError *error = nil;
  switch (_kind) {
    case OISTransferDownload: {
      NSString *type = nil;
      _fileURL = [_store fileForStream:_stream objectID:_objectID contentType:&type error:&error];
      if (!_fileURL) _error = error;
      break;
    }
    case OISTransferUpload: {
      NSData *data = [NSData dataWithContentsOfURL:_upload options:NSDataReadingMappedIfSafe error:&error];
      if (!data) {
        _error = error;
        break;
      }
      if (_objectID) {
        if (![_store putStream:_stream objectID:_objectID data:data contentType:_uploadType error:&error]) _error = error;
      } else {
        _created = [_store postMediaEntity:_entity data:data contentType:_uploadType error:&error];
        if (!_created) _error = error;
      }
      break;
    }
    case OISTransferRemove:
      if (![_store putStream:_stream objectID:_objectID data:nil contentType:nil error:&error]) _error = error;
      break;
  }
}

// On the context's queue: a new media entity as an object in it.
- (void)finish
{
  if (_error) return;
  if (_created) {
    _object = [self.context objectWithID:_created];
    _objectID = _created;
    _created = nil;
    _stream = @"";
  }
  if (_store && _objectID) [self takeInfo];
}

@end
