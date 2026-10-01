// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataError.h"

NSErrorDomain const ODataIncrementalStoreErrorDomain = @"org.gnu.ois.ODataIncrementalStore";

NSErrorDomain const ODataServiceErrorDomain = @"org.gnu.ois.ODataService";

NSString * const ODataErrorHTTPStatusKey = @"ODataErrorHTTPStatus";
NSString * const ODataErrorCodeKey = @"ODataErrorCode";
NSString * const ODataErrorTargetKey = @"ODataErrorTarget";
NSString * const ODataErrorDetailsKey = @"ODataErrorDetails";
NSString * const ODataErrorResponseBodyKey = @"ODataErrorResponseBody";
NSString * const ODataErrorScopesKey = @"ODataErrorScopes";

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

// A challenge's auth-params, by lowercased name: name="value" (\" escapes)
// or name=token, after the scheme.
static NSDictionary<NSString *, NSString *> *OISChallengeParameters(NSString *challenge)
{
  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
  NSScanner *scanner = [NSScanner scannerWithString:challenge];
  scanner.charactersToBeSkipped = nil;
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  NSCharacterSet *nameEnd = [NSCharacterSet characterSetWithCharactersInString:@"=, \t"];
  // The scheme, Bearer.
  [scanner scanUpToCharactersFromSet:space intoString:NULL];
  while (!scanner.isAtEnd) {
    [scanner scanCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@", \t"] intoString:NULL];
    NSString *name = nil;
    if (![scanner scanUpToCharactersFromSet:nameEnd intoString:&name]) break;
    [scanner scanCharactersFromSet:space intoString:NULL];
    if (![scanner scanString:@"=" intoString:NULL]) continue;
    [scanner scanCharactersFromSet:space intoString:NULL];
    NSMutableString *value = [NSMutableString string];
    if ([scanner scanString:@"\"" intoString:NULL]) {
      while (!scanner.isAtEnd) {
        NSString *run = nil;
        if ([scanner scanUpToCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\"\\"] intoString:&run]) [value appendString:run];
        if ([scanner scanString:@"\"" intoString:NULL]) break;
        if ([scanner scanString:@"\\" intoString:NULL] && !scanner.isAtEnd) {
          [value appendString:[challenge substringWithRange:NSMakeRange(scanner.scanLocation, 1)]];
          scanner.scanLocation += 1;
        }
      }
    } else {
      NSString *token = nil;
      if ([scanner scanUpToCharactersFromSet:[NSCharacterSet characterSetWithCharactersInString:@", \t"] intoString:&token]) [value appendString:token];
    }
    parameters[name.lowercaseString] = value;
  }
  return parameters;
}

NSError *OISHTTPErrorWithChallenge(NSError *error, NSString *challenge)
{
  NSInteger status = [error.userInfo[ODataErrorHTTPStatusKey] integerValue];
  if ((status != 401 && status != 403) || !challenge.length) return error;
  NSDictionary *parameters = OISChallengeParameters(challenge);
  NSMutableArray *scopes = [NSMutableArray array];
  for (NSString *scope in [parameters[@"scope"] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
    if (scope.length) [scopes addObject:scope];
  }
  BOOL insufficient = [parameters[@"error"] isEqualToString:@"insufficient_scope"];
  if (!scopes.count && !insufficient) return error;
  NSMutableDictionary *info = [error.userInfo mutableCopy];
  if (scopes.count) info[ODataErrorScopesKey] = scopes;
  if (insufficient) {
    info[NSLocalizedRecoverySuggestionErrorKey] = scopes.count
        ? [NSString stringWithFormat:@"The access token's scopes do not allow this: sign in again, asking the identity "
                                     @"provider for the scopes the service names (%@)", [scopes componentsJoinedByString:@", "]]
        : @"The access token's scopes do not allow this: sign in again, asking the identity provider for more";
  }
  return [NSError errorWithDomain:error.domain code:error.code userInfo:info];
}

NSError *OISError(ODataIncrementalStoreErrorCode code, NSString *message)
{
  return [NSError errorWithDomain:ODataIncrementalStoreErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}

NSError *ODataServiceErrorWithTarget(NSInteger status, NSString *message, NSString *target)
{
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  info[NSLocalizedDescriptionKey] = message ?: [NSHTTPURLResponse localizedStringForStatusCode:status];
  if (target) info[ODataErrorTargetKey] = target;
  return [NSError errorWithDomain:ODataServiceErrorDomain code:status userInfo:info];
}

NSError *ODataServiceError(NSInteger status, NSString *message)
{
  return ODataServiceErrorWithTarget(status, message, nil);
}
