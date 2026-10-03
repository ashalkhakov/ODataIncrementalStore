// A replica's clocks: the hybrid logical clock that stamps a change for
// last writer wins, and the count of its changes its version vectors name.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>

@class ODSStore;

NS_ASSUME_NONNULL_BEGIN

@interface ODSClock : NSObject
// A device's replica (its store's replica ID), or the service's (svc).
- (instancetype)initWithStore:(ODSStore *)store service:(BOOL)service NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
// A stamp for a change made now (0001701234567890.0003.ab12cd34: ordered as
// text, as the clock orders); a stamp seen from elsewhere, so the next is
// after it.
- (NSString *)tick;
- (void)witness:(nullable NSString *)stamp;
// This replica as vectors name it (8 characters, or svc), and the count of
// a new change of its (kept in the store's metadata).
@property (nonatomic, readonly) NSString *shortReplica;
- (int64_t)nextCount;
@end

NS_ASSUME_NONNULL_END
