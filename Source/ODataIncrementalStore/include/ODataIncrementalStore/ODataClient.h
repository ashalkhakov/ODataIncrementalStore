// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "ODataConfiguration.h"
#import <ODataKit/ODataTransport.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataClient : NSObject
@property (nonatomic, readonly) ODataConfiguration *configuration;
// nil: ODataDefaultTransport().
@property (nonatomic, strong, nullable) id<ODataTransport> transport;

// Sends a request with the configuration's headers. When it is done, on
// whatever thread the transport finished on, the action goes to the
// target: the exchange's response is set, or its error (an HTTP error
// status is an error, as in -sendRequest:error:). The exchange is
// returned, too, for its context.
- (ODataExchange *)sendRequest:(NSURLRequest *)request target:(nullable id)target action:(nullable SEL)action;
// As -sendChangeSet:error:, reporting the same way, with responses set.
- (ODataExchange *)sendChangeSet:(NSArray<NSURLRequest *> *)requests target:(nullable id)target action:(nullable SEL)action;

// The same, waited for, for callers that are synchronous themselves, as
// the store's callbacks are. They wait on a condition, not a run loop.

- (instancetype)initWithConfiguration:(ODataConfiguration *)configuration NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (nullable ODataHTTPResponse *)sendRequest:(NSURLRequest *)request error:(NSError **)error;
- (nullable id)JSONAtURL:(NSURL *)url error:(NSError **)error;
- (nullable id)JSONAtURL:(NSURL *)url headers:(nullable NSDictionary<NSString *, NSString *> *)headers error:(NSError **)error;
- (nullable NSString *)textAtURL:(NSURL *)url error:(NSError **)error;
- (nullable ODataHTTPResponse *)sendJSONMethod:(NSString *)method
                                           URL:(NSURL *)url
                                          body:(nullable id)body
                                          etag:(nullable NSString *)etag
                                         error:(NSError **)error;
- (nullable NSData *)metadataWithError:(NSError **)error;

// The request -sendJSONMethod:... would send, not sent: JSON body, If-Match,
// Prefer, and the configuration's headers.
- (nullable NSMutableURLRequest *)requestWithMethod:(NSString *)method
                                               URL:(NSURL *)url
                                              body:(nullable id)body
                                              etag:(nullable NSString *)etag
                                             error:(NSError **)error;

// These requests as one change set of a $batch request (Part 1 section
// 11.7): all of them take effect or none does. The responses in order; or
// nil, with the error of the request that failed, or of the batch itself
// (its HTTP status in ODataErrorHTTPStatusKey).
- (nullable NSArray<ODataHTTPResponse *> *)sendChangeSet:(NSArray<NSURLRequest *> *)requests error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
