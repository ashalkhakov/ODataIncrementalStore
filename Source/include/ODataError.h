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
  ODataIncrementalStoreErrorModelMismatch = 9,
  ODataIncrementalStoreErrorHTTP = 1000,
  ODataIncrementalStoreErrorOptimisticLocking = 1570
};

FOUNDATION_EXPORT NSError *OISError(ODataIncrementalStoreErrorCode code, NSString *message);

// What a service said about a failed request (JSON Format section 21,
// Part 1 section 9.4), in the userInfo of an ODataIncrementalStoreErrorHTTP
// + status error. Its message is the error's localizedDescription.
FOUNDATION_EXPORT NSString * const ODataErrorHTTPStatusKey;    // NSNumber
FOUNDATION_EXPORT NSString * const ODataErrorCodeKey;          // the service's error code
FOUNDATION_EXPORT NSString * const ODataErrorTargetKey;        // the property or entity it concerns
FOUNDATION_EXPORT NSString * const ODataErrorDetailsKey;       // NSArray of { code, message, target }
FOUNDATION_EXPORT NSString * const ODataErrorResponseBodyKey;  // the body, as text

FOUNDATION_EXPORT NSError *OISHTTPError(ODataIncrementalStoreErrorCode code, NSInteger status, NSURL * _Nullable url, NSData * _Nullable body);

NS_ASSUME_NONNULL_END
