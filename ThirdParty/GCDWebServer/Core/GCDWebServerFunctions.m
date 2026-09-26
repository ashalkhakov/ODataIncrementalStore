/*
 Copyright (c) 2012-2019, Pierre-Olivier Latour
 All rights reserved.
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
 * Redistributions of source code must retain the above copyright
 notice, this list of conditions and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright
 notice, this list of conditions and the following disclaimer in the
 documentation and/or other materials provided with the distribution.
 * The name of Pierre-Olivier Latour may not be used to endorse
 or promote products derived from this software without specific
 prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL PIERRE-OLIVIER LATOUR BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#if !__has_feature(objc_arc)
#error GCDWebServer requires ARC
#endif

#if defined(__APPLE__)
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <MobileCoreServices/MobileCoreServices.h>
#else
#import <SystemConfiguration/SystemConfiguration.h>
#endif
#endif

#import <ifaddrs.h>
#import <net/if.h>
#import <netdb.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/types.h>

#import "GCDWebServerPrivate.h"

#if __GCDWEBSERVER_ENABLE_DIGEST_AUTH__
#import <CommonCrypto/CommonDigest.h>
#endif

static NSDateFormatter* _dateFormatterRFC822 = nil;
static NSDateFormatter* _dateFormatterISO8601 = nil;
static dispatch_queue_t _dateFormatterQueue = NULL;

// TODO: Handle RFC 850 and ANSI C's asctime() format
void GCDWebServerInitializeFunctions() {
  GWS_DCHECK([NSThread isMainThread]);  // NSDateFormatter should be initialized on main thread
  if (_dateFormatterRFC822 == nil) {
    _dateFormatterRFC822 = [[NSDateFormatter alloc] init];
    _dateFormatterRFC822.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    _dateFormatterRFC822.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
    _dateFormatterRFC822.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    GWS_DCHECK(_dateFormatterRFC822);
  }
  if (_dateFormatterISO8601 == nil) {
    _dateFormatterISO8601 = [[NSDateFormatter alloc] init];
    _dateFormatterISO8601.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
    _dateFormatterISO8601.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'+00:00'";
    _dateFormatterISO8601.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US"];
    GWS_DCHECK(_dateFormatterISO8601);
  }
  if (_dateFormatterQueue == NULL) {
    _dateFormatterQueue = dispatch_queue_create(NULL, DISPATCH_QUEUE_SERIAL);
    GWS_DCHECK(_dateFormatterQueue);
  }
}

NSString* GCDWebServerNormalizeHeaderValue(NSString* value) {
  if (value) {
    NSRange range = [value rangeOfString:@";"];  // Assume part before ";" separator is case-insensitive
    if (range.location != NSNotFound) {
      value = [[[value substringToIndex:range.location] lowercaseString] stringByAppendingString:[value substringFromIndex:range.location]];
    } else {
      value = [value lowercaseString];
    }
  }
  return value;
}

NSString* GCDWebServerTruncateHeaderValue(NSString* value) {
  if (value) {
    NSRange range = [value rangeOfString:@";"];
    if (range.location != NSNotFound) {
      return [value substringToIndex:range.location];
    }
  }
  return value;
}

NSString* GCDWebServerExtractHeaderValueParameter(NSString* value, NSString* name) {
  NSString* parameter = nil;
  if (value) {
    NSScanner* scanner = [[NSScanner alloc] initWithString:value];
    [scanner setCaseSensitive:NO];  // Assume parameter names are case-insensitive
    NSString* string = [NSString stringWithFormat:@"%@=", name];
    if ([scanner scanUpToString:string intoString:NULL]) {
      [scanner scanString:string intoString:NULL];
      if ([scanner scanString:@"\"" intoString:NULL]) {
        [scanner scanUpToString:@"\"" intoString:&parameter];
      } else {
        [scanner scanUpToCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:&parameter];
      }
    }
  }
  return parameter;
}

// http://www.w3schools.com/tags/ref_charactersets.asp
NSStringEncoding GCDWebServerStringEncodingFromCharset(NSString* charset) {
#if defined(__APPLE__)
  NSStringEncoding encoding = kCFStringEncodingInvalidId;
  if (charset) {
    encoding = CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding((CFStringRef)charset));
  }
  return (encoding != kCFStringEncodingInvalidId ? encoding : NSUTF8StringEncoding);
#else
  // ODataStore port: no CFStringConvertIANACharSetNameToEncoding(); the common IANA names, UTF-8 otherwise
  static NSDictionary<NSString*, NSNumber*>* encodings = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    encodings = @{
      @"utf-8" : @(NSUTF8StringEncoding),
      @"utf8" : @(NSUTF8StringEncoding),
      @"us-ascii" : @(NSASCIIStringEncoding),
      @"ascii" : @(NSASCIIStringEncoding),
      @"iso-8859-1" : @(NSISOLatin1StringEncoding),
      @"iso_8859-1" : @(NSISOLatin1StringEncoding),
      @"latin1" : @(NSISOLatin1StringEncoding),
      @"iso-8859-2" : @(NSISOLatin2StringEncoding),
      @"windows-1250" : @(NSWindowsCP1250StringEncoding),
      @"windows-1251" : @(NSWindowsCP1251StringEncoding),
      @"windows-1252" : @(NSWindowsCP1252StringEncoding),
      @"utf-16" : @(NSUTF16StringEncoding),
      @"utf-16be" : @(NSUTF16BigEndianStringEncoding),
      @"utf-16le" : @(NSUTF16LittleEndianStringEncoding),
      @"utf-32" : @(NSUTF32StringEncoding),
      @"shift_jis" : @(NSShiftJISStringEncoding),
      @"euc-jp" : @(NSJapaneseEUCStringEncoding),
    };
  });
  NSNumber* encoding = charset ? [encodings objectForKey:[charset lowercaseString]] : nil;
  return encoding ? [encoding unsignedIntegerValue] : NSUTF8StringEncoding;
#endif
}

NSString* GCDWebServerFormatRFC822(NSDate* date) {
  __block NSString* string;
  dispatch_sync(_dateFormatterQueue, ^{
    string = [_dateFormatterRFC822 stringFromDate:date];
  });
  return string;
}

NSDate* GCDWebServerParseRFC822(NSString* string) {
  __block NSDate* date;
  dispatch_sync(_dateFormatterQueue, ^{
    date = [_dateFormatterRFC822 dateFromString:string];
  });
  return date;
}

NSString* GCDWebServerFormatISO8601(NSDate* date) {
  __block NSString* string;
  dispatch_sync(_dateFormatterQueue, ^{
    string = [_dateFormatterISO8601 stringFromDate:date];
  });
  return string;
}

NSDate* GCDWebServerParseISO8601(NSString* string) {
  __block NSDate* date;
  dispatch_sync(_dateFormatterQueue, ^{
    date = [_dateFormatterISO8601 dateFromString:string];
  });
  return date;
}

BOOL GCDWebServerIsTextContentType(NSString* type) {
  return ([type hasPrefix:@"text/"] || [type hasPrefix:@"application/json"] || [type hasPrefix:@"application/xml"]);
}

NSString* GCDWebServerDescribeData(NSData* data, NSString* type) {
  if (GCDWebServerIsTextContentType(type)) {
    NSString* charset = GCDWebServerExtractHeaderValueParameter(type, @"charset");
    NSString* string = [[NSString alloc] initWithData:data encoding:GCDWebServerStringEncodingFromCharset(charset)];
    if (string) {
      return string;
    }
  }
  return [NSString stringWithFormat:@"<%lu bytes>", (unsigned long)data.length];
}

NSString* GCDWebServerGetMimeTypeForExtension(NSString* extension, NSDictionary<NSString*, NSString*>* overrides) {
  NSDictionary* builtInOverrides = @{@"css" : @"text/css"};
  NSString* mimeType = nil;
  extension = [extension lowercaseString];
  if (extension.length) {
    mimeType = [overrides objectForKey:extension];
    if (mimeType == nil) {
      mimeType = [builtInOverrides objectForKey:extension];
    }
    if (mimeType == nil) {
#if defined(__APPLE__)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
      CFStringRef uti = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)extension, NULL);
      if (uti) {
        mimeType = CFBridgingRelease(UTTypeCopyPreferredTagWithClass(uti, kUTTagClassMIMEType));
        CFRelease(uti);
      }
#pragma clang diagnostic pop
#else
      // ODataStore port: no UTType; a small built-in table (unknown extensions get the default type)
      static NSDictionary<NSString*, NSString*>* types = nil;
      static dispatch_once_t onceToken;
      dispatch_once(&onceToken, ^{
        types = @{
          @"json" : @"application/json",
          @"xml" : @"application/xml",
          @"txt" : @"text/plain",
          @"text" : @"text/plain",
          @"htm" : @"text/html",
          @"html" : @"text/html",
          @"css" : @"text/css",
          @"js" : @"text/javascript",
          @"mjs" : @"text/javascript",
          @"csv" : @"text/csv",
          @"png" : @"image/png",
          @"jpg" : @"image/jpeg",
          @"jpeg" : @"image/jpeg",
          @"gif" : @"image/gif",
          @"svg" : @"image/svg+xml",
          @"ico" : @"image/vnd.microsoft.icon",
          @"pdf" : @"application/pdf",
          @"zip" : @"application/zip",
          @"bin" : @"application/octet-stream",
        };
      });
      mimeType = [types objectForKey:extension];
#endif
    }
  }
  return mimeType ? mimeType : kGCDWebServerDefaultMimeType;
}

// ODataStore port: Foundation in place of CFURLCreateStringByAddingPercentEscapes(string, NULL, ":@/?&=+", UTF-8),
// which kept exactly these ASCII characters and escaped everything else as UTF-8
NSString* GCDWebServerEscapeURLString(NSString* string) {
  static NSCharacterSet* allowed = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!$'()*,-.;_~"];
  });
  return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static inline int _HexValue(unsigned char c) {
  if ((c >= '0') && (c <= '9')) return c - '0';
  if ((c >= 'a') && (c <= 'f')) return c - 'a' + 10;
  if ((c >= 'A') && (c <= 'F')) return c - 'A' + 10;
  return -1;
}

// ODataStore port: in place of CFURLCreateStringByReplacingPercentEscapesUsingEncoding(string, "", UTF-8):
// every escape is decoded, and a malformed escape or a result that is not UTF-8 gives nil
// (-stringByRemovingPercentEncoding is not strict about this on GNUstep)
NSString* GCDWebServerUnescapeURLString(NSString* string) {
  NSData* data = [string dataUsingEncoding:NSUTF8StringEncoding];
  if (data == nil) {
    return nil;
  }
  const unsigned char* bytes = data.bytes;
  NSUInteger length = data.length;
  if (memchr(bytes, '%', length) == NULL) {
    return [string copy];
  }
  NSMutableData* decoded = [[NSMutableData alloc] initWithCapacity:length];
  for (NSUInteger i = 0; i < length; ++i) {
    unsigned char c = bytes[i];
    if (c == '%') {
      int hi = (i + 2 < length) ? _HexValue(bytes[i + 1]) : -1;
      int lo = (i + 2 < length) ? _HexValue(bytes[i + 2]) : -1;
      if ((hi < 0) || (lo < 0)) {
        return nil;
      }
      c = (unsigned char)((hi << 4) | lo);
      i += 2;
    }
    [decoded appendBytes:&c length:1];
  }
  return [[NSString alloc] initWithData:decoded encoding:NSUTF8StringEncoding];
}

// ODataStore port: CFURLCopyPath() / CFURLCopyQueryString(url, NULL) on the URL's own (relative) string, so
// escapes are kept, a trailing slash survives, and ";params" stay in the path (GNUstep's -[NSURL path] strips them)
static void _SplitURLString(NSString* urlString, NSRange* pathRange, NSRange* queryRange) {
  NSUInteger length = urlString.length;
  NSUInteger end = [urlString rangeOfString:@"#"].location;
  if (end == NSNotFound) {
    end = length;
  }
  NSUInteger queryStart = [urlString rangeOfString:@"?" options:0 range:NSMakeRange(0, end)].location;
  NSUInteger pathEnd = (queryStart != NSNotFound) ? queryStart : end;
  NSUInteger pathStart = 0;
  // Skip "scheme:"
  NSUInteger colon = [urlString rangeOfString:@":" options:0 range:NSMakeRange(0, pathEnd)].location;
  if (colon != NSNotFound) {
    NSUInteger slash = [urlString rangeOfString:@"/" options:0 range:NSMakeRange(0, pathEnd)].location;
    if ((slash == NSNotFound) || (colon < slash)) {
      pathStart = colon + 1;
    }
  }
  // Skip "//authority"
  if ((pathStart + 2 <= pathEnd) && [[urlString substringWithRange:NSMakeRange(pathStart, 2)] isEqualToString:@"//"]) {
    NSUInteger slash = [urlString rangeOfString:@"/" options:0 range:NSMakeRange(pathStart + 2, pathEnd - pathStart - 2)].location;
    pathStart = (slash != NSNotFound) ? slash : pathEnd;
  }
  *pathRange = NSMakeRange(pathStart, pathEnd - pathStart);
  *queryRange = (queryStart != NSNotFound) ? NSMakeRange(queryStart + 1, end - queryStart - 1) : NSMakeRange(NSNotFound, 0);
}

NSString* GCDWebServerCopyURLPath(NSURL* url) {
  NSString* string = [url relativeString];
  if (string == nil) {
    return nil;
  }
  NSRange pathRange, queryRange;
  _SplitURLString(string, &pathRange, &queryRange);
  return pathRange.length ? [string substringWithRange:pathRange] : nil;  // CFURLCopyPath() returns NULL for an empty path
}

NSString* GCDWebServerCopyURLQueryString(NSURL* url) {
  NSString* string = [url relativeString];
  if (string == nil) {
    return nil;
  }
  NSRange pathRange, queryRange;
  _SplitURLString(string, &pathRange, &queryRange);
  return (queryRange.location != NSNotFound) ? [string substringWithRange:queryRange] : nil;
}

NSDictionary<NSString*, NSString*>* GCDWebServerParseURLEncodedForm(NSString* form) {
  NSMutableDictionary* parameters = [NSMutableDictionary dictionary];
  NSScanner* scanner = [[NSScanner alloc] initWithString:form];
  [scanner setCharactersToBeSkipped:nil];
  while (1) {
    NSString* key = nil;
    if (![scanner scanUpToString:@"=" intoString:&key] || [scanner isAtEnd]) {
      break;
    }
    [scanner setScanLocation:([scanner scanLocation] + 1)];

    NSString* value = nil;
    [scanner scanUpToString:@"&" intoString:&value];
    if (value == nil) {
      value = @"";
    }

    key = [key stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    NSString* unescapedKey = key ? GCDWebServerUnescapeURLString(key) : nil;
    value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    NSString* unescapedValue = value ? GCDWebServerUnescapeURLString(value) : nil;
    if (unescapedKey && unescapedValue) {
      [parameters setObject:unescapedValue forKey:unescapedKey];
    } else {
      GWS_LOG_WARNING(@"Failed parsing URL encoded form for key \"%@\" and value \"%@\"", key, value);
      GWS_DNOT_REACHED();
    }

    if ([scanner isAtEnd]) {
      break;
    }
    [scanner setScanLocation:([scanner scanLocation] + 1)];
  }
  return parameters;
}

NSString* GCDWebServerStringFromSockAddr(const struct sockaddr* addr, BOOL includeService) {
  char hostBuffer[NI_MAXHOST];
  char serviceBuffer[NI_MAXSERV];
#if defined(__APPLE__)
  socklen_t addrLength = addr->sa_len;
#else
  socklen_t addrLength = (addr->sa_family == AF_INET6) ? sizeof(struct sockaddr_in6) : sizeof(struct sockaddr_in);  // ODataStore port: no sa_len
#endif
  if (getnameinfo(addr, addrLength, hostBuffer, sizeof(hostBuffer), serviceBuffer, sizeof(serviceBuffer), NI_NUMERICHOST | NI_NUMERICSERV | NI_NOFQDN) != 0) {
#if DEBUG
    GWS_DNOT_REACHED();
#else
    return @"";
#endif
  }
  return includeService ? [NSString stringWithFormat:@"%s:%s", hostBuffer, serviceBuffer] : (NSString*)[NSString stringWithUTF8String:hostBuffer];
}

NSString* GCDWebServerGetPrimaryIPAddress(BOOL useIPv6) {
  NSString* address = nil;
#if TARGET_OS_IPHONE
#if !TARGET_IPHONE_SIMULATOR && !TARGET_OS_TV
  const char* primaryInterface = "en0";  // WiFi interface on iOS
#endif
#elif defined(__APPLE__)
  const char* primaryInterface = NULL;
  SCDynamicStoreRef store = SCDynamicStoreCreate(kCFAllocatorDefault, CFSTR("GCDWebServer"), NULL, NULL);
  if (store) {
    CFPropertyListRef info = SCDynamicStoreCopyValue(store, CFSTR("State:/Network/Global/IPv4"));  // There is no equivalent for IPv6 but the primary interface should be the same
    if (info) {
      NSString* interface = [(__bridge NSDictionary*)info objectForKey:@"PrimaryInterface"];
      if (interface) {
        primaryInterface = [[NSString stringWithString:interface] UTF8String];  // Copy string to auto-release pool
      }
      CFRelease(info);
    }
    CFRelease(store);
  }
  if (primaryInterface == NULL) {
    primaryInterface = "lo0";
  }
#endif  // ODataStore port: without SystemConfiguration, take the first interface that is up and not loopback
  struct ifaddrs* list;
  if (getifaddrs(&list) >= 0) {
    for (struct ifaddrs* ifap = list; ifap; ifap = ifap->ifa_next) {
#if TARGET_IPHONE_SIMULATOR || TARGET_OS_TV
      // Assume en0 is Ethernet and en1 is WiFi since there is no way to use SystemConfiguration framework in iOS Simulator
      // Assumption holds for Apple TV running tvOS
      if (strcmp(ifap->ifa_name, "en0") && strcmp(ifap->ifa_name, "en1"))
#elif !defined(__APPLE__)
      if ((ifap->ifa_addr == NULL) || (ifap->ifa_flags & IFF_LOOPBACK))
#else
      if (strcmp(ifap->ifa_name, primaryInterface))
#endif
      {
        continue;
      }
      if ((ifap->ifa_flags & IFF_UP) && ((!useIPv6 && (ifap->ifa_addr->sa_family == AF_INET)) || (useIPv6 && (ifap->ifa_addr->sa_family == AF_INET6)))) {
        address = GCDWebServerStringFromSockAddr(ifap->ifa_addr, NO);
        break;
      }
    }
    freeifaddrs(list);
  }
  return address;
}

#if __GCDWEBSERVER_ENABLE_DIGEST_AUTH__

NSString* GCDWebServerComputeMD5Digest(NSString* format, ...) {
  va_list arguments;
  va_start(arguments, format);
  const char* string = [[[NSString alloc] initWithFormat:format arguments:arguments] UTF8String];
  va_end(arguments);
  unsigned char md5[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CC_MD5(string, (CC_LONG)strlen(string), md5);
#pragma clang diagnostic pop
  char buffer[2 * CC_MD5_DIGEST_LENGTH + 1];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; ++i) {
    unsigned char byte = md5[i];
    unsigned char byteHi = (byte & 0xF0) >> 4;
    buffer[2 * i + 0] = byteHi >= 10 ? 'a' + byteHi - 10 : '0' + byteHi;
    unsigned char byteLo = byte & 0x0F;
    buffer[2 * i + 1] = byteLo >= 10 ? 'a' + byteLo - 10 : '0' + byteLo;
  }
  buffer[2 * CC_MD5_DIGEST_LENGTH] = 0;
  return (NSString*)[NSString stringWithUTF8String:buffer];
}

#endif

NSString* GCDWebServerNormalizePath(NSString* path) {
  NSMutableArray* components = [[NSMutableArray alloc] init];
  for (NSString* component in [path componentsSeparatedByString:@"/"]) {
    if ([component isEqualToString:@".."]) {
      [components removeLastObject];
    } else if (component.length && ![component isEqualToString:@"."]) {
      [components addObject:component];
    }
  }
  if (path.length && ([path characterAtIndex:0] == '/')) {
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];  // Preserve initial slash
  }
  return [components componentsJoinedByString:@"/"];
}
