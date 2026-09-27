// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataBatch.h"

@implementation ODataBatchPart
- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _headers = @{};
  _body = [NSData data];
  return self;
}

- (NSString *)valueForHeader:(NSString *)name
{
  for (NSString *key in self.headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return self.headers[key];
  }
  return nil;
}
@end

#pragma mark - Writing

static void OISAppend(NSMutableData *data, NSString *text)
{
  [data appendData:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

// Headers a request of a batch carries: what describes it, not what the
// batch request carries for them all.
static BOOL OISBatchCarriesHeader(NSString *name)
{
  NSSet *skip = [NSSet setWithObjects:@"authorization", @"user-agent", @"content-length", @"host", nil];
  return ![skip containsObject:name.lowercaseString];
}

NSData *ODataChangeSetBody(NSArray<NSURLRequest *> *requests, NSString *batchBoundary)
{
  NSString *changeSet = [@"changeset_" stringByAppendingString:[[NSUUID UUID] UUIDString]];
  NSMutableData *out = [NSMutableData data];
  OISAppend(out, [NSString stringWithFormat:@"--%@\r\nContent-Type: multipart/mixed; boundary=%@\r\n\r\n", batchBoundary, changeSet]);
  NSUInteger contentID = 1;
  for (NSURLRequest *request in requests) {
    OISAppend(out, [NSString stringWithFormat:@"--%@\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: %lu\r\n\r\n",
                                              changeSet, (unsigned long)contentID++]);
    OISAppend(out, [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\n", request.HTTPMethod ?: @"GET", request.URL.absoluteString]);
    NSDictionary *headers = request.allHTTPHeaderFields;
    for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if (!OISBatchCarriesHeader(name)) continue;
      OISAppend(out, [NSString stringWithFormat:@"%@: %@\r\n", name, headers[name]]);
    }
    OISAppend(out, @"\r\n");
    if (request.HTTPBody.length) [out appendData:request.HTTPBody];
    OISAppend(out, @"\r\n");
  }
  OISAppend(out, [NSString stringWithFormat:@"--%@--\r\n--%@--\r\n", changeSet, batchBoundary]);
  return out;
}

#pragma mark - Reading

NSString *ODataMultipartBoundary(NSString *contentType)
{
  for (NSString *parameter in [contentType componentsSeparatedByString:@";"]) {
    NSString *p = [parameter stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([p.lowercaseString hasPrefix:@"boundary="]) {
      NSString *value = [p substringFromIndex:9];
      if (value.length >= 2 && [value hasPrefix:@"\""] && [value hasSuffix:@"\""]) {
        value = [value substringWithRange:NSMakeRange(1, value.length - 2)];
      }
      return value.length ? value : nil;
    }
  }
  return nil;
}

static NSRange OISFind(NSData *data, NSString *text, NSUInteger from)
{
  if (from >= data.length) return NSMakeRange(NSNotFound, 0);
  return [data rangeOfData:[text dataUsingEncoding:NSUTF8StringEncoding]
                   options:0
                     range:NSMakeRange(from, data.length - from)];
}

// Header lines and what follows the blank line after them. CRLF or LF.
static BOOL OISSplitHeaders(NSData *data, NSArray **lines, NSData **body)
{
  NSRange blank = OISFind(data, @"\r\n\r\n", 0);
  NSUInteger skip = 4;
  NSRange lf = OISFind(data, @"\n\n", 0);
  if (blank.location == NSNotFound || (lf.location != NSNotFound && lf.location < blank.location)) {
    blank = lf;
    skip = 2;
  }
  NSData *head = blank.location == NSNotFound ? data : [data subdataWithRange:NSMakeRange(0, blank.location)];
  NSString *text = [[NSString alloc] initWithData:head encoding:NSUTF8StringEncoding];
  if (!text) return NO;
  text = [text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
  *lines = [text componentsSeparatedByString:@"\n"];
  NSUInteger start = blank.location == NSNotFound ? data.length : blank.location + skip;
  *body = [data subdataWithRange:NSMakeRange(start, data.length - start)];
  return YES;
}

static NSDictionary *OISHeaderDictionary(NSArray *lines)
{
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSString *line in lines) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    NSString *name = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (name.length) headers[name] = value;
  }
  return headers;
}

static NSString *OISHeader(NSDictionary *headers, NSString *name)
{
  for (NSString *key in headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
  }
  return nil;
}

// An application/http part: a request line or a status line, headers,
// and a body.
static ODataBatchPart *OISHTTPMessage(NSData *data, NSString *contentID)
{
  NSArray *lines = nil;
  NSData *body = nil;
  if (!OISSplitHeaders(data, &lines, &body) || !lines.count) return nil;
  ODataBatchPart *part = [[ODataBatchPart alloc] init];
  part.contentID = contentID;
  NSArray *first = [lines[0] componentsSeparatedByString:@" "];
  if ([lines[0] hasPrefix:@"HTTP/"]) {
    if (first.count < 2) return nil;
    part.status = [first[1] integerValue];
  } else {
    if (first.count < 2) return nil;
    part.method = first[0];
    part.URLString = first[1];
  }
  part.headers = OISHeaderDictionary([lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]);
  part.body = body;
  return part;
}

NSData *ODataJSONBatchBody(NSArray<NSURLRequest *> *requests)
{
  NSMutableArray *out = [NSMutableArray array];
  NSUInteger identifier = 1;
  for (NSURLRequest *request in requests) {
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    item[@"id"] = [NSString stringWithFormat:@"%lu", (unsigned long)identifier++];
    item[@"atomicityGroup"] = @"g1";
    item[@"method"] = request.HTTPMethod ?: @"GET";
    item[@"url"] = request.URL.absoluteString ?: @"";
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    for (NSString *name in request.allHTTPHeaderFields) {
      if (OISBatchCarriesHeader(name)) headers[name.lowercaseString] = request.allHTTPHeaderFields[name];
    }
    if (headers.count) item[@"headers"] = headers;
    if (request.HTTPBody.length) {
      id body = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:NSJSONReadingAllowFragments error:NULL];
      item[@"body"] = body ?: [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
    }
    [out addObject:item];
  }
  return [NSJSONSerialization dataWithJSONObject:@{ @"requests": out } options:0 error:NULL];
}

NSArray *ODataJSONBatchParts(NSData *body)
{
  id json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
  NSArray *responses = [json isKindOfClass:[NSDictionary class]] ? json[@"responses"] : nil;
  if (![responses isKindOfClass:[NSArray class]]) return nil;
  NSMutableArray *parts = [NSMutableArray array];
  for (NSDictionary *response in responses) {
    if (![response isKindOfClass:[NSDictionary class]]) return nil;
    ODataBatchPart *part = [[ODataBatchPart alloc] init];
    part.status = [response[@"status"] integerValue];
    id identifier = response[@"id"];
    part.contentID = [identifier isKindOfClass:[NSString class]] ? identifier : [identifier description];
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];
    NSDictionary *given = [response[@"headers"] isKindOfClass:[NSDictionary class]] ? response[@"headers"] : @{};
    for (NSString *name in given) headers[name] = [given[name] description];
    id content = response[@"body"];
    NSData *data = [NSData data];
    if ([content isKindOfClass:[NSString class]] && ![(OISHeader(headers, @"Content-Type") ?: @"").lowercaseString hasPrefix:@"application/json"]) {
      data = [content dataUsingEncoding:NSUTF8StringEncoding];
    } else if (content && content != [NSNull null]) {
      // A fragment is written inside an array, and the brackets cut off.
      NSData *wrapped = [NSJSONSerialization dataWithJSONObject:@[ content ] options:0 error:NULL];
      data = wrapped.length > 2 ? [wrapped subdataWithRange:NSMakeRange(1, wrapped.length - 2)] : [NSData data];
      if (!OISHeader(headers, @"Content-Type")) headers[@"Content-Type"] = @"application/json";
    }
    part.headers = headers;
    part.body = data;
    [parts addObject:part];
  }
  return parts;
}

ODataBatchPart *ODataHTTPMessage(NSData *data)
{
  return data ? OISHTTPMessage(data, nil) : nil;
}

NSString *ODataHTTPReasonPhrase(NSInteger status)
{
  NSDictionary *phrases = @{ @200: @"OK", @201: @"Created", @202: @"Accepted", @204: @"No Content", @304: @"Not Modified",
                             @400: @"Bad Request", @401: @"Unauthorized", @403: @"Forbidden", @404: @"Not Found",
                             @405: @"Method Not Allowed", @406: @"Not Acceptable", @409: @"Conflict", @410: @"Gone",
                             @412: @"Precondition Failed", @415: @"Unsupported Media Type", @424: @"Failed Dependency",
                             @500: @"Internal Server Error", @501: @"Not Implemented", @504: @"Gateway Timeout" };
  return phrases[@(status)] ?: @"Status";
}

NSData *ODataHTTPResponseMessage(NSInteger status, NSDictionary *headers, NSData *body)
{
  NSMutableData *out = [NSMutableData data];
  OISAppend(out, [NSString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, ODataHTTPReasonPhrase(status)]);
  for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) continue;
    OISAppend(out, [NSString stringWithFormat:@"%@: %@\r\n", name, headers[name]]);
  }
  OISAppend(out, @"\r\n");
  if (body.length) [out appendData:body];
  return out;
}

NSArray *ODataBatchParts(NSData *body, NSString *boundary)
{
  NSString *delimiter = [@"--" stringByAppendingString:boundary];
  NSRange at = OISFind(body, delimiter, 0);
  if (at.location == NSNotFound) return nil;
  NSMutableArray *parts = [NSMutableArray array];
  while (YES) {
    NSUInteger after = NSMaxRange(at);
    if (after + 2 <= body.length && [[body subdataWithRange:NSMakeRange(after, 2)] isEqualToData:[@"--" dataUsingEncoding:NSUTF8StringEncoding]]) {
      break;  // the closing delimiter
    }
    NSRange eol = OISFind(body, @"\n", after);
    if (eol.location == NSNotFound) return nil;
    NSUInteger start = NSMaxRange(eol);
    // A part ends at the line break before the next delimiter.
    NSRange next = OISFind(body, [@"\n" stringByAppendingString:delimiter], start);
    if (next.location == NSNotFound) return nil;
    NSUInteger end = next.location;
    if (end > start) {
      unsigned char last;
      [body getBytes:&last range:NSMakeRange(end - 1, 1)];
      if (last == '\r') end--;
    }
    NSData *raw = [body subdataWithRange:NSMakeRange(start, end - start)];
    NSArray *lines = nil;
    NSData *content = nil;
    if (!OISSplitHeaders(raw, &lines, &content)) return nil;
    NSDictionary *mime = OISHeaderDictionary(lines);
    NSString *type = OISHeader(mime, @"Content-Type") ?: @"";
    if ([type.lowercaseString hasPrefix:@"multipart/mixed"]) {
      NSString *inner = ODataMultipartBoundary(type);
      NSArray *members = inner ? ODataBatchParts(content, inner) : nil;
      if (!members) return nil;
      for (ODataBatchPart *member in members) {
        if (!member.changeSet) member.changeSet = inner;
      }
      [parts addObjectsFromArray:members];
    } else {
      ODataBatchPart *message = OISHTTPMessage(content, OISHeader(mime, @"Content-ID"));
      if (!message) return nil;
      [parts addObject:message];
    }
    at = NSMakeRange(next.location + 1, delimiter.length);
  }
  return parts;
}
