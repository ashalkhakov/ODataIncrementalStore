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

#import "ODataService.h"
#import "ODataServer.h"
#import <ODataKit/ODataBatch.h>
#import <ODataKit/ODataError.h>
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

#pragma mark An application of its own

// GET /hello/:name: who it greets, and who asked.
@interface OISHelloHandler : NSObject <ODataServerHandler>
@end

@implementation OISHelloHandler
- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  NSMutableString *order = request.userInfo[@"order"];
  [order appendString:@"handler"];
  [reply finishWithResponse:[ODataServerResponse responseWithJSON:@{ @"hello": request.pathParameters[@"name"] ?: @"",
                                                                      @"asker": request.principal.subject ?: [NSNull null] }
                                                            status:200]];
}
@end

// Answers later, from another queue, as a handler that asks a database does.
@interface OISLaterHandler : NSObject <ODataServerHandler>
@end

@implementation OISLaterHandler
- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    [reply finishWithResponse:[ODataServerResponse responseWithText:@"later" status:202]];
  });
}
@end

@interface OISBoomHandler : NSObject <ODataServerHandler>
@end

@implementation OISBoomHandler
- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  [NSException raise:NSInternalInconsistencyException format:@"on purpose"];
}
@end

// Notes the way in and the way out: X-Order shows the order stages ran.
@interface OISOrderStage : ODataServerStage
@property (nonatomic, copy) NSString *name;
@end

@implementation OISOrderStage
- (BOOL)shouldPassRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  NSMutableString *order = request.userInfo[@"order"];
  if (!order) request.userInfo[@"order"] = order = [NSMutableString string];
  [order appendFormat:@"%@>", self.name];
  return YES;
}
- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response
{
  NSMutableString *order = request.userInfo[@"order"];
  [order appendFormat:@"<%@", self.name];
  [response setValue:order forHeader:@"X-Order"];
}
@end

// Answers /blocked itself, and sees its own answer on the way back.
@interface OISBlockingStage : ODataServerStage
@end

@implementation OISBlockingStage
- (BOOL)shouldPassRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  if (![request.path isEqualToString:@"/blocked"]) return YES;
  [reply finishWithResponse:[ODataServerResponse responseWithText:@"no" status:418]];
  return NO;
}
- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response
{
  if (response.status == 418) [response setValue:@"418" forHeader:@"X-Blocked-Saw"];
}
@end

// The access log, kept rather than written.
@interface OISKeptLog : ODataAccessLogStage
@property (nonatomic, strong) NSMutableArray<NSString *> *lines;
@end

@implementation OISKeptLog
- (void)writeLine:(NSString *)line
{
  @synchronized (self) {
    [self.lines addObject:line];
  }
}
@end

// Asks elsewhere and answers later, from another queue: Token <name> is
// <name>; Token banned is refused.
@interface OISLaterAuthenticator : NSObject <ODataAuthenticator>
@end

@implementation OISLaterAuthenticator
- (void)authenticateRequest:(ODataRequest *)request reply:(ODataReply *)reply
{
  [reply defer];
  NSString *given = [[request valueForHeader:@"Authorization"] stringByReplacingOccurrencesOfString:@"Token " withString:@""];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_global_queue(0, 0), ^{
    if ([given isEqualToString:@"banned"]) {
      [reply failWithError:ODataServiceError(401, @"That token is not taken here")];
    } else {
      [reply finishWithResult:given.length ? [[ODataPrincipal alloc] initWithSubject:given claims:@{}] : nil];
    }
  });
}
- (NSString *)challengeForRequest:(ODataRequest *)request
{
  return @"Token realm=\"check\"";
}
@end

// Collects what an authenticator answered.
// (A condition lock, not a semaphore: on GNUstep a dispatch object is no
// Objective-C object a property can keep.)
@interface OISAnswers : NSObject
@property (nonatomic, strong) NSConditionLock *done;
@property (nonatomic, strong) ODataAuthentication *answer;
@end

@implementation OISAnswers
- (void)didAuthenticate:(ODataAuthentication *)answer
{
  [self.done lock];
  self.answer = answer;
  [self.done unlockWithCondition:1];
}
@end

static ODataAuthentication *OISAskLater(NSString *authorization)
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://example.test/anything"]];
  if (authorization) [request setValue:authorization forHTTPHeaderField:@"Authorization"];
  OISAnswers *answers = [[OISAnswers alloc] init];
  answers.done = [[NSConditionLock alloc] initWithCondition:0];
  [ODataAuthentication authenticateURLRequest:request with:[[OISLaterAuthenticator alloc] init] timeout:5
                                       target:answers action:@selector(didAuthenticate:)];
  if (![answers.done lockWhenCondition:1 beforeDate:[NSDate dateWithTimeIntervalSinceNow:5]]) return nil;
  ODataAuthentication *answer = answers.answer;
  [answers.done unlock];
  return answer;
}

@interface OISCheckApplication : ODataServerApplication
@property (nonatomic, strong) OISKeptLog *log;
@end

@implementation OISCheckApplication
- (void)configureRouter:(ODataServerRouter *)router
{
  [router insertRoute:[ODataServerRoute routeWithMethod:@"GET" path:@"/hello/:name" handler:[[OISHelloHandler alloc] init]] atIndex:0];
  ODataServerRoute *billing = [ODataServerRoute routeWithMethod:@"POST" path:@"/webhooks/billing" handler:[[OISLaterHandler alloc] init]];
  billing.scopes = [NSSet setWithObject:@"Billing.Notify"];
  [router addRoute:billing];
  ODataServerRoute *members = [ODataServerRoute routeWithMethod:@"GET" path:@"/members" handler:[[OISHelloHandler alloc] init]];
  members.requiresPrincipal = YES;
  [router addRoute:members];
  [router addRoute:[ODataServerRoute routeWithMethod:@"GET" path:@"/later" handler:[[OISLaterHandler alloc] init]]];
  [router addRoute:[ODataServerRoute routeWithMethod:@"GET" path:@"/boom" handler:[[OISBoomHandler alloc] init]]];
}
- (void)configurePipeline:(ODataServerPipeline *)pipeline
{
  // Its own log in place of the standard one, where it was.
  self.log = [[OISKeptLog alloc] init];
  self.log.lines = [NSMutableArray array];
  [pipeline replaceStageOfClass:[ODataAccessLogStage class] withStage:self.log];
  OISOrderStage *a = [[OISOrderStage alloc] init], *b = [[OISOrderStage alloc] init];
  a.name = @"a";
  b.name = @"b";
  [pipeline addStage:a];
  [pipeline addStage:b];
  [pipeline addStage:[[OISBlockingStage alloc] init]];
}
@end

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

    // A $batch with a change set, over the socket: two new categories, the
    // second one's product bound to the first by its Content-ID.
    NSString *batch = @"--b\r\nContent-Type: multipart/mixed; boundary=cs\r\n\r\n"
      @"--cs\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 1\r\n\r\n"
      @"POST Categories HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"CategoryName\":\"Seafood\"}\r\n"
      @"--cs\r\nContent-Type: application/http\r\nContent-Transfer-Encoding: binary\r\nContent-ID: 2\r\n\r\n"
      @"POST $1/Products HTTP/1.1\r\nContent-Type: application/json\r\n\r\n{\"ProductName\":\"Ikura\"}\r\n"
      @"--cs--\r\n--b--\r\n";
    NSString *batchHead = [NSString stringWithFormat:@"POST /odata/$batch HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n"
                      @"Content-Type: multipart/mixed; boundary=b\r\nContent-Length: %lu\r\n\r\n", (unsigned long)[batch lengthOfBytesUsingEncoding:NSUTF8StringEncoding]];
    OISReply *batched = OISSendRaw([[batchHead stringByAppendingString:batch] dataUsingEncoding:NSUTF8StringEncoding]);
    NSString *boundary = ODataMultipartBoundary(batched.headers[@"content-type"] ?: @"");
    NSArray *batchParts = boundary ? ODataBatchParts(batched.body, boundary) : nil;
    check(batched.status == 200 && [[batchParts valueForKey:@"status"] isEqual:(@[ @201, @201 ])] &&
          [OISSend(@"GET", @"/odata/Categories(3)/Products/$count", nil, nil).text isEqual:@"1"],
          @"batch", [NSString stringWithFormat:@"%ld %@", (long)batched.status, [batchParts valueForKey:@"status"]]);

    // Requests at once, each on a connection of its own.
    NSUInteger expected = (NSUInteger)[OISSend(@"GET", @"/odata/Products/$count", nil, nil).text integerValue];
    __block NSInteger ok = 0;
    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [[NSObject alloc] init];
    for (int i = 0; i < 24; i++) {
      dispatch_group_async(group, dispatch_get_global_queue(0, 0), ^{
        OISReply *r = OISSend(@"GET", @"/odata/Products?$expand=Category", nil, nil);
        if (r.status == 200 && [r.json[@"value"] count] == expected) {
          @synchronized (lock) {
            ok++;
          }
        }
      });
    }
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)));
    check(ok == 24, @"concurrent", [NSString stringWithFormat:@"%ld of 24 answered", (long)ok]);

    // Behind a proxy that signs users in: who is asking, from its headers.
    ODataTrustedHeaderAuthenticator *proxy = [[ODataTrustedHeaderAuthenticator alloc] init];
    proxy.secretHeader = @"X-OIS-Proxy-Secret";
    proxy.secret = @"s3cret";
    service.authenticator = proxy;
    OISReply *anonymous = OISSend(@"GET", @"/odata/Products", nil, nil);
    check(anonymous.status == 401 && [anonymous.headers[@"www-authenticate"] isEqual:@"Bearer"], @"sign-in-required",
          [NSString stringWithFormat:@"%ld %@", (long)anonymous.status, anonymous.headers]);
    OISReply *signedIn = OISSend(@"GET", @"/odata/Products", @{ @"x-forwarded-user": @"ann", @"X-OIS-Proxy-Secret": @"s3cret" }, nil);
    check(signedIn.status == 200 && [signedIn.json[@"value"] count] == expected, @"signed-in", [NSString stringWithFormat:@"%ld %@", (long)signedIn.status, signedIn.text]);
    OISReply *bypassed = OISSend(@"GET", @"/odata/Products", @{ @"X-Forwarded-User": @"ann" }, nil);
    check(bypassed.status == 401, @"proxy-bypassed", [NSString stringWithFormat:@"%ld", (long)bypassed.status]);
    service.authenticator = nil;
    [server stop];

    // Settings from the environment, as a container has them: the property
    // list first, then OIS_ variables, then the command line.
    NSDictionary *variables = @{ @"Port": @"OIS_PORT", @"MaxPageSize": @"OIS_MAX_PAGE_SIZE", @"JWTIssuer": @"OIS_JWT_ISSUER",
                             @"MaxURLLength": @"OIS_MAX_URL_LENGTH", @"ServiceRoot": @"OIS_SERVICE_ROOT", @"MaxJSONDepth": @"OIS_MAX_JSON_DEPTH" };
    NSMutableArray *misnamed = [NSMutableArray array];
    for (NSString *name in variables) {
      NSString *variable = [ODataServerConfiguration environmentVariableForSetting:name];
      if (![variable isEqualToString:variables[name]]) [misnamed addObject:[NSString stringWithFormat:@"%@: %@", name, variable]];
    }
    check(!misnamed.count, @"env-names", [misnamed componentsJoinedByString:@", "]);
    NSString *plist = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ois-serve-check.plist"];
    [@{ @"Port": @7000, @"HealthPath": @"/up", @"Namespace": @"FromFile" } writeToFile:plist atomically:YES];
    ODataServerConfiguration *fromEnvironment = [ODataServerConfiguration configurationWithArguments:@{ @"Namespace": @"FromArguments" }
      environment:@{ @"OIS_CONFIG": plist, @"OIS_PORT": @"7001", @"OIS_LOCALHOST": @"NO", @"OIS_NAMESPACE": @"FromEnvironment",
                     @"OIS_TRUSTED_CLAIM_HEADERS": @"{\"email\": \"X-Mail\"}", @"OIS_REPORT_TITLE": @"Daily",
                     @"OIS_BUNDLES": @"/a.bundle:/b.bundle", @"HOME": @"/root" } error:&error];
    check(fromEnvironment.port == 7001 && !fromEnvironment.bindToLocalhost && [fromEnvironment.healthPath isEqual:@"/up"] &&
          [fromEnvironment.settings[@"Namespace"] isEqual:@"FromArguments"] &&
          [fromEnvironment.settings[@"TrustedClaimHeaders"] isEqual:@{ @"email": @"X-Mail" }] &&
          [fromEnvironment.settings[@"ReportTitle"] isEqual:@"Daily"] &&
          [fromEnvironment.bundlePaths isEqual:(@[ @"/a.bundle", @"/b.bundle" ])] && !fromEnvironment.settings[@"Home"],
          @"env-settings", [NSString stringWithFormat:@"%@ %@", fromEnvironment.settings, error ?: @""]);
    [[NSFileManager defaultManager] removeItemAtPath:plist error:NULL];

    // An authenticator that answers later, asked for a host: no service, no
    // context, and the answer still comes.
    ODataAuthentication *deferredAnswer = OISAskLater(@"Token ann");
    check([deferredAnswer.principal.subject isEqual:@"ann"] && !deferredAnswer.error, @"auth-deferred", deferredAnswer.principal.subject ?: @"(no answer)");
    ODataAuthentication *nobody = OISAskLater(nil);
    check(nobody && !nobody.principal && !nobody.error, @"auth-no-one", nobody ? @"no one" : @"(no answer)");
    ODataAuthentication *banned = OISAskLater(@"Token banned");
    check(banned.error.code == 401 && [banned.challenge isEqual:@"Token realm=\"check\""], @"auth-refused",
          [NSString stringWithFormat:@"%ld %@", (long)banned.error.code, banned.challenge]);

    // An application of its own, made from settings as ois-serve's are:
    // routes and stages around the service, one sign-in for all of them.
    ODataServerConfiguration *configuration = [[ODataServerConfiguration alloc] initWithSettings:@{
      @"Model": modelPath, @"ServiceRoot": @"https://api.example.test/odata/", @"TrustedUserHeader": @"X-Forwarded-User" }];
    OISCheckApplication *application = [[OISCheckApplication alloc] initWithConfiguration:configuration];
    BOOL prepared = [application prepare:&error];
    check(prepared, @"app-prepare", [NSString stringWithFormat:@"%@\n%@\n%@", error ?: @"", application.pipeline, application.router]);
    if (!prepared) return 1;
    started = [application.server startOnPort:0 error:&error];
    port = application.server.port;
    check(started, @"app-start", [NSString stringWithFormat:@"port %lu %@", (unsigned long)port, error ?: @""]);
    if (!started) return 1;
    NSDictionary *ann = @{ @"X-Forwarded-User": @"ann" };

    OISReply *health = OISSend(@"GET", @"/health", nil, nil);
    check(health.status == 200 && [health.json[@"status"] isEqual:@"ok"], @"app-health", health.text);
    OISReply *hello = OISSend(@"GET", @"/hello/world", ann, nil);
    check(hello.status == 200 && [hello.json[@"hello"] isEqual:@"world"] && [hello.json[@"asker"] isEqual:@"ann"],
          @"app-route", [NSString stringWithFormat:@"%ld %@", (long)hello.status, hello.text]);
    check([hello.headers[@"x-order"] isEqual:@"a>b>handler<b<a"], @"app-stage-order", hello.headers[@"x-order"] ?: @"(none)");
    check([hello.headers[@"x-request-id"] length] > 0, @"app-request-id", hello.headers[@"x-request-id"] ?: @"(none)");
    OISReply *given = OISSend(@"GET", @"/hello/x", @{ @"X-Request-ID": @"abc-123" }, nil);
    check([given.headers[@"x-request-id"] isEqual:@"abc-123"], @"app-request-id-given", given.headers[@"x-request-id"] ?: @"(none)");
    OISReply *anyone = OISSend(@"GET", @"/hello/x", nil, nil);
    check(anyone.status == 200 && anyone.json[@"asker"] == [NSNull null], @"app-route-anyone", anyone.text);

    OISReply *blocked = OISSend(@"GET", @"/blocked", nil, nil);
    check(blocked.status == 418 && [blocked.headers[@"x-blocked-saw"] isEqual:@"418"] && [blocked.headers[@"x-order"] isEqual:@"a>b><b<a"],
          @"app-stage-answers", [NSString stringWithFormat:@"%ld %@ %@", (long)blocked.status, blocked.headers[@"x-blocked-saw"], blocked.headers[@"x-order"]]);
    OISReply *later = OISSend(@"GET", @"/later", nil, nil);
    check(later.status == 202 && [later.text isEqual:@"later"] && [later.headers[@"x-order"] isEqual:@"a>b><b<a"],
          @"app-deferred", [NSString stringWithFormat:@"%ld %@ %@", (long)later.status, later.text, later.headers[@"x-order"]]);
    OISReply *boom = OISSend(@"GET", @"/boom", nil, nil);
    check(boom.status == 500 && [boom.json[@"error"][@"message"] length], @"app-exception", [NSString stringWithFormat:@"%ld %@", (long)boom.status, boom.text]);

    OISReply *wrongMethod = OISSend(@"DELETE", @"/hello/x", nil, nil);
    check(wrongMethod.status == 405 && [wrongMethod.headers[@"allow"] isEqual:@"GET, HEAD"], @"app-405",
          [NSString stringWithFormat:@"%ld %@", (long)wrongMethod.status, wrongMethod.headers[@"allow"]]);
    OISReply *nowhere = OISSend(@"GET", @"/nowhere", nil, nil);
    check(nowhere.status == 404 && [nowhere.json[@"error"][@"code"] isEqual:@"404"], @"app-404", nowhere.text);
    OISReply *headOnly = OISSend(@"HEAD", @"/hello/x", nil, nil);
    check(headOnly.status == 200 && headOnly.body.length == 0, @"app-head", [NSString stringWithFormat:@"%ld, %lu bytes", (long)headOnly.status, (unsigned long)headOnly.body.length]);

    OISReply *noOne = OISSend(@"GET", @"/members", nil, nil);
    check(noOne.status == 401 && [noOne.headers[@"www-authenticate"] hasPrefix:@"Bearer"], @"app-route-signed-in", [NSString stringWithFormat:@"%ld %@", (long)noOne.status, noOne.headers[@"www-authenticate"]]);
    check(OISSend(@"GET", @"/members", ann, nil).status == 200, @"app-route-member", @"");
    OISReply *unscoped = OISSend(@"POST", @"/webhooks/billing", ann, @{});
    check(unscoped.status == 403 && [unscoped.headers[@"www-authenticate"] containsString:@"scope=\"Billing.Notify\""], @"app-route-scopes",
          [NSString stringWithFormat:@"%ld %@", (long)unscoped.status, unscoped.headers[@"www-authenticate"]]);

    // The service behind the same sign-in, not asking again.
    OISReply *odataAnonymous = OISSend(@"GET", @"/odata/Products", nil, nil);
    check(odataAnonymous.status == 401, @"app-odata-sign-in", [NSString stringWithFormat:@"%ld %@", (long)odataAnonymous.status, odataAnonymous.text]);
    OISReply *odata = OISSend(@"GET", @"/odata/Products", ann, nil);
    check(odata.status == 200 && [odata.json[@"@odata.context"] isEqual:@"https://api.example.test/odata/$metadata#Products"], @"app-odata",
          [NSString stringWithFormat:@"%ld %@", (long)odata.status, odata.text]);
    OISReply *metadataAgain = OISSend(@"GET", @"/odata/$metadata", ann, nil);
    check(metadataAgain.status == 200 && [metadataAgain.headers[@"x-order"] isEqual:@"a>b><b<a"], @"app-odata-stages", metadataAgain.headers[@"x-order"] ?: @"(none)");

    NSArray *lines;
    @synchronized (application.log) {
      lines = [application.log.lines copy];
    }
    NSString *helloLine = nil;
    for (NSString *line in lines) if ([line containsString:@"\"GET /hello/world\" 200"]) helloLine = line;
    check(helloLine && [helloLine containsString:@" ann "], @"app-access-log", helloLine ?: [lines componentsJoinedByString:@"\n"]);

    [application.server stop];
    printf("%s: %d failure(s)\n", failures ? "FAILED" : "OK", failures);
  }
  return failures ? 1 : 0;
}
