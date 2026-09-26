// ois-serve-check — the HTTP adapter over a real loopback socket.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   ois-serve-check <Catalog.momd or .xcdatamodeld>
//
// Starts an ODataHTTPServer on 127.0.0.1 over the Catalog model in memory
// and talks to it with plain sockets, not the URL loading system, so that
// what is tested is the listener and the service, as a proxy would reach
// them. One line per check; exits 0 only if all pass. The protocol itself
// is tested without sockets, in Tests/ODataServiceTests.m.

#import "ODataIncrementalStore.h"
#import "ODataHTTPServer.h"
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

static int failures;
static NSUInteger port;

static void check(BOOL ok, NSString *name, NSString *detail)
{
  printf("%s %s: %s\n", ok ? "PASS" : "FAIL", name.UTF8String, detail.UTF8String);
  if (!ok) failures++;
}

@interface OISReply : NSObject
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) NSDictionary *headers;  // lower-case names
@property (nonatomic, copy) NSData *body;
@property (nonatomic, readonly) id json;
@property (nonatomic, readonly) NSString *text;
@end

@implementation OISReply
- (id)json
{
  return self.body.length ? [NSJSONSerialization JSONObjectWithData:self.body options:0 error:NULL] : nil;
}
- (NSString *)text
{
  return [[NSString alloc] initWithData:self.body ?: [NSData data] encoding:NSUTF8StringEncoding] ?: @"";
}
@end

// One request, written as given, and the whole response, read to the end
// (the server closes each connection).
static OISReply *OISSendRaw(NSData *request)
{
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  struct sockaddr_in address;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  address.sin_port = htons((uint16_t)port);
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
    close(fd);
    return nil;
  }
  const uint8_t *bytes = request.bytes;
  for (NSUInteger sent = 0; sent < request.length;) {
    ssize_t n = write(fd, bytes + sent, request.length - sent);
    if (n <= 0) break;
    sent += (NSUInteger)n;
  }
  NSMutableData *all = [NSMutableData data];
  uint8_t buffer[16384];
  for (;;) {
    ssize_t n = read(fd, buffer, sizeof(buffer));
    if (n <= 0) break;
    [all appendBytes:buffer length:(NSUInteger)n];
  }
  close(fd);

  NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
  NSRange end = [all rangeOfData:separator options:0 range:NSMakeRange(0, all.length)];
  if (end.location == NSNotFound) return nil;
  NSString *head = [[NSString alloc] initWithData:[all subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
  NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
  OISReply *reply = [[OISReply alloc] init];
  NSArray *statusLine = [lines[0] componentsSeparatedByString:@" "];
  reply.status = statusLine.count > 1 ? [statusLine[1] integerValue] : 0;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound) continue;
    headers[[line substringToIndex:colon.location].lowercaseString] =
      [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  }
  reply.headers = headers;
  reply.body = [all subdataWithRange:NSMakeRange(NSMaxRange(end), all.length - NSMaxRange(end))];
  return reply;
}

static OISReply *OISSend(NSString *method, NSString *target, NSDictionary *headers, id json)
{
  NSData *body = json ? [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL] : nil;
  NSMutableString *head = [NSMutableString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: 127.0.0.1:%lu\r\nConnection: close\r\n",
                           method, target, (unsigned long)port];
  for (NSString *name in headers) [head appendFormat:@"%@: %@\r\n", name, headers[name]];
  if (body) [head appendFormat:@"Content-Type: application/json\r\nContent-Length: %lu\r\n", (unsigned long)body.length];
  [head appendString:@"\r\n"];
  NSMutableData *request = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
  if (body) [request appendData:body];
  return OISSendRaw(request);
}

static NSManagedObject *OISInsert(NSManagedObjectContext *context, NSString *entity, NSDictionary *values)
{
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity inManagedObjectContext:context];
  for (NSString *key in values) [object setValue:values[key] forKey:key];
  return object;
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    if (argc < 2) {
      fprintf(stderr, "usage: ois-serve-check <Catalog.momd>\n");
      return 2;
    }
    NSString *modelPath = @(argv[1]);
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:modelPath]];
    if (!model.entities.count) {
      fprintf(stderr, "ois-serve-check: %s is not a model\n", argv[1]);
      return 2;
    }
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSError *error = nil;
    [coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil options:nil error:&error];
    NSManagedObjectContext *seed = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    seed.persistentStoreCoordinator = coordinator;
    __block BOOL seeded = NO;
    [seed performBlockAndWait:^{
      NSManagedObject *beverages = OISInsert(seed, @"Category", @{ @"id": @1, @"name": @"Beverages" });
      NSManagedObject *condiments = OISInsert(seed, @"Category", @{ @"id": @2, @"name": @"Condiments" });
      OISInsert(seed, @"Product", @{ @"id": @1, @"name": @"Chai", @"unitPrice": [NSDecimalNumber decimalNumberWithString:@"18"], @"category": beverages });
      OISInsert(seed, @"Product", @{ @"id": @2, @"name": @"Chang", @"unitPrice": [NSDecimalNumber decimalNumberWithString:@"19"], @"category": beverages });
      OISInsert(seed, @"Product", @{ @"id": @3, @"name": @"Aniseed Syrup", @"unitPrice": [NSDecimalNumber decimalNumberWithString:@"10"], @"category": condiments });
      NSError *saveError = nil;
      seeded = [seed save:&saveError];
      if (!seeded) fprintf(stderr, "ois-serve-check: seeding failed: %s\n", saveError.localizedDescription.UTF8String);
    }];
    if (!seeded) return 2;

    // The public root a proxy would forward from; the adapter answers under
    // its path and writes links with it.
    ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator
                                                                         serviceRoot:[NSURL URLWithString:@"https://api.example.test/odata/"]];
    ODataHTTPServer *server = [[ODataHTTPServer alloc] initWithService:service];
    BOOL started = [server startOnPort:0 error:&error];
    port = server.port;
    check(started && port > 0, @"start", [NSString stringWithFormat:@"listening on 127.0.0.1:%lu %@", (unsigned long)port, error ?: @""]);
    if (!started) return 1;

    OISReply *metadata = OISSend(@"GET", @"/odata/$metadata", nil, nil);
    check(metadata.status == 200 && [metadata.headers[@"content-type"] hasPrefix:@"application/xml"] &&
          [metadata.text rangeOfString:@"<EntitySet Name=\"Products\""].location != NSNotFound,
          @"metadata", [NSString stringWithFormat:@"%ld %@", (long)metadata.status, metadata.headers[@"content-type"]]);

    OISReply *filtered = OISSend(@"GET", @"/odata/Products?$filter=UnitPrice%20gt%2015&$orderby=ProductName%20desc&$select=ProductName", nil, nil);
    NSArray *names = [filtered.json[@"value"] valueForKey:@"ProductName"];
    check(filtered.status == 200 && [names isEqual:(@[ @"Chang", @"Chai" ])] &&
          [filtered.json[@"@odata.context"] isEqual:@"https://api.example.test/odata/$metadata#Products(ProductName)"] &&
          [filtered.headers[@"odata-version"] isEqual:@"4.01"],
          @"query", [NSString stringWithFormat:@"%ld %@ %@", (long)filtered.status, names, filtered.json[@"@odata.context"]]);

    OISReply *quoted = OISSend(@"GET", @"/odata/Products?$filter=ProductName%20eq%20'Aniseed%20Syrup'", nil, nil);
    check([[quoted.json[@"value"] valueForKey:@"ProductID"] isEqual:@[ @3 ]], @"quoted-literal", quoted.text);

    OISReply *created = OISSend(@"POST", @"/odata/Products", nil, @{ @"ProductName": @"Ipoh Coffee", @"UnitPrice": @46, @"Category@odata.bind": @"Categories(1)" });
    check(created.status == 201 && [created.headers[@"location"] isEqual:@"https://api.example.test/odata/Products(4)"] && created.headers[@"etag"],
          @"create", [NSString stringWithFormat:@"%ld %@", (long)created.status, created.headers[@"location"]]);

    OISReply *stale = OISSend(@"PATCH", @"/odata/Products(4)", @{ @"If-Match": @"W/\"0\"" }, @{ @"UnitPrice": @40 });
    check(stale.status == 412 && [stale.json[@"error"][@"message"] length], @"stale-etag", [NSString stringWithFormat:@"%ld %@", (long)stale.status, stale.text]);
    OISReply *patched = OISSend(@"PATCH", @"/odata/Products(4)", @{ @"If-Match": created.headers[@"etag"] ?: @"*" }, @{ @"UnitPrice": @40 });
    check(patched.status == 204 && patched.headers[@"etag"] && ![patched.headers[@"etag"] isEqual:created.headers[@"etag"]],
          @"update", [NSString stringWithFormat:@"%ld %@", (long)patched.status, patched.headers[@"etag"]]);

    // A chunked body, as Caddy streams one.
    NSString *chunkedBody = @"{\"ProductName\":\"Genen Shouyu\",\"UnitPrice\":15.5}";
    NSString *chunked = [NSString stringWithFormat:@"POST /odata/Categories(2)/Products HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
                         @"Content-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n%lx\r\n%@\r\n0\r\n\r\n",
                         (unsigned long)chunkedBody.length, chunkedBody];
    OISReply *created2 = OISSendRaw([chunked dataUsingEncoding:NSUTF8StringEncoding]);
    check(created2.status == 201 && [created2.json[@"ProductName"] isEqual:@"Genen Shouyu"], @"chunked-create",
          [NSString stringWithFormat:@"%ld %@", (long)created2.status, created2.text]);
    OISReply *count = OISSend(@"GET", @"/odata/Categories(2)/Products/$count", nil, nil);
    check(count.status == 200 && [count.text isEqual:@"2"], @"count", count.text);

    OISReply *missing = OISSend(@"GET", @"/odata/Nothing", nil, nil);
    check(missing.status == 404 && [missing.json[@"error"][@"code"] length], @"not-found", missing.text);
    OISReply *outside = OISSend(@"GET", @"/elsewhere", nil, nil);
    check(outside.status == 404, @"outside-root", [NSString stringWithFormat:@"%ld", (long)outside.status]);
    OISReply *head = OISSend(@"HEAD", @"/odata/Products(1)", nil, nil);
    check(head.status == 200 && head.body.length == 0 && head.headers[@"etag"], @"head", [NSString stringWithFormat:@"%ld, %lu bytes", (long)head.status, (unsigned long)head.body.length]);
    OISReply *deleted = OISSend(@"DELETE", @"/odata/Products(4)", nil, nil);
    check(deleted.status == 204 && OISSend(@"GET", @"/odata/Products(4)", nil, nil).status == 404, @"delete", [NSString stringWithFormat:@"%ld", (long)deleted.status]);

    // Requests at once, each on a connection of its own.
    __block NSInteger ok = 0;
    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [[NSObject alloc] init];
    for (int i = 0; i < 24; i++) {
      dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{
        OISReply *r = OISSend(@"GET", @"/odata/Products?$expand=Category", nil, nil);
        if (r.status == 200 && [r.json[@"value"] count] == 4) {
          @synchronized (lock) {
            ok++;
          }
        }
      });
    }
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    check(ok == 24, @"concurrent", [NSString stringWithFormat:@"%ld of 24 answered", (long)ok]);

    [server stop];
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
  }
  return failures ? 1 : 0;
}
