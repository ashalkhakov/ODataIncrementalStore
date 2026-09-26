// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const ODataIncrementalStoreErrorDomain;

typedef NS_ENUM(NSInteger, ODataIncrementalStoreErrorCode) {
  ODataIncrementalStoreErrorMissingServiceURL = 1,
  ODataIncrementalStoreErrorUnsupportedRequest = 2,
  ODataIncrementalStoreErrorUnsupportedPredicate = 3,
  ODataIncrementalStoreErrorUnsupportedExpression = 4,
  ODataIncrementalStoreErrorDecoding = 5,
  ODataIncrementalStoreErrorMissingEntitySet = 6,
  ODataIncrementalStoreErrorMissingKey = 7,
  ODataIncrementalStoreErrorTransport = 8,
  ODataIncrementalStoreErrorHTTP = 1000,
  ODataIncrementalStoreErrorOptimisticLocking = 1570
};

FOUNDATION_EXPORT NSError *OISError(ODataIncrementalStoreErrorCode code, NSString *message);

NS_ASSUME_NONNULL_END
