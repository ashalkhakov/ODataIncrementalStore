// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Core Data's history classes are abstract on Apple ("create a concrete
// instance") and concrete in FreeCoreData; either way a subclass that
// answers every getter itself is one a store can hand out.

#import "ODataHistory.h"
#import "ODataError.h"

NSString * const ODataRemoteChangesAuthor = @"ODataIncrementalStore.remote";

#pragma mark - Token

@implementation ODataHistoryToken

- (instancetype)initWithStoreID:(NSString *)storeID logID:(NSString *)logID number:(int64_t)number
{
  self = [super init];
  if (!self) return nil;
  _storeID = [storeID copy];
  _logID = [logID copy];
  _transactionNumber = number;
  return self;
}

+ (BOOL)supportsSecureCoding
{
  return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  return [self initWithStoreID:[coder decodeObjectOfClass:[NSString class] forKey:@"storeID"] ?: @""
                         logID:[coder decodeObjectOfClass:[NSString class] forKey:@"logID"] ?: @""
                        number:[coder decodeInt64ForKey:@"transactionNumber"]];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
  [coder encodeObject:self.storeID forKey:@"storeID"];
  [coder encodeObject:self.logID forKey:@"logID"];
  [coder encodeInt64:self.transactionNumber forKey:@"transactionNumber"];
}

- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

// Apple's history requests ask their token for this: where it stands in
// each store's history.
- (NSDictionary *)storeTokens
{
  return @{ self.storeID ?: @"": @(self.transactionNumber) };
}

- (BOOL)isEqual:(id)other
{
  if (![other isKindOfClass:[ODataHistoryToken class]]) return NO;
  ODataHistoryToken *o = other;
  return o.transactionNumber == self.transactionNumber && [o.logID isEqualToString:self.logID];
}

- (NSUInteger)hash
{
  return (NSUInteger)self.transactionNumber ^ self.logID.hash;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataHistoryToken %@ #%lld>", self.storeID, (long long)self.transactionNumber];
}

@end

#pragma mark - Change

@implementation ODataHistoryChange {
  int64_t _changeID;
  NSManagedObjectID *_objectID;
  NSPersistentHistoryChangeType _type;
  NSSet *_updatedProperties;
  __weak NSPersistentHistoryTransaction *_transaction;
}

- (instancetype)initWithID:(int64_t)changeID type:(NSPersistentHistoryChangeType)type objectID:(NSManagedObjectID *)objectID
         updatedProperties:(NSSet *)updatedProperties
{
  self = [super init];
  if (!self) return nil;
  _changeID = changeID;
  _type = type;
  _objectID = objectID;
  _updatedProperties = [updatedProperties copy];
  return self;
}

- (void)setTransaction:(NSPersistentHistoryTransaction *)transaction
{
  _transaction = transaction;
}

- (int64_t)changeID { return _changeID; }
- (NSManagedObjectID *)changedObjectID { return _objectID; }
- (NSPersistentHistoryChangeType)changeType { return _type; }
- (NSDictionary *)tombstone { return nil; }
- (NSPersistentHistoryTransaction *)transaction { return _transaction; }
- (NSSet *)updatedProperties { return _updatedProperties; }

- (NSString *)description
{
  NSString *type = _type == NSPersistentHistoryChangeTypeInsert ? @"insert" : _type == NSPersistentHistoryChangeTypeUpdate ? @"update" : @"delete";
  return [NSString stringWithFormat:@"<ODataHistoryChange #%lld %@ %@>", (long long)_changeID, type, _objectID];
}

@end

#pragma mark - Transaction

@implementation ODataHistoryTransaction {
  int64_t _number;
  NSDate *_timestamp;
  NSArray *_changes;
  NSString *_storeID;
  NSString *_author;
  NSString *_contextName;
  ODataHistoryToken *_token;
  BOOL _withoutChanges;
}

- (instancetype)initWithNumber:(int64_t)number changes:(NSArray *)changes storeID:(NSString *)storeID
                        author:(NSString *)author contextName:(NSString *)contextName token:(ODataHistoryToken *)token
{
  self = [super init];
  if (!self) return nil;
  _number = number;
  _timestamp = [NSDate date];
  _changes = [changes copy];
  _storeID = [storeID copy];
  _author = [author copy];
  _contextName = [contextName copy];
  _token = token;
  for (ODataHistoryChange *change in _changes) [change setTransaction:self];
  return self;
}

// The same transaction, answered without its changes (TransactionsOnly).
- (instancetype)withoutChanges
{
  ODataHistoryTransaction *t = [[ODataHistoryTransaction alloc] initWithNumber:_number changes:@[] storeID:_storeID
                                                                        author:_author contextName:_contextName token:_token];
  t->_timestamp = _timestamp;
  t->_withoutChanges = YES;
  t->_changes = _changes;
  return t;
}

- (NSDate *)timestamp { return _timestamp; }
- (NSArray *)changes { return _withoutChanges ? nil : _changes; }
- (int64_t)transactionNumber { return _number; }
- (NSString *)storeID { return _storeID; }
- (NSString *)bundleID { return [NSBundle mainBundle].bundleIdentifier ?: @""; }
- (NSString *)processID { return [NSString stringWithFormat:@"%d", [NSProcessInfo processInfo].processIdentifier]; }
- (NSString *)contextName { return _contextName; }
- (NSString *)author { return _author; }
- (NSPersistentHistoryToken *)token { return _token; }

- (NSNotification *)objectIDNotification
{
  NSMutableSet *inserted = [NSMutableSet set], *updated = [NSMutableSet set], *deleted = [NSMutableSet set];
  for (ODataHistoryChange *change in _changes) {
    switch (change.changeType) {
      case NSPersistentHistoryChangeTypeInsert: [inserted addObject:change.changedObjectID]; break;
      case NSPersistentHistoryChangeTypeUpdate: [updated addObject:change.changedObjectID]; break;
      case NSPersistentHistoryChangeTypeDelete: [deleted addObject:change.changedObjectID]; break;
    }
  }
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (inserted.count) info[NSInsertedObjectIDsKey] = inserted;
  if (updated.count) info[NSUpdatedObjectIDsKey] = updated;
  if (deleted.count) info[NSDeletedObjectIDsKey] = deleted;
  return [NSNotification notificationWithName:NSManagedObjectContextDidSaveObjectIDsNotification object:nil userInfo:info];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<ODataHistoryTransaction #%lld %@ %lu changes>", (long long)_number, _author ?: @"",
                                    (unsigned long)_changes.count];
}

@end

#pragma mark - Result

// NSPersistentHistoryResult, answered by us.
@interface ODataHistoryResult : NSPersistentHistoryResult
- (instancetype)initWithResult:(id)result type:(NSPersistentHistoryResultType)type;
@end

@implementation ODataHistoryResult {
  id _result;
  NSPersistentHistoryResultType _type;
}

- (instancetype)initWithResult:(id)result type:(NSPersistentHistoryResultType)type
{
  self = [super init];
  if (!self) return nil;
  _result = result;
  _type = type;
  return self;
}

- (id)result { return _result; }
- (NSPersistentHistoryResultType)resultType { return _type; }

@end

#pragma mark - The log

@implementation ODataHistoryLog {
  NSString *_logID;
  NSMutableArray *_transactions;
  int64_t _nextChange;
  NSLock *_lock;
}

- (instancetype)initWithStoreID:(NSString *)storeID
{
  self = [super init];
  if (!self) return nil;
  _storeID = [storeID copy];
  _logID = [[NSUUID UUID] UUIDString];
  _transactions = [NSMutableArray array];
  _nextChange = 1;
  _lock = [[NSLock alloc] init];
  return self;
}

- (int64_t)lastTransactionNumber
{
  [_lock lock];
  int64_t n = [(ODataHistoryTransaction *)_transactions.lastObject transactionNumber];
  [_lock unlock];
  return n;
}

- (ODataHistoryToken *)currentToken
{
  return [[ODataHistoryToken alloc] initWithStoreID:self.storeID logID:_logID number:self.lastTransactionNumber];
}

- (NSPersistentHistoryTransaction *)recordInserted:(NSArray *)inserted
                                           updated:(NSDictionary *)updated
                                           deleted:(NSArray *)deleted
                                            author:(NSString *)author
                                       contextName:(NSString *)contextName
{
  if (!inserted.count && !updated.count && !deleted.count) return nil;
  [_lock lock];
  int64_t number = [(ODataHistoryTransaction *)_transactions.lastObject transactionNumber] + 1;
  NSMutableArray *changes = [NSMutableArray array];
  for (NSManagedObjectID *oid in inserted) {
    [changes addObject:[[ODataHistoryChange alloc] initWithID:_nextChange++ type:NSPersistentHistoryChangeTypeInsert objectID:oid updatedProperties:nil]];
  }
  for (NSManagedObjectID *oid in updated) {
    NSMutableSet *properties = nil;
    NSSet *names = updated[oid];
    if (names.count) {
      properties = [NSMutableSet set];
      for (NSString *name in names) {
        NSPropertyDescription *property = oid.entity.propertiesByName[name];
        if (property) [properties addObject:property];
      }
    }
    [changes addObject:[[ODataHistoryChange alloc] initWithID:_nextChange++ type:NSPersistentHistoryChangeTypeUpdate objectID:oid updatedProperties:properties]];
  }
  for (NSManagedObjectID *oid in deleted) {
    [changes addObject:[[ODataHistoryChange alloc] initWithID:_nextChange++ type:NSPersistentHistoryChangeTypeDelete objectID:oid updatedProperties:nil]];
  }
  ODataHistoryToken *token = [[ODataHistoryToken alloc] initWithStoreID:self.storeID logID:_logID number:number];
  ODataHistoryTransaction *transaction = [[ODataHistoryTransaction alloc] initWithNumber:number changes:changes storeID:self.storeID
                                                                                 author:author contextName:contextName token:token];
  [_transactions addObject:transaction];
  [_lock unlock];
  return transaction;
}

// What a value of one of the request's private anchors is, read the way
// each platform lets it be read.
static id OISRequestValue(NSPersistentHistoryChangeRequest *request, NSString *appleKey, SEL freeCoreDataSelector)
{
  if ([request respondsToSelector:freeCoreDataSelector]) {
    NSMethodSignature *signature = [request methodSignatureForSelector:freeCoreDataSelector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = request;
    invocation.selector = freeCoreDataSelector;
    [invocation invoke];
    const char *type = signature.methodReturnType;
    if (type[0] == '@') {
      __unsafe_unretained id value = nil;
      [invocation getReturnValue:&value];
      return value;
    }
    if (type[0] == 'c' || type[0] == 'B') {
      BOOL value = NO;
      [invocation getReturnValue:&value];
      return @(value);
    }
    long long value = 0;
    [invocation getReturnValue:&value];
    return @(value);
  }
  @try {
    return [request valueForKey:appleKey];
  } @catch (NSException *e) {
    return nil;
  }
}

// The transaction number a request's anchor stands at: transactions after
// it are fetched, those before it deleted.
- (BOOL)anchorOf:(NSPersistentHistoryChangeRequest *)request number:(int64_t *)number date:(NSDate **)date
{
  *number = -1;
  *date = nil;
  NSPersistentHistoryToken *token = request.token;
  if ([token isKindOfClass:[ODataHistoryToken class]]) {
    ODataHistoryToken *ours = (ODataHistoryToken *)token;
    *number = [ours.logID isEqualToString:_logID] ? ours.transactionNumber : 0;
    return YES;
  }
  if (token && [token respondsToSelector:@selector(_transactionNumberForStoreIdentifier:)]) {
    // FreeCoreData's own token, from -currentPersistentHistoryTokenFromStores:.
    NSMethodSignature *signature = [token methodSignatureForSelector:@selector(_transactionNumberForStoreIdentifier:)];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = token;
    invocation.selector = @selector(_transactionNumberForStoreIdentifier:);
    NSString *storeID = self.storeID;
    [invocation setArgument:&storeID atIndex:2];
    [invocation invoke];
    long long n = 0;
    [invocation getReturnValue:&n];
    *number = n;
    return YES;
  }
  id when = OISRequestValue(request, @"date", NSSelectorFromString(@"_anchorDate"));
  if ([when isKindOfClass:[NSDate class]]) {
    *date = when;
    return YES;
  }
  id transaction = OISRequestValue(request, @"transactionNumber", NSSelectorFromString(@"_anchorTransactionNumber"));
  if ([transaction isKindOfClass:[NSNumber class]] && [transaction longLongValue] >= 0) {
    *number = [transaction longLongValue];
    return YES;
  }
  *number = 0;  // no anchor: everything
  return YES;
}

- (NSPersistentStoreResult *)resultForRequest:(NSPersistentHistoryChangeRequest *)request error:(NSError **)error
{
  int64_t number;
  NSDate *date;
  [self anchorOf:request number:&number date:&date];
  BOOL purge = [OISRequestValue(request, @"isDelete", NSSelectorFromString(@"_isPurge")) boolValue];

  [_lock lock];
  NSMutableArray *selected = [NSMutableArray array];
  NSMutableArray *kept = [NSMutableArray array];
  for (ODataHistoryTransaction *t in _transactions) {
    BOOL after = date ? [t.timestamp compare:date] == NSOrderedDescending : t.transactionNumber > number;
    BOOL before = date ? [t.timestamp compare:date] == NSOrderedAscending : t.transactionNumber < number;
    if (purge) {
      if (before) [selected addObject:t];
      else [kept addObject:t];
    } else if (after) {
      [selected addObject:t];
    }
  }
  if (purge) [_transactions setArray:kept];
  [_lock unlock];

  NSPersistentHistoryResultType type = request.resultType;
  id result;
  switch (type) {
    case NSPersistentHistoryResultTypeStatusOnly:
      result = @YES;
      break;
    case NSPersistentHistoryResultTypeCount:
      result = @(selected.count);
      break;
    case NSPersistentHistoryResultTypeObjectIDs: {
      NSMutableArray *ids = [NSMutableArray array];
      for (ODataHistoryTransaction *t in selected) {
        for (NSPersistentHistoryChange *change in t.changes) [ids addObject:change.changedObjectID];
      }
      result = ids;
      break;
    }
    case NSPersistentHistoryResultTypeChangesOnly: {
      NSMutableArray *changes = [NSMutableArray array];
      for (ODataHistoryTransaction *t in selected) [changes addObjectsFromArray:t.changes];
      result = changes;
      break;
    }
    case NSPersistentHistoryResultTypeTransactionsOnly: {
      NSMutableArray *bare = [NSMutableArray array];
      for (ODataHistoryTransaction *t in selected) [bare addObject:[t withoutChanges]];
      result = bare;
      break;
    }
    case NSPersistentHistoryResultTypeTransactionsAndChanges:
    default:
      result = selected;
      break;
  }
  return [[ODataHistoryResult alloc] initWithResult:result type:type];
}

@end
