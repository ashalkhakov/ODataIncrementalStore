// What every save of the store is followed by: the app's changes stamped
// (ODataSync.modified) and counted (ODataSync.versions), and deletions
// remembered (tombstones).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>

@class ODataSyncEngine;

NS_ASSUME_NONNULL_BEGIN

@interface ODSRecorder : NSObject
// Observes the saves of contexts on the engine's coordinator, for as long
// as it lives.
- (instancetype)initWithEngine:(ODataSyncEngine *)engine NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
