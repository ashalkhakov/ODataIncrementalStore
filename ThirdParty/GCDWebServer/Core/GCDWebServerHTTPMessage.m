/*
 GCDWebServerHTTPMessage: a replacement for the parts of CFHTTPMessage that
 GCDWebServer used. Written for the ODataStore port of GCDWebServer 3.5.4
 and distributed under the same license as GCDWebServer (see LICENSE).

 Request heads follow RFC 9112: a request line "method SP request-target SP
 HTTP-version", header fields "name: value", CRLF line endings, an empty line
 at the end. The parser is strict where leniency invites request smuggling:
 bare CR or LF, obs-fold continuation lines, whitespace before the colon,
 control characters in values, conflicting Content-Length values and
 Content-Length together with Transfer-Encoding are all rejected with 400.
 */

#if !__has_feature(objc_arc)
#error GCDWebServer requires ARC
#endif

#import <ctype.h>
#import <string.h>

#import "GCDWebServerHTTPMessage.h"

#pragma mark - Header dictionary

@implementation GCDWebServerHeaderDictionary {
  NSArray<NSString*>* _names;  // Wire spelling, first-seen order
  NSDictionary<NSString*, NSString*>* _values;  // Lowercased name -> value
}

- (instancetype)initWithNames:(NSArray<NSString*>*)names valuesByLowercaseName:(NSDictionary<NSString*, NSString*>*)values {
  if ((self = [super init])) {
    _names = [names copy];
    _values = [values copy];
  }
  return self;
}

- (instancetype)init {
  return [self initWithNames:@[] valuesByLowercaseName:@{}];
}

// NSDictionary primitive initializer, so -initWithDictionary: and friends work
- (instancetype)initWithObjects:(const id _Nonnull[])objects forKeys:(const id<NSCopying> _Nonnull[])keys count:(NSUInteger)count {
  NSMutableArray* names = [NSMutableArray arrayWithCapacity:count];
  NSMutableDictionary* values = [NSMutableDictionary dictionaryWithCapacity:count];
  for (NSUInteger i = 0; i < count; ++i) {
    NSString* name = [(id)keys[i] description];
    NSString* lowercaseName = [name lowercaseString];
    if ([values objectForKey:lowercaseName] == nil) {
      [names addObject:name];
    }
    [values setObject:objects[i] forKey:lowercaseName];
  }
  return [self initWithNames:names valuesByLowercaseName:values];
}

- (NSUInteger)count {
  return _names.count;
}

- (id)objectForKey:(id)key {
  if (![key isKindOfClass:[NSString class]]) {
    return nil;
  }
  return [_values objectForKey:[(NSString*)key lowercaseString]];
}

- (NSEnumerator*)keyEnumerator {
  return [_names objectEnumerator];
}

// gnustep-base leaves fast enumeration to NSDictionary's subclasses
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState*)state objects:(id __unsafe_unretained _Nullable[])buffer count:(NSUInteger)len {
  return [_names countByEnumeratingWithState:state objects:buffer count:len];
}

- (id)copyWithZone:(NSZone*)zone {
  return self;
}

@end

#pragma mark - Character classes

// tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*" / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
static inline BOOL _IsTokenChar(unsigned char c) {
  if (((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9'))) {
    return YES;
  }
  return (strchr("!#$%&'*+-.^_`|~", c) != NULL) && (c != 0);
}

static inline BOOL _IsHexDigit(unsigned char c) {
  return ((c >= '0') && (c <= '9')) || ((c >= 'a') && (c <= 'f')) || ((c >= 'A') && (c <= 'F'));
}

// Characters kept as-is in a request URL: RFC 3986 unreserved, sub-delims, ":", "@", "/", "?" and "#"
static inline BOOL _IsURLChar(unsigned char c) {
  if (((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z')) || ((c >= '0') && (c <= '9'))) {
    return YES;
  }
  return (strchr("-._~!$&'()*+,;=:@/?#", c) != NULL) && (c != 0);
}

static NSString* _DecodeFieldBytes(const unsigned char* bytes, NSUInteger length) {
  NSString* string = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
  if (string == nil) {
    string = [[NSString alloc] initWithBytes:bytes length:length encoding:NSISOLatin1StringEncoding];
  }
  return string;
}

#pragma mark - Message

@implementation GCDWebServerHTTPMessage {
  // Header fields, in first-seen order, case-insensitive
  NSMutableArray<NSString*>* _headerNames;
  NSMutableDictionary<NSString*, NSString*>* _headerValues;  // Lowercased name -> value

  // Request parsing state
  NSMutableData* _headData;
  NSMutableData* _body;
  NSUInteger _scanOffset;
  NSString* _escapedTarget;
}

- (instancetype)_initAsRequest:(BOOL)isRequest statusCode:(NSInteger)statusCode {
  if ((self = [super init])) {
    _request = isRequest;
    _statusCode = statusCode;
    _headerNames = [[NSMutableArray alloc] init];
    _headerValues = [[NSMutableDictionary alloc] init];
    _maxHeadSize = kGCDWebServerHTTPMessageDefaultMaxHeadSize;
    if (isRequest) {
      _headData = [[NSMutableData alloc] init];
      _body = [[NSMutableData alloc] init];
    }
  }
  return self;
}

- (instancetype)init {
  return [self initRequest];
}

- (instancetype)initRequest {
  return [self _initAsRequest:YES statusCode:0];
}

- (instancetype)initResponseWithStatusCode:(NSInteger)statusCode {
  return [self _initAsRequest:NO statusCode:statusCode];
}

#pragma mark Header fields

- (NSDictionary<NSString*, NSString*>*)allHeaderFields {
  return [[GCDWebServerHeaderDictionary alloc] initWithNames:_headerNames valuesByLowercaseName:_headerValues];
}

- (NSString*)valueForHeaderField:(NSString*)name {
  return [_headerValues objectForKey:[name lowercaseString]];
}

- (void)setValue:(NSString*)value forHeaderField:(NSString*)name {
  NSString* lowercaseName = [name lowercaseString];
  NSUInteger index = NSNotFound;
  if ([_headerValues objectForKey:lowercaseName]) {
    index = [_headerNames indexOfObjectPassingTest:^BOOL(NSString* existing, NSUInteger idx, BOOL* stop) {
      return [[existing lowercaseString] isEqualToString:lowercaseName];
    }];
  }
  if (value == nil) {
    if (index != NSNotFound) {
      [_headerNames removeObjectAtIndex:index];
      [_headerValues removeObjectForKey:lowercaseName];
    }
    return;
  }
  if (index != NSNotFound) {
    [_headerNames replaceObjectAtIndex:index withObject:[name copy]];
  } else {
    [_headerNames addObject:[name copy]];
  }
  [_headerValues setObject:[value copy] forKey:lowercaseName];
}

// Repeated request fields combine into one comma-separated list (RFC 9110 5.3)
- (void)_addRequestHeaderField:(NSString*)name value:(NSString*)value {
  NSString* lowercaseName = [name lowercaseString];
  NSString* existing = [_headerValues objectForKey:lowercaseName];
  if (existing) {
    [_headerValues setObject:[NSString stringWithFormat:@"%@, %@", existing, value] forKey:lowercaseName];
  } else {
    [_headerNames addObject:name];
    [_headerValues setObject:value forKey:lowercaseName];
  }
}

#pragma mark Request parsing

- (NSData*)bodyData {
  return _body ? _body : [NSData data];
}

- (GCDWebServerHTTPMessageParseStatus)_failWithStatusCode:(NSInteger)statusCode description:(NSString*)description {
  _errorStatusCode = statusCode;
  _errorDescription = description;
  _headData = nil;
  return kGCDWebServerHTTPMessageParseStatus_Error;
}

- (GCDWebServerHTTPMessageParseStatus)appendBytes:(const void*)bytes length:(NSUInteger)length {
  if (!_request) {
    return [self _failWithStatusCode:500 description:@"Not a request"];
  }
  if (_errorStatusCode) {
    return kGCDWebServerHTTPMessageParseStatus_Error;
  }
  if (_headerComplete) {
    [_body appendBytes:bytes length:length];
    return kGCDWebServerHTTPMessageParseStatus_Complete;
  }
  [_headData appendBytes:bytes length:length];

  // Ignore empty lines before the request line (RFC 9112 2.2)
  const unsigned char* data = _headData.bytes;
  NSUInteger skip = 0;
  while ((_headData.length >= skip + 2) && (data[skip] == '\r') && (data[skip + 1] == '\n')) {
    skip += 2;
  }
  if (skip) {
    [_headData replaceBytesInRange:NSMakeRange(0, skip) withBytes:NULL length:0];
    _scanOffset = 0;
    data = _headData.bytes;
  }

  NSUInteger total = _headData.length;
  NSUInteger start = _scanOffset > 3 ? _scanOffset - 3 : 0;
  NSUInteger end = NSNotFound;
  for (NSUInteger i = start; i + 4 <= total; ++i) {
    if ((data[i] == '\r') && (data[i + 1] == '\n') && (data[i + 2] == '\r') && (data[i + 3] == '\n')) {
      end = i;
      break;
    }
  }
  if (end == NSNotFound) {
    if (total > _maxHeadSize) {
      return [self _failWithStatusCode:431 description:[NSString stringWithFormat:@"Request head exceeds %lu bytes", (unsigned long)_maxHeadSize]];
    }
    _scanOffset = total;
    return kGCDWebServerHTTPMessageParseStatus_Incomplete;
  }
  NSUInteger headLength = end + 4;
  if (headLength > _maxHeadSize) {
    return [self _failWithStatusCode:431 description:[NSString stringWithFormat:@"Request head exceeds %lu bytes", (unsigned long)_maxHeadSize]];
  }
  if (total > headLength) {
    [_body appendBytes:(data + headLength) length:(total - headLength)];
  }
  GCDWebServerHTTPMessageParseStatus status = [self _parseHead:data length:(end + 2)];  // Lines including the last CRLF
  _headData = nil;
  return status;
}

- (GCDWebServerHTTPMessageParseStatus)_parseHead:(const unsigned char*)data length:(NSUInteger)length {
  NSUInteger lineStart = 0;
  BOOL firstLine = YES;
  while (lineStart < length) {
    // Find the CRLF ending this line; reject bare CR or LF
    NSUInteger lineEnd = lineStart;
    while (1) {
      if (lineEnd + 1 >= length) {
        return [self _failWithStatusCode:400 description:@"Unterminated line in request head"];
      }
      unsigned char c = data[lineEnd];
      if (c == '\r') {
        if (data[lineEnd + 1] != '\n') {
          return [self _failWithStatusCode:400 description:@"Bare CR in request head"];
        }
        break;
      }
      if (c == '\n') {
        return [self _failWithStatusCode:400 description:@"Bare LF in request head"];
      }
      ++lineEnd;
    }
    const unsigned char* line = data + lineStart;
    NSUInteger lineLength = lineEnd - lineStart;
    GCDWebServerHTTPMessageParseStatus status = firstLine ? [self _parseRequestLine:line length:lineLength] : [self _parseHeaderLine:line length:lineLength];
    if (status == kGCDWebServerHTTPMessageParseStatus_Error) {
      return status;
    }
    firstLine = NO;
    lineStart = lineEnd + 2;
  }
  if (firstLine) {
    return [self _failWithStatusCode:400 description:@"Empty request head"];
  }
  return [self _finishRequestHead];
}

// request-line = method SP request-target SP HTTP-version
- (GCDWebServerHTTPMessageParseStatus)_parseRequestLine:(const unsigned char*)line length:(NSUInteger)length {
  NSUInteger i = 0;
  while ((i < length) && _IsTokenChar(line[i])) {
    ++i;
  }
  if ((i == 0) || (i >= length) || (line[i] != ' ')) {
    return [self _failWithStatusCode:400 description:@"Malformed request method"];
  }
  NSUInteger methodLength = i;
  NSUInteger targetStart = ++i;
  while ((i < length) && (line[i] > 0x20) && (line[i] != 0x7F)) {
    ++i;
  }
  if ((i == targetStart) || (i >= length) || (line[i] != ' ')) {
    return [self _failWithStatusCode:400 description:@"Malformed request target"];
  }
  NSUInteger targetLength = i - targetStart;
  const unsigned char* version = line + i + 1;
  NSUInteger versionLength = length - i - 1;
  if ((versionLength != 8) || (memcmp(version, "HTTP/", 5) != 0) || !isdigit(version[5]) || (version[6] != '.') || !isdigit(version[7])) {
    return [self _failWithStatusCode:400 description:@"Malformed HTTP version"];
  }
  if (version[5] != '1') {
    return [self _failWithStatusCode:505 description:@"Unsupported HTTP version"];
  }

  _requestMethod = [[NSString alloc] initWithBytes:line length:methodLength encoding:NSASCIIStringEncoding];
  _httpVersion = [[NSString alloc] initWithBytes:version length:versionLength encoding:NSASCIIStringEncoding];

  // Keep valid escapes and URL characters; escape everything else, as CFHTTPMessage did
  const unsigned char* target = line + targetStart;
  static const char hex[] = "0123456789ABCDEF";
  NSMutableData* escaped = [[NSMutableData alloc] initWithCapacity:targetLength];
  for (NSUInteger j = 0; j < targetLength; ++j) {
    unsigned char c = target[j];
    if (_IsURLChar(c) || ((c == '%') && (j + 2 < targetLength) && _IsHexDigit(target[j + 1]) && _IsHexDigit(target[j + 2]))) {
      [escaped appendBytes:&c length:1];
    } else {
      char buffer[3] = {'%', hex[c >> 4], hex[c & 0x0F]};
      [escaped appendBytes:buffer length:3];
    }
  }
  _requestTarget = _DecodeFieldBytes(target, targetLength);
  _escapedTarget = [[NSString alloc] initWithData:escaped encoding:NSASCIIStringEncoding];
  return kGCDWebServerHTTPMessageParseStatus_Incomplete;
}

// field-line = field-name ":" OWS field-value OWS
- (GCDWebServerHTTPMessageParseStatus)_parseHeaderLine:(const unsigned char*)line length:(NSUInteger)length {
  if ((length > 0) && ((line[0] == ' ') || (line[0] == '\t'))) {
    return [self _failWithStatusCode:400 description:@"Obsolete line folding in request head"];
  }
  NSUInteger i = 0;
  while ((i < length) && _IsTokenChar(line[i])) {
    ++i;
  }
  if ((i == 0) || (i >= length) || (line[i] != ':')) {
    return [self _failWithStatusCode:400 description:@"Malformed header field name"];
  }
  NSString* name = [[NSString alloc] initWithBytes:line length:i encoding:NSASCIIStringEncoding];
  NSUInteger valueStart = i + 1;
  NSUInteger valueEnd = length;
  while ((valueStart < valueEnd) && ((line[valueStart] == ' ') || (line[valueStart] == '\t'))) {
    ++valueStart;
  }
  while ((valueEnd > valueStart) && ((line[valueEnd - 1] == ' ') || (line[valueEnd - 1] == '\t'))) {
    --valueEnd;
  }
  for (NSUInteger j = valueStart; j < valueEnd; ++j) {
    unsigned char c = line[j];
    if (((c < 0x20) && (c != '\t')) || (c == 0x7F)) {
      return [self _failWithStatusCode:400 description:@"Control character in header field value"];
    }
  }
  NSString* value = _DecodeFieldBytes(line + valueStart, valueEnd - valueStart);
  if ((name == nil) || (value == nil)) {
    return [self _failWithStatusCode:400 description:@"Undecodable header field"];
  }
  [self _addRequestHeaderField:name value:value];
  return kGCDWebServerHTTPMessageParseStatus_Incomplete;
}

- (GCDWebServerHTTPMessageParseStatus)_finishRequestHead {
  // Content-Length: one decimal value, or a list of identical ones
  NSString* contentLength = [self valueForHeaderField:@"Content-Length"];
  if (contentLength) {
    NSString* single = nil;
    for (NSString* item in [contentLength componentsSeparatedByString:@","]) {
      NSString* trimmed = [item stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ((trimmed.length == 0) || (trimmed.length > 18) || ([trimmed rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound)) {
        return [self _failWithStatusCode:400 description:@"Invalid Content-Length"];
      }
      if (single && ![single isEqualToString:trimmed]) {
        return [self _failWithStatusCode:400 description:@"Conflicting Content-Length values"];
      }
      single = trimmed;
    }
    NSString* originalName = nil;
    for (NSString* name in _headerNames) {
      if ([name caseInsensitiveCompare:@"Content-Length"] == NSOrderedSame) {
        originalName = name;
        break;
      }
    }
    [self setValue:single forHeaderField:(originalName ? originalName : @"Content-Length")];
  }

  // Transfer-Encoding: only "chunked", never together with Content-Length
  NSString* transferEncoding = [self valueForHeaderField:@"Transfer-Encoding"];
  if (transferEncoding) {
    if (contentLength) {
      return [self _failWithStatusCode:400 description:@"Both Content-Length and Transfer-Encoding"];
    }
    NSString* normalized = [[transferEncoding stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] lowercaseString];
    if (![normalized isEqualToString:@"chunked"]) {
      return [self _failWithStatusCode:501 description:@"Unsupported Transfer-Encoding"];
    }
  }

  // Build the URL like CFHTTPMessageCopyRequestURL(): relative to http://<Host>/ for origin-form
  BOOL isAbsolute = NO;
  NSUInteger schemeEnd = [_escapedTarget rangeOfString:@":"].location;
  if ((schemeEnd != NSNotFound) && (schemeEnd > 0)) {
    isAbsolute = YES;
    for (NSUInteger k = 0; k < schemeEnd; ++k) {
      unichar c = [_escapedTarget characterAtIndex:k];
      BOOL alpha = ((c >= 'a') && (c <= 'z')) || ((c >= 'A') && (c <= 'Z'));
      if (!(alpha || ((k > 0) && (((c >= '0') && (c <= '9')) || (c == '+') || (c == '-') || (c == '.'))))) {
        isAbsolute = NO;
        break;
      }
    }
  }
  if (isAbsolute) {
    _requestURL = [NSURL URLWithString:_escapedTarget];
  } else {
    NSString* host = [self valueForHeaderField:@"Host"];
    NSURL* baseURL = host.length ? [NSURL URLWithString:[NSString stringWithFormat:@"http://%@/", host]] : nil;
    if (baseURL == nil) {
      baseURL = [NSURL URLWithString:@"fake://host/"];
    }
    _requestURL = [NSURL URLWithString:_escapedTarget relativeToURL:baseURL];
  }
  if (_requestURL == nil) {
    return [self _failWithStatusCode:400 description:@"Invalid request target"];
  }

  _headerComplete = YES;
  return kGCDWebServerHTTPMessageParseStatus_Complete;
}

#pragma mark Response serialisation

+ (NSString*)reasonPhraseForStatusCode:(NSInteger)statusCode {
  switch (statusCode) {
    case 100: return @"Continue";
    case 101: return @"Switching Protocols";
    case 102: return @"Processing";
    case 103: return @"Early Hints";
    case 200: return @"OK";
    case 201: return @"Created";
    case 202: return @"Accepted";
    case 203: return @"Non-Authoritative Information";
    case 204: return @"No Content";
    case 205: return @"Reset Content";
    case 206: return @"Partial Content";
    case 207: return @"Multi-Status";
    case 208: return @"Already Reported";
    case 226: return @"IM Used";
    case 300: return @"Multiple Choices";
    case 301: return @"Moved Permanently";
    case 302: return @"Found";
    case 303: return @"See Other";
    case 304: return @"Not Modified";
    case 305: return @"Use Proxy";
    case 307: return @"Temporary Redirect";
    case 308: return @"Permanent Redirect";
    case 400: return @"Bad Request";
    case 401: return @"Unauthorized";
    case 402: return @"Payment Required";
    case 403: return @"Forbidden";
    case 404: return @"Not Found";
    case 405: return @"Method Not Allowed";
    case 406: return @"Not Acceptable";
    case 407: return @"Proxy Authentication Required";
    case 408: return @"Request Timeout";
    case 409: return @"Conflict";
    case 410: return @"Gone";
    case 411: return @"Length Required";
    case 412: return @"Precondition Failed";
    case 413: return @"Content Too Large";
    case 414: return @"URI Too Long";
    case 415: return @"Unsupported Media Type";
    case 416: return @"Range Not Satisfiable";
    case 417: return @"Expectation Failed";
    case 421: return @"Misdirected Request";
    case 422: return @"Unprocessable Content";
    case 423: return @"Locked";
    case 424: return @"Failed Dependency";
    case 425: return @"Too Early";
    case 426: return @"Upgrade Required";
    case 428: return @"Precondition Required";
    case 429: return @"Too Many Requests";
    case 431: return @"Request Header Fields Too Large";
    case 451: return @"Unavailable For Legal Reasons";
    case 500: return @"Internal Server Error";
    case 501: return @"Not Implemented";
    case 502: return @"Bad Gateway";
    case 503: return @"Service Unavailable";
    case 504: return @"Gateway Timeout";
    case 505: return @"HTTP Version Not Supported";
    case 506: return @"Variant Also Negotiates";
    case 507: return @"Insufficient Storage";
    case 508: return @"Loop Detected";
    case 511: return @"Network Authentication Required";
    default: break;
  }
  // Unknown codes get their class's generic phrase, as CFHTTPMessage did
  switch (statusCode / 100) {
    case 1: return @"Continue";
    case 2: return @"OK";
    case 3: return @"Multiple Choices";
    case 4: return @"Bad Request";
    case 5: return @"Internal Server Error";
    default: return @"Unknown";
  }
}

static NSString* _SanitizeFieldValue(NSString* value) {
  if ([value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n"]].location == NSNotFound) {
    return value;
  }
  // Never let a value start a new header line (response splitting)
  return [[value stringByReplacingOccurrencesOfString:@"\r" withString:@" "] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
}

- (NSData*)serializedHead {
  NSMutableString* head = [[NSMutableString alloc] init];
  if (_request) {
    [head appendFormat:@"%@ %@ %@\r\n", _requestMethod, _requestTarget, _httpVersion ? _httpVersion : @"HTTP/1.1"];
  } else {
    [head appendFormat:@"HTTP/1.1 %ld %@\r\n", (long)_statusCode, [[self class] reasonPhraseForStatusCode:_statusCode]];
  }
  for (NSString* name in _headerNames) {
    NSString* value = [_headerValues objectForKey:[name lowercaseString]];
    [head appendFormat:@"%@: %@\r\n", name, _SanitizeFieldValue(value)];
  }
  [head appendString:@"\r\n"];
  return (NSData*)[head dataUsingEncoding:NSUTF8StringEncoding];
}

@end
