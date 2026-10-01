// ODataServerObservability — what a server says about itself: metrics,
// trace context, readiness.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Metrics in Prometheus's text format (ODataMetrics, ODataMetricsStage,
// ODataMetricsHandler), labelled by route pattern, never by path, so that
// their number stays bounded; W3C Trace Context (ODataTraceContextStage),
// so a request can be followed through the proxy, this server and what it
// calls; and readiness (ODataReadinessHandler), apart from liveness
// (ODataHealthHandler): whether to send it requests, not whether it runs.

#pragma once
#import <Foundation/Foundation.h>
#import "ODataServerPipeline.h"

@class ODataService;

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Metrics

// A registry of metrics, by name and labels: counters, gauges and
// histograms, thread-safe. The application's own go in the same one as the
// server's, and come out at the same /metrics.
//
//   [metrics incrementCounter:@"orders_placed_total" help:@"Orders placed." labels:@{ @"channel": @"web" } by:1];
//
// Names and label names as Prometheus has them ([a-zA-Z_:][a-zA-Z0-9_:]*);
// label values are escaped when written. A name is one kind, with one help
// text: the first use says which.
@interface ODataMetrics : NSObject
- (void)incrementCounter:(NSString *)name help:(NSString *)help labels:(nullable NSDictionary<NSString *, NSString *> *)labels by:(double)value;
- (void)setGauge:(NSString *)name help:(NSString *)help labels:(nullable NSDictionary<NSString *, NSString *> *)labels value:(double)value;
- (void)addToGauge:(NSString *)name help:(NSString *)help labels:(nullable NSDictionary<NSString *, NSString *> *)labels by:(double)value;
// buckets: upper bounds, ascending (+Inf is added); nil for the default,
// 5 ms to 10 s as Prometheus's clients have it.
- (void)observeHistogram:(NSString *)name help:(NSString *)help labels:(nullable NSDictionary<NSString *, NSString *> *)labels
                   value:(double)value buckets:(nullable NSArray<NSNumber *> *)buckets;
// The current value of a counter or gauge (0 for none): for tests and
// health checks.
- (double)valueOf:(NSString *)name labels:(nullable NSDictionary<NSString *, NSString *> *)labels;
// Everything, in the text exposition format (version 0.0.4), with the
// process's own: start time, resident memory, and the build.
- (NSString *)exposition;
@end

// Each request counted, timed and sized, by method, route pattern and
// status: http_requests_total, http_request_duration_seconds,
// http_response_size_bytes, http_requests_in_flight; and, for a request
// whose handler named its operation (an OpenAPI operationId, an OData
// entity set), http_operations_total by route and operation too. A request
// no route took is counted under route "(none)".
@interface ODataMetricsStage : ODataServerStage
- (instancetype)initWithMetrics:(ODataMetrics *)metrics NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) ODataMetrics *metrics;
@end

// GET: the metrics, as Prometheus scrapes them.
@interface ODataMetricsHandler : NSObject <ODataServerHandler>
- (instancetype)initWithMetrics:(ODataMetrics *)metrics NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

// The version the build says (ODATASERVER_VERSION when compiled), for
// odataserver_build_info and logs.
FOUNDATION_EXPORT NSString * const ODataServerVersion;

#pragma mark - Trace context

// W3C Trace Context: a request's traceparent (00-<trace id>-<parent id>-
// <flags>) is taken when it is well formed, and a new trace begun when it
// is not; either way this server's part of it is a new span. In userInfo:
// the trace id (ODataServerTraceIDKey), the span id (ODataServerSpanIDKey)
// and the traceparent to send on to what it calls (ODataServerTraceparentKey);
// a mounted service's handlers see it as the request's traceparent header.
// The access log writes the trace id.
FOUNDATION_EXPORT NSString * const ODataServerTraceIDKey;
FOUNDATION_EXPORT NSString * const ODataServerSpanIDKey;
FOUNDATION_EXPORT NSString * const ODataServerTraceparentKey;
@interface ODataTraceContextStage : ODataServerStage
@end

#pragma mark - Readiness

@class ODataServerCheck;

// One thing a server needs to answer requests: a store, a database, a
// service it calls. Asked each time readiness is: pass or fail the check,
// now or later, from any thread.
@protocol ODataServerReadinessCheck <NSObject>
@property (nonatomic, readonly, copy) NSString *name;  // as the answer names it: store, cache
- (void)checkReadiness:(ODataServerCheck *)check;
@end

// A check under way: passed, or failed with why; the first answer counts.
@interface ODataServerCheck : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (void)pass;
- (void)failWithReason:(NSString *)reason;
@end

// Whether the server should be sent requests: 200, or 503 while it is
// draining (shutting down) or when a check fails or does not answer within
// timeout, with each check's answer ({"status": "ready", "checks":
// {"store": "ok"}}). A load balancer or an orchestrator asks;
// ODataHealthHandler says only that the process runs.
@interface ODataReadinessHandler : NSObject <ODataServerHandler>
@property (copy) NSArray<id<ODataServerReadinessCheck>> *checks;
- (void)addCheck:(id<ODataServerReadinessCheck>)check;
@property (atomic, getter=isDraining) BOOL draining;
@property (nonatomic) NSTimeInterval timeout;  // default: 5 seconds
@end

// An ODataService's store answers a count of one of its entity sets.
@interface ODataServiceStoreCheck : NSObject <ODataServerReadinessCheck>
- (instancetype)initWithService:(ODataService *)service NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
