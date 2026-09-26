// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

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
// Header names are case-insensitive (RFC 9110), whatever case the
// transport kept them in.
- (nullable NSString *)valueForHeader:(NSString *)name;
// The JSON body, with control information spelled one way whatever the
// payload's OData-Version: a 4.01 payload may leave out the odata. prefix
// (JSON Format 4.01 section 4.5), so @etag, @nextLink and Orders@count
// become @odata.etag, @odata.nextLink and Orders@odata.count. A payload
// that says it is 4.0 is taken as it is; one that says nothing, as 4.01.
- (nullable id)JSONWithError:(NSError **)error;
@end

// The same, for JSON already parsed, from a payload of this OData-Version.
FOUNDATION_EXPORT id ODataNormalizedControlInformation(id json, NSString * _Nullable version);

// One request on its way, and once it is done, how it went. Whoever
// starts an exchange gives it a target and an action; -finish sends the
// action to the target, with the exchange as its argument, once:
//
//   - (void)exchangeDidFinish:(ODataExchange *)exchange;
//
// That is how both layers report: a transport fills in the HTTP response
// and data, or an error, and finishes; the client fills in the OData
// response (or change-set responses), or an OData error, and finishes.
@interface ODataExchange : NSObject
- (instancetype)initWithRequest:(NSURLRequest *)request target:(nullable id)target action:(nullable SEL)action NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSURLRequest *request;
@property (nonatomic, strong, nullable) id context;             // the starter's own, untouched
// Set by the transport.
@property (nonatomic, strong, nullable) NSURLResponse *URLResponse;
@property (nonatomic, copy, nullable) NSData *data;
// Set by the transport (a request that never got an answer) or the client.
@property (nonatomic, strong, nullable) NSError *error;
// Set by the client.
@property (nonatomic, strong, nullable) ODataHTTPResponse *response;
@property (nonatomic, copy, nullable) NSArray<ODataHTTPResponse *> *responses;  // a change set's, in order
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
// Sends the action to the target, from the calling thread, the first time
// it is called; later calls do nothing. The target is released after.
- (void)finish;
@end

// How requests reach a service. Send the exchange's request; when it is
// done - before returning, or later on any thread - set URLResponse and
// data, or error, and call -finish.
//
// The one rule: do not finish on the thread that started the exchange by
// waiting for that thread to come back. The store's callbacks are
// synchronous, so that thread is waiting for -finish, not running its run
// loop. NSURLSession finishes on its own queue, and a transport that
// answers from memory finishes before returning; both are fine.
@protocol ODataTransport <NSObject>
- (void)startExchange:(ODataExchange *)exchange;
@end

// The transport a client uses when it is given none: NSURLSession, where
// Foundation has it (Apple, and gnustep-base built with libcurl), else
// NSURLConnection on a thread of its own. For a transport that wraps the
// network (one that logs, say) to hand exchanges on to.
FOUNDATION_EXPORT id<ODataTransport> ODataDefaultTransport(void);

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
