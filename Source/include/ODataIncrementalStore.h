// ODataIncrementalStore — NSIncrementalStore over OData v4.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Modern Objective-C (libobjc2 / ARC / blocks / properties / zeroing weak).
// Builds on GNUstep (clang + gnustep-base) and Apple Core Data.

#pragma once

#import "OISRuntime.h"
#import "OISCoreData.h"
#import "ODataError.h"
#import "ODataConfiguration.h"
#import "ODataClient.h"
#import "ODataPropertyMapper.h"
#import "ODataResourceIdentifier.h"
#import "ODataPredicateTranslator.h"
#import "ODataQueryBuilder.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataIncrementalStore : NSIncrementalStore

+ (NSString *)storeType;
+ (void)registerStore;

@end

NS_ASSUME_NONNULL_END
