// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSLog.h"
#import "HSMessage.h"
#import "HSStages.h"
#import "HSObservability.h"
#import <OTelKit/OTTrace.h>
#include <stdio.h>
#include <time.h>

static HSLog *HSSharedLog;

// UTC, to the millisecond: 2026-10-01T16:04:10.804Z.
NSString *HSLogTimestamp(void)
{
  struct timespec now;
  clock_gettime(CLOCK_REALTIME, &now);
  struct tm parts;
  gmtime_r(&now.tv_sec, &parts);
  char text[32];
  strftime(text, sizeof text, "%Y-%m-%dT%H:%M:%S", &parts);
  return [NSString stringWithFormat:@"%s.%03ldZ", text, (long)(now.tv_nsec / 1000000)];
}

@implementation HSLog {
  NSLock *_writing;
}

+ (HSLog *)sharedLog
{
  @synchronized (self) {
    if (!HSSharedLog) HSSharedLog = [[HSLog alloc] init];
    return HSSharedLog;
  }
}

+ (void)setSharedLog:(HSLog *)log
{
  @synchronized (self) {
    HSSharedLog = log ?: [[HSLog alloc] init];
  }
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _level = HSLogLevelInfo;
  _format = HSLogFormatText;
  _writing = [[NSLock alloc] init];
  return self;
}

+ (NSNumber *)levelNamed:(NSString *)name
{
  NSDictionary *levels = @{ @"debug": @(HSLogLevelDebug), @"info": @(HSLogLevelInfo), @"warn": @(HSLogLevelWarn),
                            @"warning": @(HSLogLevelWarn), @"error": @(HSLogLevelError) };
  return [name isKindOfClass:[NSString class]] ? levels[name.lowercaseString] : nil;
}

static NSString *HSLevelName(HSLogLevel level)
{
  switch (level) {
    case HSLogLevelDebug: return @"debug";
    case HSLogLevelInfo: return @"info";
    case HSLogLevelWarn: return @"warn";
    case HSLogLevelError: return @"error";
  }
  return @"info";
}

- (BOOL)logsLevel:(HSLogLevel)level
{
  return level >= self.level;
}

- (void)log:(HSLogLevel)level component:(NSString *)component message:(NSString *)message fields:(NSDictionary *)fields
{
  if (![self logsLevel:level]) return;
  if (self.format == HSLogFormatJSON) {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    for (NSString *key in fields) {
      id value = fields[key];
      entry[key] = [NSJSONSerialization isValidJSONObject:@[ value ]] ? value : [value description];
    }
    entry[@"time"] = HSLogTimestamp();
    entry[@"level"] = HSLevelName(level);
    entry[@"component"] = component ?: @"";
    entry[@"message"] = message ?: @"";
    NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:NULL];
    if (json) [self writeLine:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    return;
  }
  NSMutableString *line = [NSMutableString stringWithFormat:@"%@: ", component ?: @""];
  if (level == HSLogLevelWarn) [line appendString:@"warning: "];
  if (level == HSLogLevelError) [line appendString:@"error: "];
  if (level == HSLogLevelDebug) [line appendString:@"debug: "];
  [line appendString:message ?: @""];
  if (fields.count) {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSString *key in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      [pairs addObject:[NSString stringWithFormat:@"%@=%@", key, fields[key]]];
    }
    [line appendFormat:@" (%@)", [pairs componentsJoinedByString:@", "]];
  }
  [self writeLine:line];
}

+ (NSDictionary *)fieldsOfRequest:(HSRequest *)request
{
  if (!request) return @{};
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  if (request.userInfo[HSRequestIDKey]) fields[@"request_id"] = request.userInfo[HSRequestIDKey];
  OTSpanContext *context = request.span.context;
  if (context) {
    fields[@"trace_id"] = context.traceID;
    fields[@"span_id"] = context.spanID;
  } else if (request.userInfo[HSTraceIDKey]) {
    fields[@"trace_id"] = request.userInfo[HSTraceIDKey];
  }
  return fields;
}

+ (NSDictionary *)fieldsOfHeaders:(NSDictionary<NSString *, NSString *> *)headers
{
  NSMutableDictionary *fields = [NSMutableDictionary dictionary];
  for (NSString *name in headers) {
    if ([name caseInsensitiveCompare:@"X-Request-ID"] == NSOrderedSame) fields[@"request_id"] = headers[name];
    if ([name caseInsensitiveCompare:@"traceparent"] == NSOrderedSame) {
      OTSpanContext *context = [OTSpanContext contextWithTraceparent:headers[name]];
      if (context) {
        fields[@"trace_id"] = context.traceID;
        fields[@"span_id"] = context.spanID;
      }
    }
  }
  return fields;
}

- (void)writeLine:(NSString *)line
{
  // One line at a time, whole, whichever thread writes.
  [_writing lock];
  fprintf(stderr, "%s\n", line.UTF8String);
  fflush(stderr);
  [_writing unlock];
}

@end

void HSLogMessage(HSLogLevel level, NSString *component, HSRequest *request, NSString *format, ...)
{
  HSLog *log = [HSLog sharedLog];
  if (![log logsLevel:level]) return;
  va_list arguments;
  va_start(arguments, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  [log log:level component:component message:message fields:[HSLog fieldsOfRequest:request]];
}
