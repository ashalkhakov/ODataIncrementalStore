/*
 gws-smoke: smoke test for the ported GCDWebServer.

 Starts a GCDWebServer on 127.0.0.1 with an automatic port, then talks to it
 over plain BSD sockets (no NSURLSession, so no dependency on libcurl) and
 checks the responses. Prints one line per check; exits 0 only if all pass.

 Build: see GNUmakefile in the parent directory.
 */

#import <Foundation/Foundation.h>

#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <signal.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>

#import <stdatomic.h>

#import "GCDWebServer.h"
#import "GCDWebServerConnection.h"
#import "GCDWebServerDataRequest.h"
#import "GCDWebServerDataResponse.h"
#import "GCDWebServerStreamedResponse.h"

static int _failures = 0;

static NSDate* _lastCheck = nil;

static void Check(BOOL ok, NSString* name, NSString* detail) {
  if (!ok) {
    _failures += 1;
  }
  NSTimeInterval elapsed = _lastCheck ? -[_lastCheck timeIntervalSinceNow] : 0.0;
  _lastCheck = [NSDate date];
  printf("%s %s: %s [%.2fs]\n", ok ? "PASS" : "FAIL", [name UTF8String], [detail UTF8String], elapsed);
  fflush(stdout);
}

#pragma mark - Client

@interface Response : NSObject
@property(nonatomic) NSInteger status;  // 0 if no status line was received
@property(nonatomic, copy) NSString* statusLine;
@property(nonatomic, strong) NSMutableDictionary<NSString*, NSString*>* headers;  // Lowercased names
@property(nonatomic, strong) NSData* body;  // De-chunked when Transfer-Encoding: chunked
@property(nonatomic, strong) NSData* raw;
@property(nonatomic) BOOL chunked;
@property(nonatomic, copy) NSString* error;  // Socket error while reading, if any
@end

@implementation Response
- (NSString*)bodyString {
  NSString* string = [[NSString alloc] initWithData:self.body encoding:NSUTF8StringEncoding];
  return string ? string : @"<binary>";
}
- (id)json {
  return self.body.length ? [NSJSONSerialization JSONObjectWithData:self.body options:0 error:NULL] : nil;
}
@end

static int Connect(NSUInteger port) {
  int fd = socket(PF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (fd < 0) {
    return -1;
  }
#ifdef SO_NOSIGPIPE
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
  struct timeval timeout = {10, 0};
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr*)&addr, sizeof(addr)) != 0) {
    close(fd);
    return -1;
  }
  return fd;
}

static BOOL SendAll(int fd, NSData* data) {
#ifdef MSG_NOSIGNAL
  int flags = MSG_NOSIGNAL;
#else
  int flags = 0;
#endif
  const char* bytes = data.bytes;
  NSUInteger sent = 0;
  while (sent < data.length) {
    ssize_t n = send(fd, bytes + sent, data.length - sent, flags);
    if (n <= 0) {
      if ((n < 0) && (errno == EINTR)) {
        continue;
      }
      return NO;
    }
    sent += (NSUInteger)n;
  }
  return YES;
}

static NSData* Utf8(NSString* string) {
  return [string dataUsingEncoding:NSUTF8StringEncoding];
}

static NSRange Find(NSData* data, const char* needle, NSUInteger from) {
  return [data rangeOfData:[NSData dataWithBytes:needle length:strlen(needle)] options:0 range:NSMakeRange(from, data.length - from)];
}

// Removes chunked framing; nil if the framing is broken
static NSData* Dechunk(NSData* data) {
  NSMutableData* result = [NSMutableData data];
  NSUInteger offset = 0;
  while (1) {
    NSRange crlf = Find(data, "\r\n", offset);
    if (crlf.location == NSNotFound) {
      return nil;
    }
    NSString* sizeLine = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(offset, crlf.location - offset)] encoding:NSASCIIStringEncoding];
    unsigned int size = 0;
    if (![[NSScanner scannerWithString:sizeLine] scanHexInt:&size]) {
      return nil;
    }
    offset = crlf.location + 2;
    if (size == 0) {
      return result;
    }
    if (offset + size + 2 > data.length) {
      return nil;
    }
    [result appendData:[data subdataWithRange:NSMakeRange(offset, size)]];
    offset += size + 2;
  }
}

static Response* ParseResponse(NSData* raw, NSString* error) {
  Response* response = [[Response alloc] init];
  response.raw = raw;
  response.error = error;
  response.headers = [NSMutableDictionary dictionary];
  NSRange end = Find(raw, "\r\n\r\n", 0);
  if (end.location == NSNotFound) {
    return response;
  }
  NSString* head = [[NSString alloc] initWithData:[raw subdataWithRange:NSMakeRange(0, end.location)] encoding:NSISOLatin1StringEncoding];
  NSArray<NSString*>* lines = [head componentsSeparatedByString:@"\r\n"];
  response.statusLine = lines.firstObject;
  NSArray<NSString*>* parts = [response.statusLine componentsSeparatedByString:@" "];
  if ((parts.count >= 2) && [parts[0] hasPrefix:@"HTTP/1."]) {
    response.status = [parts[1] integerValue];
  }
  for (NSUInteger i = 1; i < lines.count; ++i) {
    NSRange colon = [lines[i] rangeOfString:@":"];
    if (colon.location != NSNotFound) {
      NSString* name = [[lines[i] substringToIndex:colon.location] lowercaseString];
      NSString* value = [[lines[i] substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      response.headers[name] = value;
    }
  }
  NSData* body = [raw subdataWithRange:NSMakeRange(end.location + 4, raw.length - end.location - 4)];
  if ([[response.headers[@"transfer-encoding"] lowercaseString] isEqualToString:@"chunked"]) {
    response.chunked = YES;
    body = Dechunk(body);
  }
  response.body = body;
  return response;
}

// Reads until the server closes the connection (it always sends Connection: close)
static NSData* ReadAll(int fd, NSString** error) {
  NSMutableData* data = [NSMutableData data];
  char buffer[16384];
  while (1) {
    ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
    if (n > 0) {
      [data appendBytes:buffer length:(NSUInteger)n];
    } else if (n == 0) {
      break;
    } else if (errno != EINTR) {
      *error = [NSString stringWithUTF8String:strerror(errno)];
      break;
    }
  }
  return data;
}

static Response* Exchange(NSUInteger port, NSData* request) {
  int fd = Connect(port);
  if (fd < 0) {
    return ParseResponse([NSData data], @"connect failed");
  }
  NSString* error = nil;
  if (!SendAll(fd, request)) {
    error = [NSString stringWithFormat:@"send: %s", strerror(errno)];
  }
  NSString* readError = nil;
  NSData* raw = ReadAll(fd, &readError);
  close(fd);
  return ParseResponse(raw, readError ? readError : error);
}

static NSString* Describe(Response* response) {
  if (response.status == 0) {
    return [NSString stringWithFormat:@"no response (%@, %lu bytes)", response.error ? response.error : @"closed", (unsigned long)response.raw.length];
  }
  return response.statusLine;
}

#pragma mark - Server

// Counts live connections, to check that none is leaked once its response is sent
static atomic_int _liveConnections = 0;

@interface SmokeConnection : GCDWebServerConnection
@end

@implementation SmokeConnection {
  BOOL _counted;
}
- (BOOL)open {
  _counted = YES;
  atomic_fetch_add(&_liveConnections, 1);
  return [super open];
}
- (void)dealloc {
  if (_counted) {
    atomic_fetch_sub(&_liveConnections, 1);
  }
}
@end

static GCDWebServer* StartServer(NSDictionary* extraOptions) {
  GCDWebServer* server = [[GCDWebServer alloc] init];

  // Default handler: echo the request as JSON. Any method; GCDWebServerDataRequest collects the body.
  [server addHandlerWithMatchBlock:^GCDWebServerRequest*(NSString* method, NSURL* url, NSDictionary<NSString*, NSString*>* headers, NSString* path, NSDictionary<NSString*, NSString*>* query) {
    return [[GCDWebServerDataRequest alloc] initWithMethod:method url:url headers:headers path:path query:query];
  }
      processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
        GCDWebServerDataRequest* dataRequest = (GCDWebServerDataRequest*)request;
        NSDictionary* echo = @{
          @"method" : request.method,
          @"path" : request.path,
          @"rawQuery" : request.URL.query ? request.URL.query : [NSNull null],
          @"query" : request.query ? request.query : @{},
          @"xTest" : [request.headers objectForKey:@"x-test"] ? [request.headers objectForKey:@"x-test"] : [NSNull null],  // Case-insensitive lookup
          @"bodyLength" : @(dataRequest.hasBody ? dataRequest.data.length : 0),
          @"body" : dataRequest.hasBody ? [[NSString alloc] initWithData:dataRequest.data encoding:NSUTF8StringEncoding] : @"",
        };
        return [GCDWebServerDataResponse responseWithJSONObject:echo];
      }];

  // Streamed response, sent with chunked transfer encoding
  [server addHandlerForMethod:@"GET"
                         path:@"/stream"
                 requestClass:[GCDWebServerRequest class]
                 processBlock:^GCDWebServerResponse*(GCDWebServerRequest* request) {
                   __block int index = 0;
                   return [GCDWebServerStreamedResponse responseWithContentType:@"text/plain"
                                                               asyncStreamBlock:^(GCDWebServerBodyReaderCompletionBlock completionBlock) {
                                                                 int current = index++;
                                                                 dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                                                   if (current < 5) {
                                                                     completionBlock(Utf8([NSString stringWithFormat:@"chunk-%d;", current]), nil);
                                                                   } else {
                                                                     completionBlock([NSData data], nil);  // End of stream
                                                                   }
                                                                 });
                                                               }];
                 }];

  // Asynchronous handler: answers later, from another queue
  [server addHandlerForMethod:@"GET"
                         path:@"/async"
                 requestClass:[GCDWebServerRequest class]
            asyncProcessBlock:^(GCDWebServerRequest* request, GCDWebServerCompletionBlock completionBlock) {
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                GCDWebServerDataResponse* response = [GCDWebServerDataResponse responseWithText:@"later"];
                response.statusCode = 202;
                [response setValue:@"yes" forAdditionalHeader:@"X-Async"];
                completionBlock(response);
              });
            }];

  NSMutableDictionary* options = [NSMutableDictionary dictionaryWithDictionary:@{
    GCDWebServerOption_Port : @0,
    GCDWebServerOption_BindToLocalhost : @YES,
    GCDWebServerOption_ServerName : @"gws-smoke",
    GCDWebServerOption_ConnectionClass : [SmokeConnection class],
  }];
  [options addEntriesFromDictionary:extraOptions];
  NSError* error = nil;
  if (![server startWithOptions:options error:&error]) {
    Check(NO, @"start", [NSString stringWithFormat:@"%@", error]);
    return nil;
  }
  return server;
}

#pragma mark - Checks

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    [GCDWebServer setLogLevel:4];  // Errors only; the checks below provoke warnings on purpose

    GCDWebServer* server = StartServer(@{GCDWebServerOption_MaxBodySize : @(1024 * 1024)});
    if (server == nil) {
      return 1;
    }
    NSUInteger port = server.port;
    Check(port > 0, @"start", [NSString stringWithFormat:@"listening on 127.0.0.1:%lu", (unsigned long)port]);

    // 1. GET with an OData-style query
    {
      Response* r = Exchange(port, Utf8(@"GET /svc/Products(1)?$filter=Name%20eq%20'x'&$top=2 HTTP/1.1\r\nHost: localhost\r\nX-TEST: odata\r\n\r\n"));
      NSDictionary* json = [r json];
      BOOL ok = (r.status == 200) && [json[@"method"] isEqual:@"GET"] && [json[@"path"] isEqual:@"/svc/Products(1)"] && [json[@"rawQuery"] isEqual:@"$filter=Name%20eq%20'x'&$top=2"] && [json[@"query"][@"$filter"] isEqual:@"Name eq 'x'"] && [json[@"query"][@"$top"] isEqual:@"2"] && [json[@"xTest"] isEqual:@"odata"] && [r.headers[@"content-type"] hasPrefix:@"application/json"] && [r.headers[@"connection"] isEqual:@"Close"] && [r.headers[@"server"] isEqual:@"gws-smoke"] && (r.headers[@"date"].length > 0);
      Check(ok, @"get-odata-query", [NSString stringWithFormat:@"%@ %@", Describe(r), [r bodyString]]);
    }

    // 2. POST with Content-Length
    {
      Response* r = Exchange(port, Utf8(@"POST /svc/Products HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"Name\":\"x\"}\n"));
      NSDictionary* json = [r json];
      BOOL ok = (r.status == 200) && [json[@"method"] isEqual:@"POST"] && [json[@"bodyLength"] isEqual:@13] && [json[@"body"] isEqual:@"{\"Name\":\"x\"}\n"];
      Check(ok, @"post-content-length", [NSString stringWithFormat:@"%@ %@", Describe(r), [r bodyString]]);
    }

    // 3. POST with a chunked body (chunk extension and trailer included)
    {
      Response* r = Exchange(port, Utf8(@"POST /svc/$batch HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n7;ext=1\r\n, world\r\n0\r\nX-Trailer: t\r\n\r\n"));
      NSDictionary* json = [r json];
      BOOL ok = (r.status == 200) && [json[@"bodyLength"] isEqual:@12] && [json[@"body"] isEqual:@"hello, world"];
      Check(ok, @"post-chunked", [NSString stringWithFormat:@"%@ %@", Describe(r), [r bodyString]]);
    }

    // 4. Expect: 100-continue: the body is only sent after the interim response
    {
      int fd = Connect(port);
      NSString* interim = nil;
      Response* r = nil;
      if (fd >= 0) {
        SendAll(fd, Utf8(@"PUT /svc/Products(1) HTTP/1.1\r\nHost: localhost\r\nContent-Type: text/plain\r\nContent-Length: 4\r\nExpect: 100-continue\r\n\r\n"));
        NSMutableData* head = [NSMutableData data];
        char c;
        while ((Find(head, "\r\n\r\n", 0).location == NSNotFound) && (recv(fd, &c, 1, 0) == 1)) {
          [head appendBytes:&c length:1];
        }
        interim = [[[[NSString alloc] initWithData:head encoding:NSISOLatin1StringEncoding] componentsSeparatedByString:@"\r\n"] firstObject];
        SendAll(fd, Utf8(@"ping"));
        NSString* error = nil;
        NSData* raw = ReadAll(fd, &error);
        close(fd);
        r = ParseResponse(raw, error);
      }
      NSDictionary* json = [r json];
      BOOL ok = [interim isEqual:@"HTTP/1.1 100 Continue"] && (r.status == 200) && [json[@"method"] isEqual:@"PUT"] && [json[@"body"] isEqual:@"ping"];
      Check(ok, @"expect-100-continue", [NSString stringWithFormat:@"interim \"%@\", then %@ %@", interim, Describe(r), [r bodyString]]);
    }

    // 5. Oversized request head (70 KiB header against the 64 KiB default limit)
    {
      NSString* big = [@"" stringByPaddingToLength:(70 * 1024) withString:@"a" startingAtIndex:0];
      Response* r = Exchange(port, Utf8([NSString stringWithFormat:@"GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: %@\r\n\r\n", big]));
      BOOL ok = (r.status == 431) || ((r.status == 0) && (r.raw.length == 0));
      Check(ok, @"oversized-head", (r.status == 431) ? Describe(r) : [NSString stringWithFormat:@"connection closed without a response (%@)", r.error ? r.error : @"EOF"]);
    }

    // 6. Malformed request line
    {
      Response* r = Exchange(port, Utf8(@"THIS IS NOT HTTP\r\nHost: localhost\r\n\r\n"));
      Check(r.status == 400, @"malformed-request-line", Describe(r));
    }

    // 7. Obsolete line folding is rejected
    {
      Response* r = Exchange(port, Utf8(@"GET / HTTP/1.1\r\nHost: localhost\r\nX-Test: a\r\n folded\r\n\r\n"));
      Check(r.status == 400, @"obs-fold", Describe(r));
    }

    // 7b. A path whose escapes are not UTF-8
    {
      Response* r = Exchange(port, Utf8(@"GET /svc/%FF HTTP/1.1\r\nHost: localhost\r\n\r\n"));
      Check(r.status == 400, @"bad-path-escape", Describe(r));
    }

    // 8. Streamed response, de-chunked by the client
    {
      Response* r = Exchange(port, Utf8(@"GET /stream HTTP/1.1\r\nHost: localhost\r\n\r\n"));
      NSString* body = r.body ? [[NSString alloc] initWithData:r.body encoding:NSUTF8StringEncoding] : nil;
      BOOL ok = (r.status == 200) && r.chunked && [body isEqual:@"chunk-0;chunk-1;chunk-2;chunk-3;chunk-4;"];
      Check(ok, @"streamed-chunked", [NSString stringWithFormat:@"%@, chunked=%d, body \"%@\"", Describe(r), r.chunked, body]);
    }

    // 9. Asynchronous handler
    {
      Response* r = Exchange(port, Utf8(@"GET /async HTTP/1.1\r\nHost: localhost\r\n\r\n"));
      BOOL ok = (r.status == 202) && [r.headers[@"x-async"] isEqual:@"yes"] && [[r bodyString] isEqual:@"later"];
      Check(ok, @"async-handler", [NSString stringWithFormat:@"%@ %@", Describe(r), [r bodyString]]);
    }

    // 10. Content-Length over GCDWebServerOption_MaxBodySize (1 MiB here): 413 before the body is read
    {
      Response* r = Exchange(port, Utf8(@"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nContent-Length: 2000000\r\n\r\n"));
      Check(r.status == 413, @"body-too-large", Describe(r));
    }

    // 11. Chunked body over the limit: 413 as soon as the chunk size is read
    {
      Response* r = Exchange(port, Utf8(@"POST /upload HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/octet-stream\r\nTransfer-Encoding: chunked\r\n\r\n200000\r\n"));
      Check(r.status == 413, @"chunked-too-large", Describe(r));
    }

    // 12. Content-Length together with Transfer-Encoding (request smuggling vector)
    {
      Response* r = Exchange(port, Utf8(@"POST / HTTP/1.1\r\nHost: localhost\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"));
      Check(r.status == 400, @"cl-and-te", Describe(r));
    }

    // 13. Read timeout (separate server with a 1 second timeout): an incomplete head gets 408
    {
      GCDWebServer* slow = StartServer(@{GCDWebServerOption_ReadTimeout : @1.0});
      NSDate* start = [NSDate date];
      Response* r = Exchange(slow.port, Utf8(@"GET / HTTP/1.1\r\nHost: localhost\r\n"));
      NSTimeInterval elapsed = -[start timeIntervalSinceNow];
      Check((r.status == 408) && (elapsed < 5.0), @"read-timeout", [NSString stringWithFormat:@"%@ after %.1fs", Describe(r), elapsed]);
      [slow stop];
    }

    // 14. Every connection object has been deallocated (nothing retains it after the response)
    {
      int live = 0;
      for (int i = 0; i < 50; ++i) {  // Up to 5 seconds for the last completion blocks to finish
        live = atomic_load(&_liveConnections);
        if (live == 0) {
          break;
        }
        [NSThread sleepForTimeInterval:0.1];
      }
      Check(live == 0, @"no-leaked-connections", [NSString stringWithFormat:@"%d connection object(s) still alive", live]);
    }

    [server stop];
    printf("%s: %d failure(s)\n", _failures ? "FAILED" : "OK", _failures);
    return _failures ? 1 : 0;
  }
}
