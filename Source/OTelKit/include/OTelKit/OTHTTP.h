// OTHTTP — a request this process makes, as a client span, its trace
// passed on in the request's headers, so the service it calls puts its
// spans under it.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   NSMutableURLRequest *call = [NSMutableURLRequest requestWithURL:billing];
//   OTSpan *span = [tracer startClientSpanForRequest:call name:nil parent:request.span.context];
//   ... send call; then, on whatever thread it is done:
//   [span endWithResponse:response error:error];

#pragma once
#import <Foundation/Foundation.h>
#import "OTTrace.h"

NS_ASSUME_NONNULL_BEGIN

@interface NSMutableURLRequest (OTelKit)
// traceparent and tracestate, as context has them.
- (void)ot_setTraceContext:(OTSpanContext *)context;
@end

@interface OTTracer (OTHTTP)
// A client span for request: named name (default: the method), with
// OpenTelemetry's HTTP client attributes (http.request.method, url.full
// without credentials, server.address, server.port), under parent (nil:
// this thread's current span, or a new trace). Its context goes in the
// request's headers when the trace is recorded here or was by the caller
// (sampled), so a trace nobody records is not made up for the service.
// Not made current.
- (OTSpan *)startClientSpanForRequest:(NSMutableURLRequest *)request name:(nullable NSString *)name parent:(nullable OTSpanContext *)parent;
@end

@interface OTSpan (OTHTTP)
// http.response.status_code, and Error for a 4xx or 5xx or no response
// (error.type the status, or the error's domain); then ended.
- (void)endWithResponse:(nullable NSURLResponse *)response error:(nullable NSError *)error;
@end

NS_ASSUME_NONNULL_END
