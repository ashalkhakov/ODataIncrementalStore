// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Version vectors (docs/offline-sync.md, 12): for each replica that
// changed an object, the number of that replica's latest change the
// version includes. As text: `Kq3x9Zp1.4f,svc.2a`, replicas sorted, counts
// in base 36.

#import "ODSInternal.h"
#import <objc/runtime.h>

NSString * const ODSServiceReplica = @"svc";
NSString * const ODataSyncVersionsHeader = @"ODataSync-Versions";
NSString * const ODSDeletedCode = @"ODataSync.deleted";
NSString * const ODSDeletionsKey = @"ODataSync.deletions";

// FreeCoreData's contexts have no userInfo: an associated dictionary.
static char ODSDeletionsAssociation;

NSDictionary<NSString *, NSString *> *ODSSentDeletions(NSManagedObjectContext *context)
{
  return objc_getAssociatedObject(context, &ODSDeletionsAssociation);
}

void ODSNoteSentDeletion(NSManagedObjectContext *context, NSString *name, NSString *versions)
{
  NSMutableDictionary *deletions = [ODSSentDeletions(context) mutableCopy] ?: [NSMutableDictionary dictionary];
  deletions[name] = versions;
  objc_setAssociatedObject(context, &ODSDeletionsAssociation, deletions, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *ODSBase36(int64_t value)
{
  static const char digits[] = "0123456789abcdefghijklmnopqrstuvwxyz";
  if (value <= 0) return @"0";
  char buffer[16];
  int at = 15;
  buffer[at] = 0;
  while (value > 0 && at > 0) {
    buffer[--at] = digits[value % 36];
    value /= 36;
  }
  return [NSString stringWithUTF8String:buffer + at];
}

static int64_t ODSFromBase36(NSString *text)
{
  int64_t value = 0;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    int digit = c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'z' ? c - 'a' + 10 : -1;
    if (digit < 0) return -1;
    value = value * 36 + digit;
  }
  return value;
}

NSDictionary<NSString *, NSNumber *> *ODSVersionsFromText(NSString *text)
{
  NSMutableDictionary *versions = [NSMutableDictionary dictionary];
  if (![text isKindOfClass:[NSString class]]) return versions;
  for (NSString *entry in [text componentsSeparatedByString:@","]) {
    NSRange dot = [entry rangeOfString:@"." options:NSBackwardsSearch];
    if (dot.location == NSNotFound || dot.location == 0) continue;
    int64_t count = ODSFromBase36([entry substringFromIndex:dot.location + 1]);
    if (count <= 0) continue;
    NSString *replica = [entry substringToIndex:dot.location];
    if (count > [versions[replica] longLongValue]) versions[replica] = @(count);
  }
  return versions;
}

NSString *ODSTextOfVersions(NSDictionary<NSString *, NSNumber *> *versions)
{
  NSMutableArray *entries = [NSMutableArray array];
  for (NSString *replica in [versions.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    int64_t count = [versions[replica] longLongValue];
    if (count > 0) [entries addObject:[NSString stringWithFormat:@"%@.%@", replica, ODSBase36(count)]];
  }
  return [entries componentsJoinedByString:@","];
}

ODSOrder ODSCompareVersions(NSDictionary<NSString *, NSNumber *> *a, NSDictionary<NSString *, NSNumber *> *b)
{
  BOOL aHasMore = NO, bHasMore = NO;
  NSMutableSet *replicas = [NSMutableSet setWithArray:a.allKeys ?: @[]];
  [replicas addObjectsFromArray:b.allKeys ?: @[]];
  for (NSString *replica in replicas) {
    int64_t x = [a[replica] longLongValue], y = [b[replica] longLongValue];
    if (x > y) aHasMore = YES;
    if (y > x) bHasMore = YES;
  }
  if (aHasMore && bHasMore) return ODSOrderConcurrent;
  if (aHasMore) return ODSOrderAfter;
  if (bHasMore) return ODSOrderBefore;
  return ODSOrderSame;
}

NSDictionary<NSString *, NSNumber *> *ODSMergeVersions(NSDictionary<NSString *, NSNumber *> *a, NSDictionary<NSString *, NSNumber *> *b)
{
  NSMutableDictionary *merged = [NSMutableDictionary dictionaryWithDictionary:a ?: @{}];
  for (NSString *replica in b) {
    if ([b[replica] longLongValue] > [merged[replica] longLongValue]) merged[replica] = b[replica];
  }
  return merged;
}

NSString *ODSShortReplica(NSString *replicaID)
{
  // The first 48 bits of the UUID, base64url: 8 characters.
  NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:replicaID];
  uuid_t bytes;
  if (!uuid) return [replicaID substringToIndex:MIN(8u, replicaID.length)];
  [uuid getUUIDBytes:bytes];
  static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  uint64_t bits = 0;
  for (int i = 0; i < 6; i++) bits = (bits << 8) | bytes[i];
  char text[9];
  for (int i = 7; i >= 0; i--) {
    text[i] = alphabet[bits & 63];
    bits >>= 6;
  }
  text[8] = 0;
  return [NSString stringWithUTF8String:text];
}
