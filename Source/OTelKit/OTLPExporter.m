// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OTLPExporter.h"
#if defined(__APPLE__)
#import <CoreFoundation/CoreFoundation.h>
#endif

#if defined(__APPLE__) || (defined(GS_HAVE_NSURLSESSION) && GS_HAVE_NSURLSESSION)
#define OT_HAVE_NSURLSESSION 1
#include <dispatch/dispatch.h>
#else
#define OT_HAVE_NSURLSESSION 0
#endif

#pragma mark - Encoding

static BOOL OTIsBoolean(NSNumber *number)
{
#if defined(__APPLE__)
  return CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID();
#else
  // gnustep-base's @YES and @NO are of a class of their own.
  static Class booleans;
  if (!booleans) booleans = NSClassFromString(@"NSBoolNumber");
  if (booleans) return [number isKindOfClass:booleans];
  const char *type = number.objCType;
  return type && type[0] == 'B' && type[1] == 0;
#endif
}

// OTLP's AnyValue, as its JSON mapping has it: 64-bit integers as strings.
static NSDictionary *OTAnyValue(id value)
{
  if ([value isKindOfClass:[NSString class]]) return @{ @"stringValue": value };
  if ([value isKindOfClass:[NSNumber class]]) {
    NSNumber *number = value;
    if (OTIsBoolean(number)) return @{ @"boolValue": number.boolValue ? @YES : @NO };
    const char *type = number.objCType;
    if (type && (type[0] == 'f' || type[0] == 'd')) return @{ @"doubleValue": number };
    return @{ @"intValue": number.stringValue };
  }
  if ([value isKindOfClass:[NSArray class]]) {
    NSMutableArray *values = [NSMutableArray array];
    for (id item in value) [values addObject:OTAnyValue(item)];
    return @{ @"arrayValue": @{ @"values": values } };
  }
  return @{ @"stringValue": [value description] ?: @"" };
}

static NSArray *OTKeyValues(NSDictionary<NSString *, id> *attributes)
{
  NSMutableArray *list = [NSMutableArray array];
  for (NSString *key in [attributes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [list addObject:@{ @"key": key, @"value": OTAnyValue(attributes[key]) }];
  }
  return list;
}

static NSString *OTNanos(uint64_t nanos)
{
  return [NSString stringWithFormat:@"%llu", (unsigned long long)nanos];
}

static NSDictionary *OTSpanJSON(OTSpan *span)
{
  NSMutableDictionary *json = [NSMutableDictionary dictionary];
  json[@"traceId"] = span.context.traceID;
  json[@"spanId"] = span.context.spanID;
  if (span.parentSpanID) json[@"parentSpanId"] = span.parentSpanID;
  json[@"name"] = span.name;
  json[@"kind"] = @(span.kind);
  json[@"startTimeUnixNano"] = OTNanos(span.startTime);
  json[@"endTimeUnixNano"] = OTNanos(span.endTime ?: span.startTime);
  NSDictionary *attributes = span.attributes;
  if (attributes.count) json[@"attributes"] = OTKeyValues(attributes);
  NSMutableArray *events = [NSMutableArray array];
  for (NSDictionary *event in span.events) {
    NSMutableDictionary *one = [NSMutableDictionary dictionary];
    one[@"name"] = event[@"name"];
    one[@"timeUnixNano"] = OTNanos([event[@"time"] unsignedLongLongValue]);
    if ([event[@"attributes"] count]) one[@"attributes"] = OTKeyValues(event[@"attributes"]);
    [events addObject:one];
  }
  if (events.count) json[@"events"] = events;
  if (span.status != OTStatusUnset) {
    NSMutableDictionary *status = [NSMutableDictionary dictionaryWithObject:@(span.status) forKey:@"code"];
    if (span.statusMessage) status[@"message"] = span.statusMessage;
    json[@"status"] = status;
  }
  return json;
}

#pragma mark - Exporter

@implementation OTLPExporter

- (instancetype)initWithEndpoint:(NSURL *)endpoint
{
  self = [super init];
  if (!self) return nil;
  _endpoint = [endpoint copy];
  _headers = @{};
  _timeout = 10;
  return self;
}

+ (NSDictionary *)requestForSpans:(NSArray<OTSpan *> *)spans
{
  // Resource, then scope, then the spans of each, in the order they came.
  NSMutableArray<NSDictionary *> *resources = [NSMutableArray array];
  NSMutableArray<NSMutableArray *> *scopesOfResource = [NSMutableArray array];
  for (OTSpan *span in spans) {
    NSUInteger r = [resources indexOfObject:span.resource];
    if (r == NSNotFound) {
      [resources addObject:span.resource];
      [scopesOfResource addObject:[NSMutableArray array]];
      r = resources.count - 1;
    }
    NSMutableArray *scopes = scopesOfResource[r];
    NSMutableDictionary *scope = nil;
    for (NSMutableDictionary *candidate in scopes) {
      if ([candidate[@"name"] isEqual:span.scopeName] && [candidate[@"version"] isEqual:span.scopeVersion ?: @""]) scope = candidate;
    }
    if (!scope) {
      scope = [NSMutableDictionary dictionaryWithDictionary:@{ @"name": span.scopeName, @"version": span.scopeVersion ?: @"",
                                                               @"spans": [NSMutableArray array] }];
      [scopes addObject:scope];
    }
    [scope[@"spans"] addObject:OTSpanJSON(span)];
  }
  NSMutableArray *resourceSpans = [NSMutableArray array];
  for (NSUInteger r = 0; r < resources.count; r++) {
    NSMutableArray *scopeSpans = [NSMutableArray array];
    for (NSDictionary *scope in scopesOfResource[r]) {
      NSMutableDictionary *named = [NSMutableDictionary dictionaryWithObject:scope[@"name"] forKey:@"name"];
      if ([scope[@"version"] length]) named[@"version"] = scope[@"version"];
      [scopeSpans addObject:@{ @"scope": named, @"spans": scope[@"spans"] }];
    }
    [resourceSpans addObject:@{ @"resource": @{ @"attributes": OTKeyValues(resources[r]) }, @"scopeSpans": scopeSpans }];
  }
  return @{ @"resourceSpans": resourceSpans };
}

- (BOOL)exportSpans:(NSArray<OTSpan *> *)spans error:(NSError **)error
{
  NSData *body = [NSJSONSerialization dataWithJSONObject:[OTLPExporter requestForSpans:spans] options:0 error:error];
  if (!body) return NO;
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:_timeout];
  NSTimeInterval backoff = 1;
  for (;;) {
    NSTimeInterval left = [deadline timeIntervalSinceNow];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:_endpoint];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = MAX(left, 1);
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    for (NSString *name in _headers) [request setValue:_headers[name] forHTTPHeaderField:name];
    NSHTTPURLResponse *response = nil;
    NSError *failure = nil;
    NSData *answer = [self send:request response:&response error:&failure];
    NSInteger status = response.statusCode;
    if (response && status >= 200 && status < 300) return YES;
    BOOL again = !response || status == 429 || status == 502 || status == 503 || status == 504;
    if (!failure) {
      NSString *text = answer.length ? [[NSString alloc] initWithData:answer encoding:NSUTF8StringEncoding] : @"";
      if (text.length > 200) text = [[text substringToIndex:200] stringByAppendingString:@"…"];
      failure = [NSError errorWithDomain:OTErrorDomain code:status
                                userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ answered %ld %@", _endpoint, (long)status, text] }];
    }
    NSTimeInterval wait = backoff;
    NSString *retryAfter = [response.allHeaderFields[@"Retry-After"] description];
    if (retryAfter.doubleValue > 0) wait = retryAfter.doubleValue;
    if (!again || wait >= [deadline timeIntervalSinceNow]) {
      if (error) *error = failure;
      return NO;
    }
    [NSThread sleepForTimeInterval:wait];
    backoff = MIN(backoff * 2, 8);
  }
}

// Synchronous: the processor's thread waits.
- (NSData *)send:(NSURLRequest *)request response:(NSHTTPURLResponse **)response error:(NSError **)error
{
#if OT_HAVE_NSURLSESSION
  if (NSClassFromString(@"NSURLSession")) {
    __block NSData *data = nil;
    __block NSURLResponse *answered = nil;
    __block NSError *failed = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
      data = d;
      answered = r;
      failed = e;
      dispatch_semaphore_signal(done);
    }];
    [task resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    *response = [answered isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)answered : nil;
    *error = failed;
    return data;
  }
#endif
#if !defined(__APPLE__)
  NSURLResponse *answered = nil;
  NSData *data = [NSURLConnection sendSynchronousRequest:request returningResponse:&answered error:error];
  *response = [answered isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)answered : nil;
  return data;
#else
  return nil;
#endif
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"<OTLPExporter %@>", _endpoint];
}

@end
