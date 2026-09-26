// ODataIncrementalStore — values between Core Data and OData.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// One place decides how an attribute's value is written in a JSON payload,
// read back from one, and written as a URL literal (JSON Format section
// 7.1, Part 2 section 5.1.1.14). The Edm type comes from the attribute's
// Core Data type, or from userInfo[@"OData.type"] where one Core Data type
// stands for several Edm types: a Date attribute holding an Edm.Date, a
// Double holding an Edm.Duration in seconds, a String holding an
// Edm.TimeOfDay or an Edm.Guid.

#pragma once
#import "OISCoreData.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ODataUserInfoType;  // @"OData.type", e.g. @"Edm.Date"

typedef NS_ENUM(NSInteger, ODataEdmType) {
  ODataEdmUnknown = 0,
  ODataEdmBoolean,
  ODataEdmInteger,         // Byte, SByte, Int16, Int32
  ODataEdmInt64,
  ODataEdmDecimal,
  ODataEdmDouble,          // Single, Double
  ODataEdmString,
  ODataEdmDateTimeOffset,
  ODataEdmDate,
  ODataEdmTimeOfDay,       // on a String attribute: "13:20:00"
  ODataEdmDuration,        // on a Double attribute: seconds
  ODataEdmGuid,
  ODataEdmBinary
};

@interface ODataValueCoder : NSObject

// Int64 and Decimal as JSON strings, both ways, so neither goes through a
// double (JSON Format section 3.2). The store asks for this format with
// IEEE754Compatible=true; reading accepts numbers and strings either way.
@property (nonatomic) BOOL IEEE754Compatible;

+ (ODataEdmType)edmTypeForAttribute:(nullable NSAttributeDescription *)attribute;

// The Core Data value for a JSON value, NSNull for null, or nil when the
// JSON cannot be one (a date that does not parse, say).
- (nullable id)coreDataValueForJSON:(id)json attribute:(NSAttributeDescription *)attribute;

// The JSON value for a Core Data value; NSNull for nil.
- (id)JSONForCoreDataValue:(nullable id)value attribute:(NSAttributeDescription *)attribute;

// A URL literal: typed by the attribute where there is one, else by the
// value's class.
- (NSString *)literalForValue:(nullable id)value attribute:(nullable NSAttributeDescription *)attribute;

@end

// The textual forms, for anyone who needs them without an attribute.
FOUNDATION_EXPORT NSDate * _Nullable ODataDateFromString(NSString *string);  // DateTimeOffset or Date
FOUNDATION_EXPORT NSString *ODataDateTimeOffsetString(NSDate *date);         // UTC, fraction only when there is one
FOUNDATION_EXPORT NSString *ODataDateString(NSDate *date);                   // the UTC calendar day
FOUNDATION_EXPORT NSNumber * _Nullable ODataDurationFromString(NSString *string);  // seconds
FOUNDATION_EXPORT NSString *ODataDurationString(double seconds);
FOUNDATION_EXPORT NSData * _Nullable ODataDataFromBase64(NSString *string);  // base64url or base64
FOUNDATION_EXPORT NSString *ODataBase64URLString(NSData *data);

NS_ASSUME_NONNULL_END
