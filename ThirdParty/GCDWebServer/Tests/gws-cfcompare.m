/*
 gws-cfcompare: macOS only. Checks GCDWebServerHTTPMessage and the URL helpers
 of the ported GCDWebServer against the CFHTTPMessage / CFURL functions they
 replace, and prints the parser's answers to malformed heads.

 Build and run: make cfcompare (on macOS, without gnustep-make)
 */

#import <Foundation/Foundation.h>
#import <CFNetwork/CFNetwork.h>
#import "GCDWebServerPrivate.h"
#pragma clang diagnostic ignored "-Wdeprecated-declarations"  // The CF functions being compared against
static int fails = 0;
static void check(NSString* what, id a, id b) {
  if (!((a == nil && b == nil) || [a isEqual:b])) { fails++; printf("MISMATCH %s: cf=%s ours=%s\n", what.UTF8String, [[a description] UTF8String], [[b description] UTF8String]); }
}
int main(void) { @autoreleasepool {
  NSArray* targets = @[@"/svc/Products(1)?$filter=Name%20eq%20'x'&$top=2", @"/a%2Fb/?q", @"//", @"/", @"/x;p=1?a#f", @"/caf%C3%A9?x=%zz", @"*", @"http://h:8/p/q?z=1", @"/a?", @"/a?b?c", @"/[x]?{y}|", @"/%zz", @"//foo/bar?x", @"/a/b/", @"/%E2%82%AC/?%26=%3D", @"/a\"b<c>d^e`f", @"/x?y=\xc3\xa9"];
  NSArray* hosts = @[@"example.com:8080", @""];
  for (NSString* host in hosts) for (NSString* t in targets) {
    NSString* req = host.length ? [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: %@\r\ncontent-type: t/x\r\nX-Foo: a\r\nx-foo: b\r\n\r\n", t, host] : [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\ncontent-type: t/x\r\n\r\n", t];
    NSData* d = [req dataUsingEncoding:NSUTF8StringEncoding];
    CFHTTPMessageRef m = CFHTTPMessageCreateEmpty(NULL, true);
    CFHTTPMessageAppendBytes(m, d.bytes, d.length);
    NSURL* cu = CFBridgingRelease(CFHTTPMessageCopyRequestURL(m));
    GCDWebServerHTTPMessage* o = [[GCDWebServerHTTPMessage alloc] initRequest];
    // feed byte by byte to exercise incremental parsing
    GCDWebServerHTTPMessageParseStatus st = 0;
    for (NSUInteger i = 0; i < d.length; i++) st = [o appendBytes:(const char*)d.bytes + i length:1];
    if (st != kGCDWebServerHTTPMessageParseStatus_Complete) { printf("parse failed %s: %s\n", t.UTF8String, o.errorDescription.UTF8String); fails++; continue; }
    NSURL* ou = o.requestURL;
    check([@"rel " stringByAppendingString:t], [cu relativeString], [ou relativeString]);
    check([@"abs " stringByAppendingString:t], [cu absoluteString], [ou absoluteString]);
    NSString* cp = CFBridgingRelease(CFURLCopyPath((CFURLRef)cu)); NSString* op = GCDWebServerCopyURLPath(ou);
    check([@"path " stringByAppendingString:t], cp, op);
    check([@"query " stringByAppendingString:t], CFBridgingRelease(CFURLCopyQueryString((CFURLRef)cu, NULL)), GCDWebServerCopyURLQueryString(ou));
    check([@"method " stringByAppendingString:t], CFBridgingRelease(CFHTTPMessageCopyRequestMethod(m)), o.requestMethod);
    NSDictionary* ch = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(m)); NSDictionary* oh = [o allHeaderFields];
    check(@"ct", ch[@"Content-Type"], oh[@"Content-Type"]);
    check(@"host", ch[@"Host"], oh[@"Host"]);
    check(@"xfoo", ch[@"X-Foo"] ?: ch[@"x-foo"], oh[@"X-FOO"]);
    if (cp) check([@"unescape " stringByAppendingString:cp], CFBridgingRelease(CFURLCreateStringByReplacingPercentEscapesUsingEncoding(NULL, (CFStringRef)cp, CFSTR(""), kCFStringEncodingUTF8)), GCDWebServerUnescapeURLString(cp));
    CFRelease(m);
  }
  NSArray* un = @[@"%zz", @"%", @"a%2", @"%FF", @"%C3%A9", @"%c3%a9", @"%00x", @"%2B+", @"%%41", @"é%41", @"%E2%82", @"plain", @"", @"a%20b%2"];
  for (NSString* u in un) check([@"unesc " stringByAppendingString:u], CFBridgingRelease(CFURLCreateStringByReplacingPercentEscapesUsingEncoding(NULL, (CFStringRef)u, CFSTR(""), kCFStringEncodingUTF8)), GCDWebServerUnescapeURLString(u));
  NSMutableString* all = [NSMutableString string]; for (unichar c = 1; c < 256; c++) [all appendFormat:@"%C", c]; [all appendString:@"€😀"];
  check(@"escape", CFBridgingRelease(CFURLCreateStringByAddingPercentEscapes(NULL, (CFStringRef)all, NULL, CFSTR(":@/?&=+"), kCFStringEncodingUTF8)), GCDWebServerEscapeURLString(all));
  // form parsing
  NSDictionary* f = GCDWebServerParseURLEncodedForm(@"$filter=Name%20eq%20'x'&$top=2&a+b=c+d");
  printf("form=%s\n", [[f description] UTF8String]);
  // serialisation
  GCDWebServerHTTPMessage* r = [[GCDWebServerHTTPMessage alloc] initResponseWithStatusCode:431];
  [r setValue:@"Close" forHeaderField:@"Connection"]; [r setValue:@"1" forHeaderField:@"X-A"]; [r setValue:@"2\r\nEvil: yes" forHeaderField:@"x-a"]; [r setValue:@"gone" forHeaderField:@"Z"]; [r setValue:nil forHeaderField:@"z"];
  printf("%s", [[[NSString alloc] initWithData:[r serializedHead] encoding:NSUTF8StringEncoding] UTF8String]);
  // errors
  NSArray* bad = @[@"GET /\r\n\r\n", @"GET  / HTTP/1.1\r\n\r\n", @"GET / HTTP/2.0\r\n\r\n", @"GET / HTTP/1.1\r\nA: b\r\n folded\r\n\r\n", @"GET / HTTP/1.1\r\nA : b\r\n\r\n", @"GET / HTTP/1.1\nA: b\r\n\r\n", @"GET / HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n", @"GET / HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n", @"GET / HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n", @"GET / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", @"G(T / HTTP/1.1\r\n\r\n", @"GET / HTTP/1.1\r\nA: b\x01\r\n\r\n"];
  for (NSString* b in bad) { GCDWebServerHTTPMessage* o = [[GCDWebServerHTTPMessage alloc] initRequest]; NSData* d = [b dataUsingEncoding:NSUTF8StringEncoding]; [o appendBytes:d.bytes length:d.length]; printf("bad -> %ld %s\n", (long)o.errorStatusCode, o.errorDescription.UTF8String); if (!o.errorStatusCode) fails++; }
  GCDWebServerHTTPMessage* ok = [[GCDWebServerHTTPMessage alloc] initRequest]; NSData* d = [@"\r\nPOST /x HTTP/1.0\r\nContent-Length: 3, 3\r\n\r\nabcdef" dataUsingEncoding:NSUTF8StringEncoding];
  printf("ok status=%ld cl=%s body=%lu\n", (long)[ok appendBytes:d.bytes length:d.length], [[ok allHeaderFields][@"content-length"] UTF8String], (unsigned long)ok.bodyData.length);
  GCDWebServerHTTPMessage* big = [[GCDWebServerHTTPMessage alloc] initRequest]; big.maxHeadSize = 100; NSData* bd = [[@"GET / HTTP/1.1\r\nX: " stringByPaddingToLength:200 withString:@"a" startingAtIndex:0] dataUsingEncoding:NSUTF8StringEncoding];
  [big appendBytes:bd.bytes length:bd.length]; printf("big -> %ld\n", (long)big.errorStatusCode);
  printf("fails=%d\n", fails);
  return fails != 0;
}}
