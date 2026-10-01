// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OTTrace.h"
#import "OTLPExporter.h"
#include <stdlib.h>
#include <time.h>

#ifndef OTELKIT_VERSION
#define OTELKIT_VERSION "dev"
#endif

NSString * const OTErrorDomain = @"org.gnu.ois.OTelKit";

static NSError *OTError(NSString *message)
{
  return [NSError errorWithDomain:OTErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

#pragma mark - IDs and time

// Lower-case hex of count random bytes, never all zero (which W3C reserves).
static NSString *OTRandomHex(NSUInteger count)
{
  NSMutableString *hex = [NSMutableString stringWithCapacity:count * 2];
  BOOL zero = YES;
  while (hex.length < count * 2) {
    unsigned char bytes[16];
    [[NSUUID UUID] getUUIDBytes:bytes];
    // Bytes 6 and 8 carry the UUID's version and variant: the others are random.
    for (int i = 0; i < 16 && hex.length < count * 2; i++) {
      if (i == 6 || i == 8) continue;
      if (bytes[i]) zero = NO;
      [hex appendFormat:@"%02x", bytes[i]];
    }
  }
  return zero ? OTRandomHex(count) : hex;
}

NSString *OTNewTraceID(void)
{
  return OTRandomHex(16);
}

NSString *OTNewSpanID(void)
{
  return OTRandomHex(8);
}

uint64_t OTNow(void)
{
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  return (uint64_t)now.tv_sec * 1000000000ull + (uint64_t)now.tv_nsec;
}

static BOOL OTHexDigits(NSString *text, NSUInteger length)
{
  if (text.length != length) return NO;
  for (NSUInteger i = 0; i < length; i++) {
    unichar c = [text characterAtIndex:i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return NO;
  }
  return YES;
}

// An ID: lower-case hex, not all zero.
static BOOL OTIsHex(NSString *text, NSUInteger length)
{
  return OTHexDigits(text, length) && [text stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"0"]].length;
}

#pragma mark - Span context

@implementation OTSpanContext

- (instancetype)initWithTraceID:(NSString *)traceID spanID:(NSString *)spanID sampled:(BOOL)sampled remote:(BOOL)remote
                     traceState:(NSString *)traceState
{
  self = [super init];
  if (!self) return nil;
  _traceID = [traceID copy];
  _spanID = [spanID copy];
  _sampled = sampled;
  _remote = remote;
  _traceState = traceState.length ? [traceState copy] : nil;
  return self;
}

- (instancetype)initWithTraceID:(NSString *)traceID spanID:(NSString *)spanID sampled:(BOOL)sampled remote:(BOOL)remote
{
  return [self initWithTraceID:traceID spanID:spanID sampled:sampled remote:remote traceState:nil];
}

// A tracestate worth passing on: list-members (key=value) with commas
// between, at most 32 and 512 characters (W3C Trace Context, 3.3); nil
// when not, as the specification says to drop it whole.
static NSString *OTUsableTraceState(NSString *header)
{
  NSString *trimmed = [header stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!trimmed.length || trimmed.length > 512) return nil;
  NSUInteger members = 0;
  for (NSString *member in [trimmed componentsSeparatedByString:@","]) {
    NSString *item = [member stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!item.length) continue;
    NSRange equals = [item rangeOfString:@"="];
    if (equals.location == NSNotFound || equals.location == 0 || equals.location + 1 == item.length) return nil;
    members++;
  }
  return members && members <= 32 ? trimmed : nil;
}

+ (instancetype)contextWithTraceparent:(NSString *)traceparent
{
  return [self contextWithTraceparent:traceparent tracestate:nil];
}

+ (instancetype)contextWithHeaders:(NSDictionary<NSString *, NSString *> *)headers
{
  NSString *traceparent = nil, *tracestate = nil;
  for (NSString *name in headers) {
    if ([name caseInsensitiveCompare:@"traceparent"] == NSOrderedSame) traceparent = headers[name];
    if ([name caseInsensitiveCompare:@"tracestate"] == NSOrderedSame) tracestate = headers[name];
  }
  return [self contextWithTraceparent:traceparent tracestate:tracestate];
}

+ (instancetype)contextWithTraceparent:(NSString *)traceparent tracestate:(NSString *)tracestate
{
  // version-traceid-parentid-flags; a later version may add fields after these.
  NSArray<NSString *> *parts = [traceparent ?: @"" componentsSeparatedByString:@"-"];
  BOOL valid = parts.count >= 4 && OTHexDigits(parts[0], 2) &&
               ![parts[0] isEqualToString:@"ff"] && (![parts[0] isEqualToString:@"00"] || parts.count == 4) &&
               OTIsHex(parts[1], 32) && OTIsHex(parts[2], 16) && OTHexDigits(parts[3], 2);
  if (!valid) return nil;
  unsigned flags = 0;
  [[NSScanner scannerWithString:parts[3]] scanHexInt:&flags];
  return [[self alloc] initWithTraceID:parts[1] spanID:parts[2] sampled:(flags & 1) != 0 remote:YES
                           traceState:OTUsableTraceState(tracestate)];
}

- (NSDictionary<NSString *, NSString *> *)propagationHeaders
{
  return _traceState ? @{ @"traceparent": self.traceparent, @"tracestate": _traceState } : @{ @"traceparent": self.traceparent };
}

- (NSString *)traceparent
{
  return [NSString stringWithFormat:@"00-%@-%@-%@", _traceID, _spanID, _sampled ? @"01" : @"00"];
}

- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

- (BOOL)isEqual:(id)object
{
  if (![object isKindOfClass:[OTSpanContext class]]) return NO;
  OTSpanContext *other = object;
  return [_traceID isEqualToString:other.traceID] && [_spanID isEqualToString:other.spanID] && _sampled == other.sampled;
}

- (NSUInteger)hash
{
  return _spanID.hash;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<OTSpanContext %@%@>", self.traceparent, _remote ? @" remote" : @""];
}

@end

#pragma mark - Spans

static NSString * const OTCurrentSpansKey = @"OTelKit.currentSpans";

static NSMutableArray<OTSpan *> *OTCurrentSpans(BOOL create)
{
  NSMutableDictionary *thread = [NSThread currentThread].threadDictionary;
  NSMutableArray *spans = thread[OTCurrentSpansKey];
  if (!spans && create) {
    spans = [NSMutableArray array];
    thread[OTCurrentSpansKey] = spans;
  }
  return spans;
}

// A value an attribute can have: a string, a number, or an array of them.
static id OTAttributeValue(id value)
{
  if ([value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]]) return [value copy];
  if ([value isKindOfClass:[NSArray class]]) {
    NSMutableArray *items = [NSMutableArray array];
    for (id item in value) {
      id kept = [item isKindOfClass:[NSArray class]] ? nil : OTAttributeValue(item);
      if (kept) [items addObject:kept];
    }
    return items;
  }
  if ([value isKindOfClass:[NSURL class]]) return [value absoluteString];
  return value ? [value description] : nil;
}

@interface OTSpan ()
- (instancetype)initWithName:(NSString *)name kind:(OTSpanKind)kind context:(OTSpanContext *)context
                parentSpanID:(NSString *)parentSpanID tracer:(OTTracer *)tracer resource:(NSDictionary *)resource
                   processor:(id<OTSpanProcessor>)processor startTime:(uint64_t)startTime;
@end

@implementation OTSpan {
  NSMutableDictionary<NSString *, id> *_attributes;
  NSMutableArray<NSDictionary *> *_events;
  id<OTSpanProcessor> _processor;
  NSString *_name;
  NSString *_statusMessage;
  OTStatusCode _status;
  uint64_t _endTime;
  BOOL _ended;
}

- (instancetype)initWithName:(NSString *)name kind:(OTSpanKind)kind context:(OTSpanContext *)context
                parentSpanID:(NSString *)parentSpanID tracer:(OTTracer *)tracer resource:(NSDictionary *)resource
                   processor:(id<OTSpanProcessor>)processor startTime:(uint64_t)startTime
{
  self = [super init];
  if (!self) return nil;
  _name = [name copy];
  _kind = kind;
  _context = context;
  _parentSpanID = [parentSpanID copy];
  _scopeName = [tracer.name copy] ?: @"";
  _scopeVersion = [tracer.version copy];
  _resource = [resource copy] ?: @{};
  _processor = processor;
  _recording = processor != nil;
  _startTime = startTime ?: OTNow();
  if (_recording) {
    _attributes = [NSMutableDictionary dictionary];
    _events = [NSMutableArray array];
  }
  return self;
}

- (NSString *)name
{
  @synchronized (self) {
    return _name;
  }
}

- (void)setName:(NSString *)name
{
  @synchronized (self) {
    if (!_ended && name.length) _name = [name copy];
  }
}

- (uint64_t)endTime
{
  @synchronized (self) {
    return _endTime;
  }
}

- (BOOL)hasEnded
{
  @synchronized (self) {
    return _ended;
  }
}

- (NSDictionary *)attributes
{
  @synchronized (self) {
    return [_attributes copy] ?: @{};
  }
}

- (NSArray *)events
{
  @synchronized (self) {
    return [_events copy] ?: @[];
  }
}

- (OTStatusCode)status
{
  @synchronized (self) {
    return _status;
  }
}

- (NSString *)statusMessage
{
  @synchronized (self) {
    return _statusMessage;
  }
}

- (void)setAttribute:(id)value forKey:(NSString *)key
{
  if (!_recording || !key.length) return;
  id kept = OTAttributeValue(value);
  @synchronized (self) {
    if (_ended) return;
    if (kept) {
      _attributes[key] = kept;
    } else {
      [_attributes removeObjectForKey:key];
    }
  }
}

- (void)addAttributes:(NSDictionary *)attributes
{
  if (!_recording) return;
  for (NSString *key in attributes) [self setAttribute:attributes[key] forKey:key];
}

- (void)addEventNamed:(NSString *)name attributes:(NSDictionary *)attributes
{
  if (!_recording) return;
  NSMutableDictionary *kept = [NSMutableDictionary dictionary];
  for (NSString *key in attributes) {
    id value = OTAttributeValue(attributes[key]);
    if (value) kept[key] = value;
  }
  NSDictionary *event = @{ @"name": [name copy] ?: @"", @"time": @(OTNow()), @"attributes": kept };
  @synchronized (self) {
    // Bounded, as OpenTelemetry's SDKs bound them.
    if (!_ended && _events.count < 128) [_events addObject:event];
  }
}

- (void)setStatus:(OTStatusCode)status message:(NSString *)message
{
  @synchronized (self) {
    if (_ended) return;
    // OK is final; Error is not undone by Unset.
    if (_status == OTStatusOK || (status == OTStatusUnset && _status == OTStatusError)) return;
    _status = status;
    _statusMessage = status == OTStatusError ? [message copy] : nil;
  }
}

- (void)recordError:(NSError *)error
{
  if (!error) return;
  NSString *type = [NSString stringWithFormat:@"%@ %ld", error.domain, (long)error.code];
  [self addEventNamed:@"exception" attributes:@{ @"exception.type": type, @"exception.message": error.localizedDescription ?: @"" }];
  [self setStatus:OTStatusError message:error.localizedDescription];
}

- (void)end
{
  [self endAtTime:0];
}

- (void)endAtTime:(uint64_t)time
{
  @synchronized (self) {
    if (_ended) return;
    _ended = YES;
    _endTime = MAX(time ?: OTNow(), _startTime);
  }
  [self resignCurrent];
  if (_recording) [_processor spanDidEnd:self];
}

+ (OTSpan *)currentSpan
{
  return OTCurrentSpans(NO).lastObject;
}

- (void)becomeCurrent
{
  if (self.hasEnded) return;
  [OTCurrentSpans(YES) addObject:self];
}

- (void)resignCurrent
{
  NSMutableArray *spans = OTCurrentSpans(NO);
  NSUInteger index = [spans indexOfObjectIdenticalTo:self];
  if (index != NSNotFound) [spans removeObjectAtIndex:index];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<OTSpan %@ %@ %@%@>", self.name, _context.spanID, _context.traceID,
                                    _parentSpanID ? [@" under " stringByAppendingString:_parentSpanID] : @""];
}

@end

#pragma mark - Samplers

@implementation OTRatioSampler

- (instancetype)initWithRatio:(double)ratio
{
  self = [super init];
  if (!self) return nil;
  _ratio = ratio < 0 ? 0 : ratio > 1 ? 1 : ratio;
  return self;
}

- (BOOL)shouldSampleTraceID:(NSString *)traceID parent:(OTSpanContext *)parent name:(NSString *)name kind:(OTSpanKind)kind
{
  if (_ratio >= 1) return YES;
  if (_ratio <= 0 || traceID.length < 16) return NO;
  // The trace ID's last 8 bytes, as a fraction of their range.
  unsigned long long low = strtoull([traceID substringFromIndex:traceID.length - 16].UTF8String, NULL, 16);
  return (double)low < _ratio * 18446744073709551615.0;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"traceidratio(%g)", _ratio];
}

@end

@implementation OTParentBasedSampler

- (instancetype)initWithRootSampler:(id<OTSampler>)root
{
  self = [super init];
  if (!self) return nil;
  _root = root;
  return self;
}

- (BOOL)shouldSampleTraceID:(NSString *)traceID parent:(OTSpanContext *)parent name:(NSString *)name kind:(OTSpanKind)kind
{
  if (parent) return parent.sampled;
  return [_root shouldSampleTraceID:traceID parent:nil name:name kind:kind];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"parentbased(%@)", _root];
}

@end

#pragma mark - Processors

@implementation OTBatchSpanProcessor {
  NSCondition *_condition;
  NSMutableArray<OTSpan *> *_queue;
  NSUInteger _dropped;
  BOOL _started, _finished, _shutdown, _flushing, _exporting;
}

- (instancetype)initWithExporter:(id<OTSpanExporter>)exporter
{
  self = [super init];
  if (!self) return nil;
  _exporter = exporter;
  _maxQueueSize = 2048;
  _maxBatchSize = 512;
  _scheduleDelay = 5;
  _condition = [[NSCondition alloc] init];
  _queue = [NSMutableArray array];
  return self;
}

- (void)spanDidEnd:(OTSpan *)span
{
  [_condition lock];
  if (!_shutdown) {
    if (!_started) {
      _started = YES;
      [NSThread detachNewThreadSelector:@selector(work) toTarget:self withObject:nil];
    }
    if (_queue.count >= _maxQueueSize) {
      _dropped++;
    } else {
      [_queue addObject:span];
      if (_queue.count >= _maxBatchSize) [_condition broadcast];
    }
  }
  [_condition unlock];
}

- (void)work
{
  for (;;) {
    @autoreleasepool {
      [_condition lock];
      NSDate *due = [NSDate dateWithTimeIntervalSinceNow:_scheduleDelay];
      while (!_shutdown && !_flushing && _queue.count < _maxBatchSize) {
        if (![_condition waitUntilDate:due]) break;
      }
      if (_shutdown && !_queue.count) {
        NSUInteger dropped = _dropped;
        _dropped = 0;
        _finished = YES;
        [_condition broadcast];
        [_condition unlock];
        id<OTExportObserver> observer = self.observer;
        if (dropped && [observer respondsToSelector:@selector(spanProcessor:didDropSpans:)]) {
          [observer spanProcessor:self didDropSpans:dropped];
        }
        return;
      }
      NSRange taken = NSMakeRange(0, MIN(_queue.count, _maxBatchSize));
      NSArray<OTSpan *> *batch = [_queue subarrayWithRange:taken];
      [_queue removeObjectsInRange:taken];
      NSUInteger dropped = _dropped;
      _dropped = 0;
      _exporting = batch.count > 0;
      [_condition unlock];

      id<OTExportObserver> observer = self.observer;
      if (dropped && [observer respondsToSelector:@selector(spanProcessor:didDropSpans:)]) {
        [observer spanProcessor:self didDropSpans:dropped];
      }
      if (batch.count) {
        NSError *error = nil;
        BOOL sent = NO;
        @try {
          sent = [_exporter exportSpans:batch error:&error];
        } @catch (NSException *exception) {
          error = OTError([NSString stringWithFormat:@"the exporter raised %@: %@", exception.name, exception.reason]);
        }
        if (sent && [observer respondsToSelector:@selector(spanProcessor:didExportSpans:)]) {
          [observer spanProcessor:self didExportSpans:batch.count];
        } else if (!sent && [observer respondsToSelector:@selector(spanProcessor:didFailToExportSpans:error:)]) {
          [observer spanProcessor:self didFailToExportSpans:batch.count error:error ?: OTError(@"the exporter did not take the spans")];
        }
      }

      [_condition lock];
      _exporting = NO;
      if (!_queue.count) _flushing = NO;
      [_condition broadcast];
      [_condition unlock];
    }
  }
}

- (BOOL)forceFlushWithTimeout:(NSTimeInterval)timeout
{
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
  [_condition lock];
  if (_started && !_finished) {
    _flushing = YES;
    [_condition broadcast];
    while ((_queue.count || _exporting || _flushing) && !_finished) {
      if (![_condition waitUntilDate:until]) break;
    }
  }
  BOOL flushed = !_queue.count && !_exporting;
  [_condition unlock];
  return flushed;
}

- (void)shutdownWithTimeout:(NSTimeInterval)timeout
{
  NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout];
  [_condition lock];
  _shutdown = YES;
  [_condition broadcast];
  while (_started && !_finished) {
    if (![_condition waitUntilDate:until]) break;
  }
  [_condition unlock];
  if ([_exporter respondsToSelector:@selector(shutdown)]) [_exporter shutdown];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<OTBatchSpanProcessor %@>", _exporter];
}

@end

@implementation OTSimpleSpanProcessor

- (instancetype)initWithExporter:(id<OTSpanExporter>)exporter
{
  self = [super init];
  if (!self) return nil;
  _exporter = exporter;
  return self;
}

- (void)spanDidEnd:(OTSpan *)span
{
  [_exporter exportSpans:@[ span ] error:NULL];
}

- (BOOL)forceFlushWithTimeout:(NSTimeInterval)timeout
{
  return YES;
}

- (void)shutdownWithTimeout:(NSTimeInterval)timeout
{
  if ([_exporter respondsToSelector:@selector(shutdown)]) [_exporter shutdown];
}

@end

@implementation OTInMemoryExporter {
  NSMutableArray<OTSpan *> *_spans;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _spans = [NSMutableArray array];
  return self;
}

- (BOOL)exportSpans:(NSArray<OTSpan *> *)spans error:(NSError **)error
{
  @synchronized (self) {
    [_spans addObjectsFromArray:spans];
  }
  return YES;
}

- (NSArray *)spans
{
  @synchronized (self) {
    return [_spans copy];
  }
}

- (void)reset
{
  @synchronized (self) {
    [_spans removeAllObjects];
  }
}

@end

#pragma mark - Provider

static OTTracerProvider *OTShared;

@implementation OTTracerProvider

+ (OTTracerProvider *)sharedProvider
{
  @synchronized (self) {
    if (!OTShared) OTShared = [[OTTracerProvider alloc] init];
    return OTShared;
  }
}

+ (void)setSharedProvider:(OTTracerProvider *)provider
{
  @synchronized (self) {
    OTShared = provider ?: [[OTTracerProvider alloc] init];
  }
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _resource = @{};
  return self;
}

- (instancetype)initWithResource:(NSDictionary *)resource sampler:(id<OTSampler>)sampler processor:(id<OTSpanProcessor>)processor
{
  self = [super init];
  if (!self) return nil;
  NSMutableDictionary *all = [NSMutableDictionary dictionary];
  NSProcessInfo *process = [NSProcessInfo processInfo];
  all[@"service.name"] = [@"unknown_service:" stringByAppendingString:process.processName ?: @"objc"];
  all[@"host.name"] = process.hostName ?: @"";
  all[@"process.pid"] = @(process.processIdentifier);
  for (NSString *key in resource) {
    id value = OTAttributeValue(resource[key]);
    if (value) all[key] = value;
  }
  all[@"telemetry.sdk.name"] = @"OTelKit";
  all[@"telemetry.sdk.language"] = @"objective-c";
  all[@"telemetry.sdk.version"] = @OTELKIT_VERSION;
  _resource = all;
  _sampler = sampler;
  _processor = processor;
  return self;
}

- (BOOL)isRecording
{
  return _processor != nil;
}

- (BOOL)forceFlushWithTimeout:(NSTimeInterval)timeout
{
  return _processor ? [_processor forceFlushWithTimeout:timeout] : YES;
}

- (void)shutdownWithTimeout:(NSTimeInterval)timeout
{
  [_processor shutdownWithTimeout:timeout];
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<OTTracerProvider %@ %@ %@>", _resource[@"service.name"] ?: @"(not recording)",
                                    (id)_sampler ?: @"", (id)_processor ?: @""];
}

// key=value,key=value, the values percent-encoded (W3C Baggage's form, as
// OTEL_RESOURCE_ATTRIBUTES and OTEL_EXPORTER_OTLP_HEADERS have it).
static NSDictionary<NSString *, NSString *> *OTPairs(NSString *text)
{
  NSMutableDictionary *pairs = [NSMutableDictionary dictionary];
  for (NSString *pair in [text ?: @"" componentsSeparatedByString:@","]) {
    NSRange equals = [pair rangeOfString:@"="];
    if (equals.location == NSNotFound) continue;
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    NSString *key = [[pair substringToIndex:equals.location] stringByTrimmingCharactersInSet:space];
    NSString *value = [[pair substringFromIndex:equals.location + 1] stringByTrimmingCharactersInSet:space];
    if (key.length) pairs[key] = [value stringByRemovingPercentEncoding] ?: value;
  }
  return pairs;
}

static NSString *OTSetting(NSDictionary *environment, NSString *name)
{
  NSString *value = [environment[name] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  return value.length ? value : nil;
}

+ (instancetype)providerWithEnvironment:(NSDictionary<NSString *, NSString *> *)environment defaults:(NSDictionary *)defaults
                                  error:(NSError **)error
{
  if ([[OTSetting(environment, @"OTEL_SDK_DISABLED") lowercaseString] isEqualToString:@"true"]) return nil;
  NSString *tracesEndpoint = OTSetting(environment, @"OTEL_EXPORTER_OTLP_TRACES_ENDPOINT");
  NSString *endpoint = OTSetting(environment, @"OTEL_EXPORTER_OTLP_ENDPOINT");
  NSString *exporterName = [OTSetting(environment, @"OTEL_TRACES_EXPORTER") lowercaseString];
  // OpenTelemetry's default exporter is otlp; here an endpoint, or naming
  // it, turns tracing on, so a server without a collector does not try one.
  if (!exporterName) exporterName = tracesEndpoint || endpoint ? @"otlp" : @"none";
  if ([exporterName isEqualToString:@"none"]) return nil;
  if (![exporterName isEqualToString:@"otlp"]) {
    if (error) *error = OTError([NSString stringWithFormat:@"OTEL_TRACES_EXPORTER %@: only otlp is known here", exporterName]);
    return nil;
  }
  NSString *protocol = OTSetting(environment, @"OTEL_EXPORTER_OTLP_TRACES_PROTOCOL") ?: OTSetting(environment, @"OTEL_EXPORTER_OTLP_PROTOCOL");
  if (protocol && ![protocol isEqualToString:@"http/json"]) {
    if (error) *error = OTError([NSString stringWithFormat:@"OTLP protocol %@: only http/json is known here (a collector takes it on 4318)", protocol]);
    return nil;
  }
  NSURL *url = nil;
  if (tracesEndpoint) {
    url = [NSURL URLWithString:tracesEndpoint];
  } else {
    NSString *base = endpoint ?: @"http://localhost:4318";
    url = [NSURL URLWithString:[base stringByAppendingString:[base hasSuffix:@"/"] ? @"v1/traces" : @"/v1/traces"]];
  }
  if (!url.scheme || !url.host) {
    if (error) *error = OTError([NSString stringWithFormat:@"the OTLP endpoint %@ is not a URL", tracesEndpoint ?: endpoint]);
    return nil;
  }
  OTLPExporter *exporter = [[OTLPExporter alloc] initWithEndpoint:url];
  NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:OTPairs(OTSetting(environment, @"OTEL_EXPORTER_OTLP_HEADERS"))];
  [headers addEntriesFromDictionary:OTPairs(OTSetting(environment, @"OTEL_EXPORTER_OTLP_TRACES_HEADERS"))];
  exporter.headers = headers;
  NSString *timeout = OTSetting(environment, @"OTEL_EXPORTER_OTLP_TRACES_TIMEOUT") ?: OTSetting(environment, @"OTEL_EXPORTER_OTLP_TIMEOUT");
  if (timeout.doubleValue > 0) exporter.timeout = timeout.doubleValue / 1000.0;

  NSString *samplerName = [OTSetting(environment, @"OTEL_TRACES_SAMPLER") lowercaseString] ?: @"parentbased_always_on";
  NSString *argument = OTSetting(environment, @"OTEL_TRACES_SAMPLER_ARG");
  double ratio = argument ? argument.doubleValue : 1.0;
  BOOL parentBased = [samplerName hasPrefix:@"parentbased_"];
  NSString *rootName = parentBased ? [samplerName substringFromIndex:12] : samplerName;
  id<OTSampler> root = nil;
  if ([rootName isEqualToString:@"always_on"]) {
    root = [[OTRatioSampler alloc] initWithRatio:1];
  } else if ([rootName isEqualToString:@"always_off"]) {
    root = [[OTRatioSampler alloc] initWithRatio:0];
  } else if ([rootName isEqualToString:@"traceidratio"]) {
    root = [[OTRatioSampler alloc] initWithRatio:ratio];
  } else {
    if (error) *error = OTError([NSString stringWithFormat:@"OTEL_TRACES_SAMPLER %@ is not known here", samplerName]);
    return nil;
  }
  id<OTSampler> sampler = parentBased ? [[OTParentBasedSampler alloc] initWithRootSampler:root] : root;

  OTBatchSpanProcessor *processor = [[OTBatchSpanProcessor alloc] initWithExporter:exporter];
  NSString *delay = OTSetting(environment, @"OTEL_BSP_SCHEDULE_DELAY");
  if (delay.doubleValue > 0) processor.scheduleDelay = delay.doubleValue / 1000.0;
  NSString *queue = OTSetting(environment, @"OTEL_BSP_MAX_QUEUE_SIZE");
  if (queue.integerValue > 0) processor.maxQueueSize = (NSUInteger)queue.integerValue;
  NSString *batch = OTSetting(environment, @"OTEL_BSP_MAX_EXPORT_BATCH_SIZE");
  if (batch.integerValue > 0) processor.maxBatchSize = MIN((NSUInteger)batch.integerValue, processor.maxQueueSize);
  NSString *exportTimeout = OTSetting(environment, @"OTEL_BSP_EXPORT_TIMEOUT");
  if (exportTimeout.doubleValue > 0) exporter.timeout = MIN(exporter.timeout, exportTimeout.doubleValue / 1000.0);

  NSMutableDictionary *resource = [NSMutableDictionary dictionaryWithDictionary:defaults ?: @{}];
  [resource addEntriesFromDictionary:OTPairs(OTSetting(environment, @"OTEL_RESOURCE_ATTRIBUTES"))];
  NSString *service = OTSetting(environment, @"OTEL_SERVICE_NAME");
  if (service) resource[@"service.name"] = service;
  return [[self alloc] initWithResource:resource sampler:sampler processor:processor];
}

@end

#pragma mark - Tracer

@implementation OTTracer

+ (OTTracer *)tracerNamed:(NSString *)name version:(NSString *)version
{
  return [[self alloc] initWithName:name version:version provider:nil];
}

- (instancetype)initWithName:(NSString *)name version:(NSString *)version provider:(OTTracerProvider *)provider
{
  self = [super init];
  if (!self) return nil;
  _name = [name copy];
  _version = [version copy];
  _provider = provider;
  return self;
}

- (OTSpan *)startSpanNamed:(NSString *)name kind:(OTSpanKind)kind parent:(OTSpanContext *)parent attributes:(NSDictionary *)attributes
{
  return [self startSpanNamed:name kind:kind parent:parent attributes:attributes startTime:0];
}

- (OTSpan *)startSpanNamed:(NSString *)name kind:(OTSpanKind)kind parent:(OTSpanContext *)parent attributes:(NSDictionary *)attributes
                 startTime:(uint64_t)startTime
{
  OTTracerProvider *provider = _provider ?: [OTTracerProvider sharedProvider];
  NSString *traceID = parent.traceID ?: OTNewTraceID();
  BOOL sampled;
  if (provider.recording) {
    sampled = provider.sampler ? [provider.sampler shouldSampleTraceID:traceID parent:parent name:name kind:kind] : YES;
  } else {
    // Recording nothing, a trace passes through as it came.
    sampled = parent.sampled;
  }
  OTSpanContext *context = [[OTSpanContext alloc] initWithTraceID:traceID spanID:OTNewSpanID() sampled:sampled remote:NO
                                                       traceState:parent.traceState];
  OTSpan *span = [[OTSpan alloc] initWithName:name kind:kind context:context parentSpanID:parent.spanID tracer:self
                                     resource:provider.resource processor:sampled ? provider.processor : nil startTime:startTime];
  if (attributes) [span addAttributes:attributes];
  return span;
}

- (OTSpan *)startSpanNamed:(NSString *)name attributes:(NSDictionary *)attributes
{
  OTSpan *span = [self startSpanNamed:name kind:OTSpanKindInternal parent:[OTSpan currentSpan].context attributes:attributes];
  [span becomeCurrent];
  return span;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<OTTracer %@ %@>", _name, _version ?: @""];
}

@end
