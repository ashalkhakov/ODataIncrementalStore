// OTLPExporter — spans to an OpenTelemetry collector (or anything that
// takes OTLP: Jaeger, Tempo, Honeycomb, Datadog's agent), over HTTP, as
// JSON.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import "OTTrace.h"

NS_ASSUME_NONNULL_BEGIN

// OTLP/HTTP with JSON bodies (application/json), each batch one
// ExportTraceServiceRequest, POSTed to the traces URL. A collector that is
// busy or away (429, 502, 503, 504, or no connection) is asked again,
// after Retry-After when it says, within timeout; anything else fails the
// batch, which the processor reports.
@interface OTLPExporter : NSObject <OTSpanExporter>
// The traces URL: http://collector:4318/v1/traces.
- (instancetype)initWithEndpoint:(NSURL *)endpoint NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, copy) NSURL *endpoint;
// Sent with each batch: an API key, a tenant.
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *headers;
// For one batch, retries included. Default: 10 seconds.
@property (nonatomic) NSTimeInterval timeout;
// The request body for these spans: for tests, and for an exporter of
// another transport.
+ (NSDictionary *)requestForSpans:(NSArray<OTSpan *> *)spans;
@end

NS_ASSUME_NONNULL_END
