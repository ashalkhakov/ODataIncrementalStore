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
// NSNumber BOOL, default YES: send a save of two or more requests as one
// $batch change set, so it takes effect whole or not at all. A service
// that refuses $batch gets the requests one at a time regardless.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreBatchSavesOption;
// NSNumber BOOL, default NO: fail to open when the model does not match
// the service's $metadata, rather than report it in metadataProblems.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreRequireMatchingModelOption;
// NSString, default @"4.01": the OData-MaxVersion requests carry, the
// newest protocol version the store will speak. The store speaks the
// newer of 4.0 and 4.01 that both this and the service's $metadata
// allow, and writes its requests in that version: see `version`.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreMaxVersionOption;
// NSNumber BOOL: address entities as Products/1 rather than Products(1)
// (Part 2 section 4.3.6). Unset, the store does so when $metadata says
// the service supports it (Capabilities.KeyAsSegmentSupported).
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreKeyAsSegmentOption;
// NSArray of entity names: the entities -fetchRemoteChanges: tracks.
// Unset, every entity with an entity set of its own.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreTrackedEntitiesOption;
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
@property (nonatomic) BOOL batchSaves;
@property (nonatomic, copy) NSString *maxVersion;
// The OData-Version requests carry, and the one their URLs and bodies are
// written in: 4.0 until the store has read $metadata.
@property (nonatomic, copy) NSString *version;
// The version to speak with a service that speaks `serviceVersion`.
- (NSString *)versionForService:(nullable NSString *)serviceVersion;
@property (nonatomic, copy) NSString *userAgent;

- (instancetype)initWithURL:(NSURL *)url options:(nullable NSDictionary *)options NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)applyToRequest:(NSMutableURLRequest *)request;
@end

NS_ASSUME_NONNULL_END
