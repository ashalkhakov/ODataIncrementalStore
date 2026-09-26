// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Synchronous transport. NSIncrementalStore callbacks are synchronous.
// NSURLSession, waited on with an NSCondition, wherever Foundation has it:
// Apple, and gnustep-base built with libcurl. gnustep-base's
// NSURLConnection is the fallback, and only that: it does not follow a
// relative redirect (NSURLProtocol resolves Location without the request
// URL, and the request times out), and it returns an empty body for a
// multipart response, which every $batch answer is (GSMimeParser keeps
// the parts, not the bytes).

#import "ODataClient.h"
#import "ODataError.h"
#import "ODataBatch.h"

#if defined(__APPLE__) || (defined(GS_HAVE_NSURLSESSION) && GS_HAVE_NSURLSESSION)
#define OIS_HAVE_NSURLSESSION 1
#else
#define OIS_HAVE_NSURLSESSION 0
#endif

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
#if OIS_HAVE_NSURLSESSION
    if (NSClassFromString(@"NSURLSession")) {
      data = [self ois_sessionSend:req response:&urlResponse error:&wire];
    } else
#endif
    {
#if defined(__APPLE__)
      if (error) *error = OISError(ODataIncrementalStoreErrorTransport, @"NSURLSession is unavailable");
      return nil;
#else
      data = [NSURLConnection sendSynchronousRequest:req returningResponse:&urlResponse error:&wire];
#endif
    }
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

#if OIS_HAVE_NSURLSESSION
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
  NSMutableURLRequest *req = [self requestWithMethod:method URL:url body:body etag:etag error:error];
  return req ? [self sendRequest:req error:error] : nil;
}

- (NSArray *)sendChangeSet:(NSArray *)requests error:(NSError **)error
{
  NSString *boundary = [@"batch_" stringByAppendingString:[[NSUUID UUID] UUIDString]];
  NSURL *url = [self.configuration.serviceRoot URLByAppendingPathComponent:@"$batch"];
  NSMutableURLRequest *batch = [NSMutableURLRequest requestWithURL:url];
  batch.HTTPMethod = @"POST";
  batch.HTTPBody = ODataChangeSetBody(requests, boundary);
  [batch setValue:[@"multipart/mixed; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];
  [batch setValue:@"multipart/mixed" forHTTPHeaderField:@"Accept"];
  ODataHTTPResponse *response = [self sendRequest:batch error:error];
  if (!response) return nil;

  NSString *responseBoundary = ODataMultipartBoundary([response valueForHeader:@"Content-Type"] ?: @"");
  NSArray *parts = responseBoundary ? ODataBatchParts(response.data, responseBoundary) : nil;
  if (!parts) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, @"The $batch response is not a multipart body");
    return nil;
  }
  // A change set that failed is answered with one response: the failure
  // (section 11.7.7.5).
  for (ODataBatchPart *part in parts) {
    if (part.status < 400) continue;
    NSUInteger index = part.contentID ? (NSUInteger)(part.contentID.integerValue - 1) : 0;
    NSURL *failed = index < requests.count ? [requests[index] URL] : url;
    ODataIncrementalStoreErrorCode code = part.status == 412
        ? ODataIncrementalStoreErrorOptimisticLocking
        : (ODataIncrementalStoreErrorCode)(ODataIncrementalStoreErrorHTTP + part.status);
    if (error) *error = OISHTTPError(code, part.status, failed, part.body);
    return nil;
  }
  if (parts.count != requests.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorDecoding,
                                 [NSString stringWithFormat:@"$batch answered %lu of %lu requests", (unsigned long)parts.count, (unsigned long)requests.count]);
    return nil;
  }
  NSMutableArray *responses = [NSMutableArray array];
  for (NSUInteger i = 0; i < parts.count; i++) {
    ODataBatchPart *part = parts[i];
    ODataHTTPResponse *one = [[ODataHTTPResponse alloc] init];
    one.status = part.status;
    one.data = part.body;
    one.headers = part.headers;
    one.URL = [requests[i] URL];
    [responses addObject:one];
  }
  return responses;
}

- (NSMutableURLRequest *)requestWithMethod:(NSString *)method
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
  [self.configuration applyToRequest:req];
  return req;
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
