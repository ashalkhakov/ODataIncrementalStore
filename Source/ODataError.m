// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataError.h"

NSErrorDomain const ODataIncrementalStoreErrorDomain = @"org.gnu.ois.ODataIncrementalStore";

NSString * const ODataErrorHTTPStatusKey = @"ODataErrorHTTPStatus";
NSString * const ODataErrorCodeKey = @"ODataErrorCode";
NSString * const ODataErrorTargetKey = @"ODataErrorTarget";
NSString * const ODataErrorDetailsKey = @"ODataErrorDetails";
NSString * const ODataErrorResponseBodyKey = @"ODataErrorResponseBody";

static NSString *OISString(id value)
{
  return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

// The text of the first <m:NAME> (or <NAME>) element, for the XML error a
// service sends when XML was asked for, as $metadata is.
static NSString *OISXMLElement(NSString *xml, NSString *name)
{
  for (NSString *open in @[ [NSString stringWithFormat:@"<m:%@>", name], [NSString stringWithFormat:@"<%@>", name] ]) {
    NSRange start = [xml rangeOfString:open];
    if (start.location == NSNotFound) continue;
    NSUInteger from = NSMaxRange(start);
    NSRange end = [xml rangeOfString:@"</" options:0 range:NSMakeRange(from, xml.length - from)];
    if (end.location != NSNotFound) return OISString([xml substringWithRange:NSMakeRange(from, end.location - from)]);
  }
  return nil;
}

NSError *OISHTTPError(ODataIncrementalStoreErrorCode code, NSInteger status, NSURL *url, NSData *body)
{
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[ODataErrorHTTPStatusKey] = @(status);
  if (url) info[NSURLErrorFailingURLErrorKey] = url;
  NSString *text = body.length ? [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] : nil;
  if (text) info[ODataErrorResponseBodyKey] = text;

  NSString *message = nil;
  id json = body.length ? [NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] : nil;
  NSDictionary *error = [json isKindOfClass:[NSDictionary class]] ? json[@"error"] : nil;
  if ([error isKindOfClass:[NSDictionary class]]) {
    message = OISString(error[@"message"]);
    if (OISString(error[@"code"])) info[ODataErrorCodeKey] = error[@"code"];
    if (OISString(error[@"target"])) info[ODataErrorTargetKey] = error[@"target"];
    NSMutableArray *details = [NSMutableArray array];
    for (NSDictionary *detail in ([error[@"details"] isKindOfClass:[NSArray class]] ? error[@"details"] : @[])) {
      if (![detail isKindOfClass:[NSDictionary class]]) continue;
      NSMutableDictionary *d = [NSMutableDictionary dictionary];
      for (NSString *key in @[ @"code", @"message", @"target" ]) {
        if (OISString(detail[key])) d[key] = detail[key];
      }
      if (d.count) [details addObject:d];
    }
    if (details.count) info[ODataErrorDetailsKey] = details;
  } else if (text && [text rangeOfString:@"error"].location != NSNotFound && [text hasPrefix:@"<"]) {
    message = OISXMLElement(text, @"message");
    if (OISXMLElement(text, @"code")) info[ODataErrorCodeKey] = OISXMLElement(text, @"code");
  }
  if (!message) {
    message = text.length && text.length <= 300 && ![text hasPrefix:@"<"]
        ? text : [NSHTTPURLResponse localizedStringForStatusCode:status];
  }
  info[NSLocalizedDescriptionKey] = message;
  info[NSLocalizedFailureReasonErrorKey] = [NSString stringWithFormat:@"HTTP %ld at %@", (long)status, url.absoluteString ?: @"?"];
  return [NSError errorWithDomain:ODataIncrementalStoreErrorDomain code:code userInfo:info];
}

NSError *OISError(ODataIncrementalStoreErrorCode code, NSString *message)
{
  return [NSError errorWithDomain:ODataIncrementalStoreErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}
