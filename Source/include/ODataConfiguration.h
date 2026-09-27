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
// Posted by the store, on the thread of the fetch or save, when a response
// carries Core.Messages: ODataMessagesKey holds the ODataMessages,
// ODataMessagesURLKey the request's URL, and ODataMessagesObjectIDKey the
// object they are about, when they are about one (a POST's, a PATCH's, a
// fetched row's own).
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreDidReceiveMessagesNotification;
FOUNDATION_EXPORT NSString * const ODataMessagesKey;
FOUNDATION_EXPORT NSString * const ODataMessagesURLKey;
FOUNDATION_EXPORT NSString * const ODataMessagesObjectIDKey;
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
// NSString: an API key, sent as the service's Authorization.ApiKey says
// (its KeyName, in a header, the query or a cookie).
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreAPIKeyOption;
// An object conforming to ODataCredentialProviding.
FOUNDATION_EXPORT NSString * const ODataIncrementalStoreCredentialProviderOption;

@class ODataSchemaAuthorization;

// Credentials for the way to sign in a service declares, when the
// configuration has none of its own, or the ones it had are refused. Asked
// on the thread of the request, which waits: a provider that refreshes a
// token over the network does so there.
@protocol ODataCredentialProviding <NSObject>
@optional
// A bearer token: for OpenIDConnect, the OAuth2 flows, Http bearer (its
// issuer and the scopes the service needs are in the authorization; nil
// before $metadata is read). refresh: the last one was answered 401.
- (nullable NSString *)accessTokenForAuthorization:(nullable ODataSchemaAuthorization *)authorization refresh:(BOOL)refresh;
// A user and password, for Http basic.
- (nullable NSURLCredential *)credentialForAuthorization:(nullable ODataSchemaAuthorization *)authorization;
// A key, for ApiKey.
- (nullable NSString *)APIKeyForAuthorization:(nullable ODataSchemaAuthorization *)authorization;
@end

typedef NS_ENUM(NSInteger, ODataPropertyNaming) {
  ODataPropertyNamingAsIs = 0,
  ODataPropertyNamingPascalCase = 1
};

@interface ODataConfiguration : NSObject
@property (nonatomic, copy) NSURL *serviceRoot;
@property (nonatomic, copy, nullable) NSString *accessToken;
@property (nonatomic, copy, nullable) NSString *username;
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic, copy, nullable) NSString *apiKey;
@property (nonatomic, strong, nullable) id<ODataCredentialProviding> credentialProvider;
// The ways to sign in the service declares ($metadata's Authorization
// vocabulary); the store sets them once it has read it. Requests are
// signed the first way the credentials here, or the provider's, can: a
// bearer token, a user and password, or an API key where the service
// wants it. None declared: a bearer token if there is one, else basic.
@property (nonatomic, copy, nullable) NSArray<ODataSchemaAuthorization *> *authorizations;
@property (nonatomic, readonly, nullable) ODataSchemaAuthorization *authorization;
// After a 401: asks the provider for a fresh token; YES if it gave one.
- (BOOL)refreshCredentials;
// What the service expects, for an error that says why it was refused.
@property (nonatomic, readonly, nullable) NSString *expectedCredentials;
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
