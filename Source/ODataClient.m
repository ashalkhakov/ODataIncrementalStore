// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Synchronous transport. NSIncrementalStore callbacks are synchronous.
// Off Apple we use NSURLConnection (no libdispatch required). On Apple,
// NSURLSession + NSCondition (Condition lives in Foundation, unlike
// dispatch_semaphore).

#import "ODataClient.h"
#import "ODataError.h"

@implementation ODataHTTPResponse
- (NSString *)etag
{
  return [self valueForHeader:@"ETag"];
}

- (NSString *)valueForHeader:(NSString *)name
{
  for (NSString *key in self.headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return self.headers[key];
  }
  return nil;
}
@end

@implementation ODataClient

- (instancetype)initWithConfiguration:(ODataConfiguration *)configuration
{
  self = [super init];
  if (!self) return nil;
  _configuration = configuration;
  return self;
}

- (ODataHTTPResponse *)sendRequest:(NSURLRequest *)request error:(NSError **)error
{
  NSMutableURLRequest *req = [request mutableCopy];
  [self.configuration applyToRequest:req];

  NSURLResponse *urlResponse = nil;
  NSError *wire = nil;
  NSData *data = nil;

  if (self.transport) {
    data = [self.transport sendRequest:req returningResponse:&urlResponse error:&wire];
  } else {
#if !defined(__APPLE__) && !defined(OIS_USE_NSURLSESSION)
    data = [NSURLConnection sendSynchronousRequest:req returningResponse:&urlResponse error:&wire];
#else
    data = [self ois_sessionSend:req response:&urlResponse error:&wire];
#endif
  }

  if (wire) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, wire.localizedDescription);
    return nil;
  }
  NSHTTPURLResponse *http = (NSHTTPURLResponse *)urlResponse;
  if (![http isKindOfClass:[NSHTTPURLResponse class]]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, @"No HTTP response");
    return nil;
  }
  NSData *body = data ?: [NSData data];
  if (http.statusCode >= 400) {
    ODataIncrementalStoreErrorCode code = http.statusCode == 412
        ? ODataIncrementalStoreErrorOptimisticLocking
        : (ODataIncrementalStoreErrorCode)(ODataIncrementalStoreErrorHTTP + http.statusCode);
    if (error) *error = OISHTTPError(code, http.statusCode, http.URL ?: req.URL, body);
    return nil;
  }
  ODataHTTPResponse *out = [[ODataHTTPResponse alloc] init];
  out.status = http.statusCode;
  out.data = body;
  out.headers = http.allHeaderFields ?: @{};
  out.URL = http.URL;
  return out;
}

#if defined(__APPLE__) || defined(OIS_USE_NSURLSESSION)
- (NSData *)ois_sessionSend:(NSURLRequest *)request
                   response:(NSURLResponse **)outResponse
                      error:(NSError **)error
{
  __block NSData *data = nil;
  __block NSURLResponse *resp = nil;
  __block NSError *err = nil;
  NSCondition *lock = [[NSCondition alloc] init];
  __block BOOL done = NO;
  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
          [lock lock];
          data = d;
          resp = r;
          err = e;
          done = YES;
          [lock signal];
          [lock unlock];
        }];
  [task resume];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:self.configuration.timeout + 5.0];
  [lock lock];
  while (!done) {
    if (![lock waitUntilDate:deadline]) break;
  }
  BOOL finished = done;
  [lock unlock];
  if (!finished) {
    [task cancel];
    if (error) *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
    return nil;
  }
  if (outResponse) *outResponse = resp;
  if (error) *error = err;
  return data;
}
#endif

- (id)JSONAtURL:(NSURL *)url error:(NSError **)error
{
  return [self JSONAtURL:url headers:nil error:error];
}

- (id)JSONAtURL:(NSURL *)url headers:(NSDictionary *)headers error:(NSError **)error
{
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  for (NSString *name in headers) [req setValue:headers[name] forHTTPHeaderField:name];
  ODataHTTPResponse *response = [self sendRequest:req error:error];
  if (!response) return nil;
  if (response.status == 204) return [NSNull null];
  return [NSJSONSerialization JSONObjectWithData:response.data options:0 error:error];
}

- (NSString *)textAtURL:(NSURL *)url error:(NSError **)error
{
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  [req setValue:@"text/plain" forHTTPHeaderField:@"Accept"];
  ODataHTTPResponse *response = [self sendRequest:req error:error];
  if (!response) return nil;
  return [[NSString alloc] initWithData:response.data encoding:NSUTF8StringEncoding] ?: @"";
}

- (ODataHTTPResponse *)sendJSONMethod:(NSString *)method
                                  URL:(NSURL *)url
                                 body:(id)body
                                 etag:(NSString *)etag
                                error:(NSError **)error
{
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = method;
  if (body) {
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
    if (!req.HTTPBody) return nil;
  }
  if (etag) [req setValue:etag forHTTPHeaderField:@"If-Match"];
  // The entity back in the response, with its new key and ETag, saves a
  // GET (Part 1 section 8.2.8.7). Not for $ref, which has no entity.
  BOOL entity = ([method isEqualToString:@"POST"] || [method isEqualToString:@"PATCH"]) &&
                ![url.path hasSuffix:@"/$ref"];
  if (entity) [req setValue:@"return=representation" forHTTPHeaderField:@"Prefer"];
  return [self sendRequest:req error:error];
}

- (NSData *)metadataWithError:(NSError **)error
{
  NSURL *url = [self.configuration.serviceRoot URLByAppendingPathComponent:@"$metadata"];
  NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
  req.HTTPMethod = @"GET";
  [req setValue:@"application/xml" forHTTPHeaderField:@"Accept"];
  return [self sendRequest:req error:error].data;
}

@end
