// Spans, their context, sampling, batching and OTLP's JSON, without a
// network (Server/Tests/ois-serve-check.m sends to a collector).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <XCTest/XCTest.h>
#import <OTelKit/OTelKit.h>

// Takes nothing until let; counts what it was given.
@interface OTSlowExporter : NSObject <OTSpanExporter>
@property (atomic) NSUInteger exported;
@property (atomic) BOOL refuses;
@end

@implementation OTSlowExporter
- (BOOL)exportSpans:(NSArray<OTSpan *> *)spans error:(NSError **)error
{
  [NSThread sleepForTimeInterval:0.01];
  if (self.refuses) {
    if (error) *error = [NSError errorWithDomain:OTErrorDomain code:503 userInfo:@{ NSLocalizedDescriptionKey: @"away" }];
    return NO;
  }
  self.exported += spans.count;
  return YES;
}
@end

@interface OTCountingObserver : NSObject <OTExportObserver>
@property (atomic) NSUInteger exported, failed, dropped;
@end

@implementation OTCountingObserver
- (void)spanProcessor:(id<OTSpanProcessor>)processor didExportSpans:(NSUInteger)count
{
  self.exported += count;
}
- (void)spanProcessor:(id<OTSpanProcessor>)processor didFailToExportSpans:(NSUInteger)count error:(NSError *)error
{
  self.failed += count;
}
- (void)spanProcessor:(id<OTSpanProcessor>)processor didDropSpans:(NSUInteger)count
{
  self.dropped += count;
}
@end

@interface OTelKitTests : XCTestCase
@end

@implementation OTelKitTests {
  OTInMemoryExporter *_memory;
  OTTracer *_tracer;
}

- (void)setUp
{
  _memory = [[OTInMemoryExporter alloc] init];
  OTTracerProvider *provider = [[OTTracerProvider alloc] initWithResource:@{ @"service.name": @"tests" }
                                                                  sampler:[[OTRatioSampler alloc] initWithRatio:1]
                                                                processor:[[OTSimpleSpanProcessor alloc] initWithExporter:_memory]];
  _tracer = [[OTTracer alloc] initWithName:@"Tests" version:@"1.0" provider:provider];
}

- (void)testTraceparent
{
  OTSpanContext *context = [OTSpanContext contextWithTraceparent:@"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"];
  XCTAssertEqualObjects(context.traceID, @"4bf92f3577b34da6a3ce929d0e0e4736");
  XCTAssertEqualObjects(context.spanID, @"00f067aa0ba902b7");
  XCTAssertTrue(context.sampled);
  XCTAssertTrue(context.remote);
  XCTAssertEqualObjects(context.traceparent, @"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
  XCTAssertFalse([OTSpanContext contextWithTraceparent:@"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"].sampled);
  // A later version may add fields; version 00 may not.
  XCTAssertNotNil([OTSpanContext contextWithTraceparent:@"01-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-more"]);
  for (NSString *bad in @[ @"", @"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01-more",
                           @"00-00000000000000000000000000000000-00f067aa0ba902b7-01", @"00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01",
                           @"ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", @"00-4BF92F3577B34DA6A3CE929D0E0E4736-00f067aa0ba902b7-01",
                           @"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7" ]) {
    XCTAssertNil([OTSpanContext contextWithTraceparent:bad], @"%@", bad);
  }
}

- (void)testTraceState
{
  OTSpanContext *context = [OTSpanContext contextWithHeaders:@{ @"TraceParent": @"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
                                                                @"tracestate": @" congo=t61rcWkgMzE, rojo=00f067aa0ba902b7 " }];
  XCTAssertEqualObjects(context.traceState, @"congo=t61rcWkgMzE, rojo=00f067aa0ba902b7");
  OTSpan *child = [_tracer startSpanNamed:@"x" kind:OTSpanKindServer parent:context attributes:nil];
  XCTAssertEqualObjects(child.context.traceState, context.traceState, @"carried on, untouched");
  XCTAssertEqualObjects(child.context.propagationHeaders[@"tracestate"], context.traceState);
  XCTAssertEqualObjects(child.context.propagationHeaders[@"traceparent"], child.context.traceparent);
  [child end];
  // Not a list of key=value, or too long: dropped whole, the traceparent kept.
  NSString *parent = @"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01";
  for (NSString *bad in @[ @"no-equals", @"=value", @"key=", [@"" stringByPaddingToLength:513 withString:@"a=b," startingAtIndex:0] ]) {
    OTSpanContext *dropped = [OTSpanContext contextWithTraceparent:parent tracestate:bad];
    XCTAssertNotNil(dropped);
    XCTAssertNil(dropped.traceState, @"%@", bad);
    XCTAssertNil(dropped.propagationHeaders[@"tracestate"]);
  }
}

- (void)testClientSpans
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://ann:secret@billing.example.test/charges?x=1"]];
  request.HTTPMethod = @"POST";
  [request setValue:@"stale=1" forHTTPHeaderField:@"tracestate"];
  OTSpan *span = [_tracer startClientSpanForRequest:request name:@"POST charges" parent:nil];
  XCTAssertEqual(span.kind, OTSpanKindClient);
  XCTAssertEqualObjects(span.attributes[@"url.full"], @"https://billing.example.test/charges?x=1", @"no credentials");
  XCTAssertEqualObjects(span.attributes[@"server.port"], @443);
  XCTAssertEqualObjects([request valueForHTTPHeaderField:@"traceparent"], span.context.traceparent);
  XCTAssertNil([request valueForHTTPHeaderField:@"tracestate"], @"not an earlier trace's");
  NSHTTPURLResponse *refused = [[NSHTTPURLResponse alloc] initWithURL:request.URL statusCode:402 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
  [span endWithResponse:refused error:nil];
  XCTAssertEqual(span.status, OTStatusError);
  XCTAssertEqualObjects(span.attributes[@"error.type"], @"402");
  XCTAssertEqualObjects(span.attributes[@"http.response.status_code"], @402);

  // Under this thread's current span, when given none.
  OTSpan *outer = [_tracer startSpanNamed:@"outer" attributes:nil];
  NSMutableURLRequest *inner = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://localhost:8080/x"]];
  OTSpan *call = [_tracer startClientSpanForRequest:inner name:nil parent:nil];
  XCTAssertEqualObjects(call.parentSpanID, outer.context.spanID);
  XCTAssertEqualObjects(call.name, @"GET");
  [call endWithResponse:nil error:[NSError errorWithDomain:NSURLErrorDomain code:-1004 userInfo:nil]];
  XCTAssertEqualObjects(call.attributes[@"error.type"], NSURLErrorDomain);
  [outer end];
}

- (void)testSpansNestByParentAndByThread
{
  OTSpanContext *remote = [OTSpanContext contextWithTraceparent:@"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"];
  OTSpan *server = [_tracer startSpanNamed:@"GET /orders" kind:OTSpanKindServer parent:remote attributes:@{ @"http.request.method": @"GET" }];
  XCTAssertEqualObjects(server.context.traceID, remote.traceID);
  XCTAssertEqualObjects(server.parentSpanID, remote.spanID);
  XCTAssertNil([OTSpan currentSpan], @"an explicit span is not made current");

  [server becomeCurrent];
  OTSpan *inner = [_tracer startSpanNamed:@"fetch" attributes:nil];
  XCTAssertEqual([OTSpan currentSpan], inner);
  OTSpan *innermost = [_tracer startSpanNamed:@"SELECT" attributes:@{ @"db.system.name": @"sqlite" }];
  XCTAssertEqualObjects(innermost.parentSpanID, inner.context.spanID);
  [innermost end];
  XCTAssertEqual([OTSpan currentSpan], inner);
  [inner end];
  XCTAssertEqual([OTSpan currentSpan], server);
  [server end];
  XCTAssertNil([OTSpan currentSpan]);
  XCTAssertEqualObjects(inner.parentSpanID, server.context.spanID);

  NSArray *names = [_memory.spans valueForKey:@"name"];
  XCTAssertEqualObjects(names, (@[ @"SELECT", @"fetch", @"GET /orders" ]), @"each as it ends");
  [server end];
  XCTAssertEqual(_memory.spans.count, 3u, @"ended once");
  [server setAttribute:@"late" forKey:@"x"];
  XCTAssertNil(server.attributes[@"x"], @"nothing changes once it ends");
}

- (void)testStatusAndErrors
{
  OTSpan *span = [_tracer startSpanNamed:@"save" kind:OTSpanKindInternal parent:nil attributes:nil];
  [span recordError:[NSError errorWithDomain:@"Store" code:7 userInfo:@{ NSLocalizedDescriptionKey: @"disk full" }]];
  [span setStatus:OTStatusUnset message:nil];
  XCTAssertEqual(span.status, OTStatusError, @"Unset does not undo an error");
  XCTAssertEqualObjects(span.statusMessage, @"disk full");
  XCTAssertEqualObjects(span.events.firstObject[@"name"], @"exception");
  XCTAssertEqualObjects(span.events.firstObject[@"attributes"][@"exception.message"], @"disk full");
  [span setStatus:OTStatusOK message:nil];
  XCTAssertEqual(span.status, OTStatusOK);
  [span setStatus:OTStatusError message:@"later"];
  XCTAssertEqual(span.status, OTStatusOK, @"OK is final");
}

- (void)testSampling
{
  OTRatioSampler *half = [[OTRatioSampler alloc] initWithRatio:0.5];
  NSUInteger sampled = 0;
  for (int i = 0; i < 2000; i++) {
    NSString *trace = OTNewTraceID();
    BOOL first = [half shouldSampleTraceID:trace parent:nil name:@"x" kind:OTSpanKindServer];
    XCTAssertEqual(first, [half shouldSampleTraceID:trace parent:nil name:@"y" kind:OTSpanKindClient], @"by the trace, not the span");
    if (first) sampled++;
  }
  XCTAssertTrue(sampled > 850 && sampled < 1150, @"%lu of 2000", (unsigned long)sampled);

  OTParentBasedSampler *parentBased = [[OTParentBasedSampler alloc] initWithRootSampler:[[OTRatioSampler alloc] initWithRatio:0]];
  OTSpanContext *recorded = [OTSpanContext contextWithTraceparent:@"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"];
  XCTAssertTrue([parentBased shouldSampleTraceID:recorded.traceID parent:recorded name:@"x" kind:OTSpanKindServer]);
  XCTAssertFalse([parentBased shouldSampleTraceID:OTNewTraceID() parent:nil name:@"x" kind:OTSpanKindServer]);

  // Not sampled: nothing kept, but the context goes on, unsampled.
  OTTracerProvider *never = [[OTTracerProvider alloc] initWithResource:@{} sampler:[[OTRatioSampler alloc] initWithRatio:0]
                                                             processor:[[OTSimpleSpanProcessor alloc] initWithExporter:_memory]];
  OTSpan *span = [[[OTTracer alloc] initWithName:@"Tests" version:nil provider:never] startSpanNamed:@"x" kind:OTSpanKindServer parent:nil
                                                                                         attributes:@{ @"a": @1 }];
  [span end];
  XCTAssertFalse(span.recording);
  XCTAssertFalse(span.context.sampled);
  XCTAssertEqual(_memory.spans.count, 0u);
  XCTAssertEqualObjects(span.attributes, @{});
}

- (void)testNoProviderPassesTheTraceOn
{
  OTTracer *tracer = [[OTTracer alloc] initWithName:@"Tests" version:nil provider:[[OTTracerProvider alloc] init]];
  OTSpanContext *recorded = [OTSpanContext contextWithTraceparent:@"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"];
  OTSpan *span = [tracer startSpanNamed:@"x" kind:OTSpanKindServer parent:recorded attributes:nil];
  XCTAssertFalse(span.recording);
  XCTAssertEqualObjects(span.context.traceID, recorded.traceID);
  XCTAssertTrue(span.context.sampled, @"the caller's choice, carried on");
  XCTAssertNotEqualObjects(span.context.spanID, recorded.spanID);
}

- (void)testOTLPRequest
{
  OTSpan *span = [_tracer startSpanNamed:@"GET /orders/:id" kind:OTSpanKindServer parent:nil
                              attributes:@{ @"http.response.status_code": @200, @"http.route": @"/orders/:id", @"cached": @YES,
                                            @"ratio": @0.25, @"tags": @[ @"a", @"b" ] }];
  [span addEventNamed:@"retry" attributes:@{ @"attempt": @2 }];
  [span setStatus:OTStatusError message:@"broken"];
  [span end];
  NSDictionary *request = [OTLPExporter requestForSpans:@[ span ]];
  // As a collector reads it: through JSON.
  NSData *data = [NSJSONSerialization dataWithJSONObject:request options:0 error:NULL];
  NSDictionary *read = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  NSDictionary *resourceSpans = [read[@"resourceSpans"] firstObject];
  NSMutableDictionary *resource = [NSMutableDictionary dictionary];
  for (NSDictionary *attribute in resourceSpans[@"resource"][@"attributes"]) resource[attribute[@"key"]] = attribute[@"value"];
  XCTAssertEqualObjects(resource[@"service.name"], @{ @"stringValue": @"tests" });
  XCTAssertEqualObjects(resource[@"telemetry.sdk.name"], @{ @"stringValue": @"OTelKit" });
  NSDictionary *scopeSpans = [resourceSpans[@"scopeSpans"] firstObject];
  XCTAssertEqualObjects(scopeSpans[@"scope"], (@{ @"name": @"Tests", @"version": @"1.0" }));
  NSDictionary *sent = [scopeSpans[@"spans"] firstObject];
  XCTAssertEqualObjects(sent[@"traceId"], span.context.traceID);
  XCTAssertEqualObjects(sent[@"spanId"], span.context.spanID);
  XCTAssertNil(sent[@"parentSpanId"]);
  XCTAssertEqualObjects(sent[@"kind"], @2);
  XCTAssertEqualObjects(sent[@"startTimeUnixNano"], ([NSString stringWithFormat:@"%llu", (unsigned long long)span.startTime]), @"64 bits, as a string");
  XCTAssertEqualObjects(sent[@"status"], (@{ @"code": @2, @"message": @"broken" }));
  NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
  for (NSDictionary *attribute in sent[@"attributes"]) attributes[attribute[@"key"]] = attribute[@"value"];
  XCTAssertEqualObjects(attributes[@"http.response.status_code"], @{ @"intValue": @"200" });
  XCTAssertEqualObjects(attributes[@"http.route"], @{ @"stringValue": @"/orders/:id" });
  XCTAssertEqualObjects(attributes[@"cached"], @{ @"boolValue": @YES });
  XCTAssertEqualObjects(attributes[@"ratio"], @{ @"doubleValue": @0.25 });
  XCTAssertEqualObjects(attributes[@"tags"], (@{ @"arrayValue": @{ @"values": @[ @{ @"stringValue": @"a" }, @{ @"stringValue": @"b" } ] } }));
  NSDictionary *event = [sent[@"events"] firstObject];
  XCTAssertEqualObjects(event[@"name"], @"retry");
  XCTAssertEqualObjects(event[@"attributes"], (@[ @{ @"key": @"attempt", @"value": @{ @"intValue": @"2" } } ]));
}

- (void)testBatchesExportFlushAndDrop
{
  OTSlowExporter *exporter = [[OTSlowExporter alloc] init];
  OTCountingObserver *observer = [[OTCountingObserver alloc] init];
  OTBatchSpanProcessor *batch = [[OTBatchSpanProcessor alloc] initWithExporter:exporter];
  batch.maxQueueSize = 100;
  batch.maxBatchSize = 10;
  batch.scheduleDelay = 60;
  batch.observer = observer;
  OTTracerProvider *provider = [[OTTracerProvider alloc] initWithResource:@{} sampler:[[OTRatioSampler alloc] initWithRatio:1] processor:batch];
  OTTracer *tracer = [[OTTracer alloc] initWithName:@"Tests" version:nil provider:provider];
  for (int i = 0; i < 25; i++) [[tracer startSpanNamed:@"x" kind:OTSpanKindInternal parent:nil attributes:nil] end];
  XCTAssertTrue([provider forceFlushWithTimeout:5]);
  XCTAssertEqual(exporter.exported, 25u, @"full batches at once, the rest when flushed, not after a minute");
  XCTAssertEqual(observer.exported, 25u);

  // Faster than the exporter: what the queue cannot hold is dropped, and said.
  exporter.refuses = YES;
  for (int i = 0; i < 1000; i++) [[tracer startSpanNamed:@"x" kind:OTSpanKindInternal parent:nil attributes:nil] end];
  XCTAssertTrue([provider forceFlushWithTimeout:10]);
  [provider shutdownWithTimeout:5];
  XCTAssertEqual(observer.failed + observer.dropped, 1000u);
  XCTAssertTrue(observer.dropped > 0);
  [[tracer startSpanNamed:@"after" kind:OTSpanKindInternal parent:nil attributes:nil] end];
  XCTAssertEqual(observer.failed + observer.dropped, 1000u, @"nothing after shutdown");
}

- (void)testEnvironment
{
  NSError *error = nil;
  XCTAssertNil([OTTracerProvider providerWithEnvironment:@{} defaults:nil error:&error], @"no endpoint: off");
  XCTAssertNil(error);
  XCTAssertNil(([OTTracerProvider providerWithEnvironment:@{ @"OTEL_EXPORTER_OTLP_ENDPOINT": @"http://c:4318", @"OTEL_SDK_DISABLED": @"true" }
                                                defaults:nil error:&error]));
  XCTAssertNil(([OTTracerProvider providerWithEnvironment:@{ @"OTEL_EXPORTER_OTLP_ENDPOINT": @"http://c:4318", @"OTEL_TRACES_EXPORTER": @"none" }
                                                defaults:nil error:&error]));
  XCTAssertNil(([OTTracerProvider providerWithEnvironment:@{ @"OTEL_EXPORTER_OTLP_ENDPOINT": @"http://c:4317", @"OTEL_EXPORTER_OTLP_PROTOCOL": @"grpc" }
                                                defaults:nil error:&error]));
  XCTAssertNotNil(error, @"a protocol it cannot speak is said, not ignored");

  error = nil;
  OTTracerProvider *provider = [OTTracerProvider providerWithEnvironment:@{
    @"OTEL_EXPORTER_OTLP_ENDPOINT": @"http://collector:4318/",
    @"OTEL_EXPORTER_OTLP_HEADERS": @"api-key=s%20cret,tenant=a",
    @"OTEL_TRACES_SAMPLER": @"parentbased_traceidratio", @"OTEL_TRACES_SAMPLER_ARG": @"0.1",
    @"OTEL_RESOURCE_ATTRIBUTES": @"deployment.environment=prod,service.name=ignored",
    @"OTEL_SERVICE_NAME": @"orders",
  } defaults:@{ @"service.version": @"2.0" } error:&error];
  XCTAssertNotNil(provider, @"%@", error);
  XCTAssertEqualObjects(provider.resource[@"service.name"], @"orders", @"OTEL_SERVICE_NAME wins");
  XCTAssertEqualObjects(provider.resource[@"service.version"], @"2.0");
  XCTAssertEqualObjects(provider.resource[@"deployment.environment"], @"prod");
  XCTAssertTrue([provider.sampler isKindOfClass:[OTParentBasedSampler class]]);
  XCTAssertEqualWithAccuracy([(OTRatioSampler *)[(OTParentBasedSampler *)provider.sampler root] ratio], 0.1, 1e-9);
  OTLPExporter *exporter = (OTLPExporter *)[(OTBatchSpanProcessor *)provider.processor exporter];
  XCTAssertEqualObjects(exporter.endpoint.absoluteString, @"http://collector:4318/v1/traces");
  XCTAssertEqualObjects(exporter.headers, (@{ @"api-key": @"s cret", @"tenant": @"a" }));
  [provider shutdownWithTimeout:1];
}

@end
