// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataResourceIdentifier : NSObject
@property (nonatomic, copy) NSString *entitySet;
@property (nonatomic, copy) NSDictionary<NSString *, id> *keys;

- (instancetype)initWithEntitySet:(NSString *)entitySet keys:(NSDictionary<NSString *, id> *)keys NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (NSString *)path;
- (NSDictionary *)dictionary;
/* Opaque reference stored inside NSManagedObjectID. FreeCoreData uniques
   on this value and types it NSData; Apple accepts any NSCopying id. */
- (NSData *)data;
+ (nullable instancetype)identifierFromReference:(id)ref;
@end

FOUNDATION_EXPORT NSString *OISKeyLiteral(id value);

NS_ASSUME_NONNULL_END
