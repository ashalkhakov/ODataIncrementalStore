// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "ODataConfiguration.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataHTTPResponse : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSData *data;
@property (nonatomic, copy) NSDictionary *headers;
@property (nonatomic, copy, nullable) NSURL *URL;
@property (nonatomic, readonly, nullable) NSString *etag;
@end

@interface ODataClient : NSObject
@property (nonatomic, readonly) ODataConfiguration *configuration;

- (instancetype)initWithConfiguration:(ODataConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable ODataHTTPResponse *)sendRequest:(NSURLRequest *)request error:(NSError **)error;
- (nullable id)JSONAtURL:(NSURL *)url error:(NSError **)error;
- (nullable NSString *)textAtURL:(NSURL *)url error:(NSError **)error;
- (nullable ODataHTTPResponse *)sendJSONMethod:(NSString *)method
                                           URL:(NSURL *)url
                                          body:(nullable id)body
                                          etag:(nullable NSString *)etag
                                         error:(NSError **)error;
- (nullable NSData *)metadataWithError:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
