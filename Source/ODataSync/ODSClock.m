// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"

@implementation ODSClock {
  ODSStore *_store;
  BOOL _service;
  // The latest wall time (ms) and its counter.
  int64_t _time;
  int32_t _counter;
}

- (instancetype)initWithStore:(ODSStore *)store service:(BOOL)service
{
  self = [super init];
  if (!self) return nil;
  _store = store;
  _service = service;
  return self;
}

- (NSString *)tick
{
  NSString *replica = [[_store replicaID] substringToIndex:8];
  @synchronized (self) {
    int64_t now = (int64_t)([[NSDate date] timeIntervalSince1970] * 1000);
    if (now > _time) {
      _time = now;
      _counter = 0;
    } else {
      _counter++;
    }
    return [NSString stringWithFormat:@"%016lld.%04d.%@", (long long)_time, _counter, replica];
  }
}

- (void)witness:(NSString *)stamp
{
  if (![stamp isKindOfClass:[NSString class]]) return;
  NSArray *parts = [stamp componentsSeparatedByString:@"."];
  if (parts.count < 2) return;
  int64_t time = [parts[0] longLongValue];
  int32_t counter = [parts[1] intValue];
  @synchronized (self) {
    if (time > _time || (time == _time && counter > _counter)) {
      _time = time;
      _counter = counter;
    }
  }
}

- (NSString *)shortReplica
{
  return _service ? ODSServiceReplica : ODSShortReplica([_store replicaID]);
}

- (int64_t)nextCount
{
  return [_store nextCount];
}

@end
