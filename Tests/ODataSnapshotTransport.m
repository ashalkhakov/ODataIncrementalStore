// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSnapshotTransport.h"
#import "ODataError.h"

static NSString *OISUnescape(NSString *s)
{
  if (!s) return @"";
  s = [s stringByReplacingOccurrencesOfString:@"+" withString:@" "];
#ifdef __APPLE__
  return [s stringByRemovingPercentEncoding] ?: s;
#else
  NSString *u = [s stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
  return u ?: s;
#endif
}

static NSDictionary *OISQueryDictionary(NSURL *url)
{
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  NSString *query = url.query;
  if (!query.length) return out;
  for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
    NSRange eq = [pair rangeOfString:@"="];
    if (eq.location == NSNotFound) {
      out[OISUnescape(pair)] = @"";
      continue;
    }
    NSString *name = OISUnescape([pair substringToIndex:eq.location]);
    NSString *value = OISUnescape([pair substringFromIndex:eq.location + 1]);
    if (name.length) out[name] = value;
  }
  return out;
}

static NSString *OISRelativePath(NSURL *url, NSURL *root)
{
  NSString *full = url.path ?: @"";
  NSString *base = root.path ?: @"";
  if (base.length && ![base hasSuffix:@"/"]) base = [base stringByAppendingString:@"/"];
  if (base.length && [full hasPrefix:base]) {
    full = [full substringFromIndex:base.length];
  } else if ([full hasPrefix:@"/"]) {
    full = [full substringFromIndex:1];
  }
  while ([full hasPrefix:@"/"]) full = [full substringFromIndex:1];
  if ([full hasSuffix:@"/"] && full.length > 1) full = [full substringToIndex:full.length - 1];
  return full;
}

static BOOL OISJSONEqual(id a, id b)
{
  if (a == b) return YES;
  if (!a || !b) return NO;
  NSData *da = [NSJSONSerialization dataWithJSONObject:a options:0 error:nil];
  NSData *db = [NSJSONSerialization dataWithJSONObject:b options:0 error:nil];
  if (!da || !db) return [a isEqual:b];
  id ra = [NSJSONSerialization JSONObjectWithData:da options:0 error:nil];
  id rb = [NSJSONSerialization JSONObjectWithData:db options:0 error:nil];
  return [ra isEqual:rb];
}

@implementation ODataSnapshotTransport {
  NSArray *_snapshots;
  NSMutableArray *_hits;
  NSMutableArray *_refusals;
}

- (instancetype)initWithDirectory:(NSString *)directory serviceRoot:(NSURL *)serviceRoot error:(NSError **)error
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [serviceRoot copy];
  _hits = [NSMutableArray array];
  _refusals = [NSMutableArray array];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSArray *names = [fm contentsOfDirectoryAtPath:directory error:error];
  if (!names) return nil;
  NSMutableArray *loaded = [NSMutableArray array];
  NSMutableArray *labels = [NSMutableArray array];
  names = [names sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    if (![name hasSuffix:@".json"] || [name isEqualToString:@"index.json"]) continue;
    NSString *path = [directory stringByAppendingPathComponent:name];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) continue;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    if (![json isKindOfClass:[NSDictionary class]]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorDecoding, [NSString stringWithFormat:@"Snapshot %@ is not an object", name]);
      return nil;
    }
    NSMutableDictionary *entry = [json mutableCopy];
    entry[@"_file"] = name;
    [loaded addObject:entry];
    [labels addObject:[name stringByDeletingPathExtension]];
  }
  _snapshots = [loaded copy];
  _snapshotNames = [labels copy];
  return self;
}

- (NSArray *)refusals
{
  return [_refusals copy];
}

- (NSDictionary *)snapshotNamed:(NSString *)name
{
  for (NSDictionary *s in _snapshots) {
    if ([s[@"_file"] isEqualToString:[name stringByAppendingString:@".json"]] ||
        [[s[@"_file"] stringByDeletingPathExtension] isEqualToString:name]) {
      return s;
    }
  }
  return nil;
}

- (BOOL)matches:(NSDictionary *)snapshot request:(NSURLRequest *)request
{
  NSDictionary *want = snapshot[@"request"];
  if (![want isKindOfClass:[NSDictionary class]]) return NO;
  NSString *method = want[@"method"] ?: @"GET";
  if (![method isEqualToString:request.HTTPMethod]) return NO;
  NSString *wantPath = want[@"path"] ?: @"";
  while ([wantPath hasPrefix:@"/"]) wantPath = [wantPath substringFromIndex:1];
  NSString *gotPath = OISRelativePath(request.URL, self.serviceRoot);
  if (![wantPath isEqualToString:gotPath]) return NO;
  NSDictionary *wantQuery = want[@"query"];
  if ([wantQuery isKindOfClass:[NSDictionary class]]) {
    NSDictionary *gotQuery = OISQueryDictionary(request.URL);
    if (wantQuery.count != gotQuery.count) return NO;
    for (NSString *key in wantQuery) {
      if (![gotQuery[key] isEqual:wantQuery[key]]) return NO;
    }
  } else if (OISQueryDictionary(request.URL).count) {
    return NO;
  }
  id wantBody = want[@"body"];
  if (wantBody) {
    if (!request.HTTPBody.length) return NO;
    id gotBody = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:0 error:nil];
    if (!OISJSONEqual(wantBody, gotBody)) return NO;
  }
  NSDictionary *wantHeaders = want[@"headers"];
  if ([wantHeaders isKindOfClass:[NSDictionary class]]) {
    for (NSString *key in wantHeaders) {
      NSString *got = [request valueForHTTPHeaderField:key];
      if (![got isEqual:wantHeaders[key]]) return NO;
    }
  }
  return YES;
}

// A snapshot's media type: its Content-Type header, or what its body is.
static NSString *OISSnapshotMediaType(NSDictionary *resp)
{
  NSString *type = resp[@"headers"][@"Content-Type"];
  if (!type) {
    if (resp[@"bodyXML"]) type = @"application/xml";
    else if ([resp[@"body"] isKindOfClass:[NSString class]]) type = @"text/plain";
    else if (resp[@"body"]) type = @"application/json";
  }
  return [[[type componentsSeparatedByString:@";"] firstObject]
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
}

// Whether an Accept header admits a media type: type/subtype, type/* or */*.
// Parameters and q-values are ignored, as they are by the services the
// client talks to.
static BOOL OISAccepts(NSString *accept, NSString *type)
{
  if (!accept.length) return YES;
  NSString *major = [[type componentsSeparatedByString:@"/"] firstObject];
  for (NSString *range in [accept componentsSeparatedByString:@","]) {
    NSString *r = [[[range componentsSeparatedByString:@";"] firstObject]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
    if ([r isEqualToString:@"*/*"] || [r isEqualToString:type]) return YES;
    if ([r isEqualToString:[major stringByAppendingString:@"/*"]]) return YES;
  }
  return NO;
}

// What a real service checks before it looks at the resource: the
// version headers, a Content-Type for a body, and an Accept it can meet.
// A mismatch is an OData error response, as a service would send, rather
// than a missing snapshot.
- (nullable NSString *)refusalOfRequest:(NSURLRequest *)request snapshot:(NSDictionary *)snapshot status:(NSInteger *)status
{
  if (![request valueForHTTPHeaderField:@"OData-MaxVersion"]) {
    *status = 400;
    return @"OData-MaxVersion is required (Part 1 section 13.3)";
  }
  if (request.HTTPBody.length) {
    NSString *ct = [request valueForHTTPHeaderField:@"Content-Type"];
    if (![ct.lowercaseString hasPrefix:@"application/json"]) {
      *status = 415;
      return [NSString stringWithFormat:@"Request body Content-Type %@ is not JSON", ct ?: @"(none)"];
    }
    if (![request valueForHTTPHeaderField:@"OData-Version"]) {
      *status = 400;
      return @"OData-Version is required with a payload (Part 1 section 13.3)";
    }
  }
  NSString *type = OISSnapshotMediaType(snapshot[@"response"] ?: @{});
  NSString *accept = [request valueForHTTPHeaderField:@"Accept"];
  if (type.length && !OISAccepts(accept, type)) {
    *status = 406;
    return [NSString stringWithFormat:@"Accept %@ does not admit %@", accept, type];
  }
  return nil;
}

- (NSData *)sendRequest:(NSURLRequest *)request returningResponse:(NSURLResponse **)response error:(NSError **)error
{
  NSDictionary *hit = nil;
  for (NSDictionary *snapshot in _snapshots) {
    if ([self matches:snapshot request:request]) {
      hit = snapshot;
      break;
    }
  }
  if (!hit) {
    NSMutableArray *bits = [NSMutableArray array];
    [bits addObject:request.HTTPMethod ?: @"?"];
    [bits addObject:request.URL.absoluteString ?: @"?"];
    NSString *ifMatch = [request valueForHTTPHeaderField:@"If-Match"];
    if (ifMatch.length) [bits addObject:[NSString stringWithFormat:@"If-Match=%@", ifMatch]];
    if (request.HTTPBody.length) {
      NSString *body = [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding];
      if (body.length) [bits addObject:body];
    }
    NSString *msg = [NSString stringWithFormat:@"No snapshot for %@", [bits componentsJoinedByString:@" "]];
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, msg);
    return nil;
  }
  NSInteger refusedStatus = 0;
  NSString *refusal = [self refusalOfRequest:request snapshot:hit status:&refusedStatus];
  if (refusal) {
    [_refusals addObject:refusal];
    if (response) {
      *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                              statusCode:refusedStatus
                                             HTTPVersion:@"HTTP/1.1"
                                            headerFields:@{ @"Content-Type": @"application/json" }];
    }
    NSDictionary *body = @{ @"error": @{ @"code": @"", @"message": refusal } };
    return [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
  }
  [_hits addObject:hit[@"_file"]];
  NSDictionary *resp = hit[@"response"] ?: @{};
  NSInteger status = [resp[@"status"] integerValue] ?: 200;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  if ([resp[@"headers"] isKindOfClass:[NSDictionary class]]) {
    [headers addEntriesFromDictionary:resp[@"headers"]];
  }
  NSData *body = [NSData data];
  if ([resp[@"bodyXML"] isKindOfClass:[NSString class]]) {
    body = [resp[@"bodyXML"] dataUsingEncoding:NSUTF8StringEncoding];
  } else if ([resp[@"body"] isKindOfClass:[NSString class]]) {
    body = [resp[@"body"] dataUsingEncoding:NSUTF8StringEncoding];
  } else if (resp[@"body"]) {
    body = [NSJSONSerialization dataWithJSONObject:resp[@"body"] options:0 error:nil] ?: [NSData data];
  }
  if (response) {
    *response = [[NSHTTPURLResponse alloc] initWithURL:request.URL
                                            statusCode:status
                                           HTTPVersion:@"HTTP/1.1"
                                          headerFields:headers];
  }
  return body;
}

@end
