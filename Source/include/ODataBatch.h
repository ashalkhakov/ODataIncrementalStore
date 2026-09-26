// ODataIncrementalStore — multipart $batch (Part 1 section 11.7).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// OData 4.0's batch format: a multipart/mixed body whose parts are HTTP
// messages, with a nested multipart/mixed change set for requests that
// succeed or fail together. The JSON batch format is 4.01 only.

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

// One HTTP message out of a batch: a request (method, URL) or a response
// (status), its headers, its body, and its Content-ID if it had one.
@interface ODataBatchPart : NSObject
@property (nonatomic, copy, nullable) NSString *method;
@property (nonatomic, copy, nullable) NSString *URLString;
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
@property (nonatomic, copy) NSData *body;
@property (nonatomic, copy, nullable) NSString *contentID;
// Case-insensitive, as header names are.
- (nullable NSString *)valueForHeader:(NSString *)name;
@end

// A batch holding one change set of these requests, each with an absolute
// URL (services such as TripPin reject relative ones in a batch). The
// Content-IDs are 1, 2, ... in order.
FOUNDATION_EXPORT NSData *ODataChangeSetBody(NSArray<NSURLRequest *> *requests, NSString *batchBoundary);

// The boundary parameter of a multipart Content-Type, or nil.
FOUNDATION_EXPORT NSString * _Nullable ODataMultipartBoundary(NSString *contentType);

// The HTTP messages in a multipart/mixed body, in order, with any nested
// change set flattened into its members. Requests and responses both.
FOUNDATION_EXPORT NSArray<ODataBatchPart *> * _Nullable ODataBatchParts(NSData *body, NSString *boundary);

NS_ASSUME_NONNULL_END
