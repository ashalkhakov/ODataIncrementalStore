// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ODataIncrementalStoreAccessTokenOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreUsernameOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStorePasswordOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreTimeoutOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStorePostOnObtainPermanentIDsOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreTransportOption;
// NSNumber BOOL, default YES: ask for IEEE754Compatible=true, so Int64 and
// Decimal values travel as strings and keep every digit. Turn it off only
// for a service that rejects the parameter.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreIEEE754CompatibleOption;
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreType;

typedef NS_ENUM(NSInteger, ODataPropertyNaming) {
  ODataPropertyNamingAsIs = 0,
  ODataPropertyNamingPascalCase = 1
};

@interface ODataConfiguration : NSObject
@property (nonatomic, copy) NSURL *serviceRoot;
@property (nonatomic, copy, nullable) NSString *accessToken;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic) NSTimeInterval timeout;
@property (nonatomic) ODataPropertyNaming naming;
@property (nonatomic) BOOL postOnObtainPermanentIDs;
@property (nonatomic) BOOL IEEE754Compatible;
@property (nonatomic, copy) NSString *userAgent;

- (instancetype)initWithURL:(NSURL *)url options:(nullable NSDictionary *)options NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)applyToRequest:(NSMutableURLRequest *)request;
@end

NS_ASSUME_NONNULL_END
