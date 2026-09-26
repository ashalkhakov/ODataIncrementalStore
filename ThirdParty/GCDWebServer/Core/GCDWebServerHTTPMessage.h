/*
 GCDWebServerHTTPMessage: a replacement for the parts of CFHTTPMessage that
 GCDWebServer used, so the server builds on platforms without CFNetwork
 (GNUstep on Linux). Written for the ODataStore port of GCDWebServer 3.5.4
 and distributed under the same license as GCDWebServer (see LICENSE).

 This is a private header: it is not part of the GCDWebServer public API.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 *  Default limit on the size of a request head (request line, header fields
 *  and the terminating empty line). Heads over this size are rejected with
 *  431 Request Header Fields Too Large.
 */
#define kGCDWebServerHTTPMessageDefaultMaxHeadSize (64 * 1024)

typedef NS_ENUM(NSInteger, GCDWebServerHTTPMessageParseStatus) {
  kGCDWebServerHTTPMessageParseStatus_Incomplete = 0,  // Need more bytes
  kGCDWebServerHTTPMessageParseStatus_Complete,  // Head parsed; see -bodyData for bytes past the head
  kGCDWebServerHTTPMessageParseStatus_Error  // See -errorStatusCode
};

/**
 *  Case-insensitive, name-preserving dictionary of header fields: keys keep
 *  the spelling received on the wire, and -objectForKey: matches any case
 *  ("content-type", "Content-Type"). Immutable.
 */
@interface GCDWebServerHeaderDictionary : NSDictionary<NSString*, NSString*>
@end

/**
 *  An HTTP/1.x message head.
 *
 *  Requests are parsed incrementally: create one with -initRequest, feed it
 *  the bytes read from the socket with -appendBytes:length: until it returns
 *  Complete or Error. Responses are created with -initResponseWithStatusCode:,
 *  given header fields with -setValue:forHeaderField:, and serialised with
 *  -serializedHead.
 */
@interface GCDWebServerHTTPMessage : NSObject

- (instancetype)initRequest;
- (instancetype)initResponseWithStatusCode:(NSInteger)statusCode;

@property(nonatomic, readonly, getter=isRequest) BOOL request;

/* --- Request parsing --- */

/**
 *  Heads larger than this are rejected with 431 (default 64 KiB).
 */
@property(nonatomic) NSUInteger maxHeadSize;

/**
 *  Appends bytes read from the connection. Once the head is complete, bytes
 *  past it are accumulated in -bodyData instead.
 */
- (GCDWebServerHTTPMessageParseStatus)appendBytes:(const void*)bytes length:(NSUInteger)length;

@property(nonatomic, readonly, getter=isHeaderComplete) BOOL headerComplete;

/**
 *  The HTTP status code to answer with after a parse error: 400 (malformed
 *  request line or header field, obs-fold, bad Content-Length, both
 *  Content-Length and Transfer-Encoding), 431 (head too large), 501
 *  (Transfer-Encoding other than chunked) or 505 (HTTP major version not 1).
 *  0 if there was no error.
 */
@property(nonatomic, readonly) NSInteger errorStatusCode;
@property(nonatomic, readonly, nullable) NSString* errorDescription;

@property(nonatomic, readonly, nullable) NSString* requestMethod;
@property(nonatomic, readonly, nullable) NSString* requestTarget;  // As received on the wire
@property(nonatomic, readonly, nullable) NSString* httpVersion;  // e.g. "HTTP/1.1"

/**
 *  The request URL, built the way CFHTTPMessageCopyRequestURL() did: for an
 *  origin-form target ("/path?query") a URL relative to "http://<Host>/"
 *  (or "fake://host/" without a Host header); an absolute-form target is
 *  returned as is. Characters not allowed in a URL are percent-escaped, and
 *  existing escapes are left untouched.
 */
@property(nonatomic, readonly, nullable) NSURL* requestURL;

/**
 *  Bytes received after the end of the head.
 */
@property(nonatomic, readonly) NSData* bodyData;

/* --- Header fields (requests and responses) --- */

/**
 *  All header fields, as a GCDWebServerHeaderDictionary. Repeated fields in a
 *  request are combined into one comma-separated value, in order.
 */
- (NSDictionary<NSString*, NSString*>*)allHeaderFields;
- (nullable NSString*)valueForHeaderField:(NSString*)name;

/**
 *  Sets (or with nil, removes) a header field. Names are matched
 *  case-insensitively; the latest spelling is kept.
 */
- (void)setValue:(nullable NSString*)value forHeaderField:(NSString*)name;

/* --- Response serialisation --- */

@property(nonatomic, readonly) NSInteger statusCode;

/**
 *  "HTTP/1.1 <code> <reason>\r\n", the header fields and the empty line.
 */
- (NSData*)serializedHead;

+ (NSString*)reasonPhraseForStatusCode:(NSInteger)statusCode;

@end

NS_ASSUME_NONNULL_END
