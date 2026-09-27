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

NSData *ODataChangeSetBody(NSArray<NSURLRequest *> *requests, NSString *batchBoundary)
{
  NSString *changeSet = [@"changeset_" stringByAppendingString:[[NSUUID UUID] UUIDString]];
  // Per part only what describes that request; authorisation and the
  // like belong to the batch request that carries them all.
  NSSet *skip = [NSSet setWithObjects:@"authorization", @"user-agent", @"content-length", @"host", nil];
  NSMutableData *out = [NSMutableData data];
  OISAppend(out, [NSString stringWithFormat:@"--%@\r\nContent-Type: multipart/mixed; boundary=%@\r\n\r\n", batchBoundary, changeSet]);
  NSUInteger contentID = 1;
  for (NSURLRequest *request in requests) {
    OISAppend(out, [NSString stringWithFormat:@"--%@\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: %lu\r\n\r\n",
                                              changeSet, (unsigned long)contentID++]);
    OISAppend(out, [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\n", request.HTTPMethod ?: @"GET", request.URL.absoluteString]);
    NSDictionary *headers = request.allHTTPHeaderFields;
    for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      if ([skip containsObject:name.lowercaseString]) continue;
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
