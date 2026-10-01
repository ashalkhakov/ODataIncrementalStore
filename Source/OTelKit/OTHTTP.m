// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "OTHTTP.h"

@implementation NSMutableURLRequest (OTelKit)

- (void)ot_setTraceContext:(OTSpanContext *)context
{
  NSDictionary *headers = context.propagationHeaders;
  for (NSString *name in headers) [self setValue:headers[name] forHTTPHeaderField:name];
  // A tracestate of an earlier context is not this one's.
  if (!headers[@"tracestate"]) [self setValue:nil forHTTPHeaderField:@"tracestate"];
}

@end

// The URL as a span may say it: without a user or a password.
static NSString *OTURLWithoutCredentials(NSURL *url)
{
  if (!url.user && !url.password) return url.absoluteString;
  NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
  components.user = nil;
  components.password = nil;
  return components.URL.absoluteString ?: @"";
}

@implementation OTTracer (OTHTTP)

- (OTSpan *)startClientSpanForRequest:(NSMutableURLRequest *)request name:(NSString *)name parent:(OTSpanContext *)parent
{
  NSString *method = request.HTTPMethod.length ? request.HTTPMethod : @"GET";
  NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
  attributes[@"http.request.method"] = method;
  attributes[@"url.full"] = OTURLWithoutCredentials(request.URL);
  attributes[@"server.address"] = request.URL.host;
  NSNumber *port = request.URL.port;
  if (!port) port = [request.URL.scheme isEqualToString:@"https"] ? @443 : @80;
  attributes[@"server.port"] = port;
  OTSpan *span = [self startSpanNamed:name.length ? name : method kind:OTSpanKindClient parent:parent ?: [OTSpan currentSpan].context
                           attributes:attributes];
  if (span.recording || span.context.sampled) [request ot_setTraceContext:span.context];
  return span;
}

@end

@implementation OTSpan (OTHTTP)

- (void)endWithResponse:(NSURLResponse *)response error:(NSError *)error
{
  NSHTTPURLResponse *http = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
  if (http) [self setAttribute:@(http.statusCode) forKey:@"http.response.status_code"];
  if (error) {
    [self setAttribute:error.domain forKey:@"error.type"];
    [self recordError:error];
  } else if (!http) {
    [self setAttribute:@"no_response" forKey:@"error.type"];
    [self setStatus:OTStatusError message:nil];
  } else if (http.statusCode >= 400) {
    // A client's span is an error for any refusal: it did not get what it asked.
    [self setAttribute:[NSString stringWithFormat:@"%ld", (long)http.statusCode] forKey:@"error.type"];
    [self setStatus:OTStatusError message:nil];
  }
  [self end];
}

@end
