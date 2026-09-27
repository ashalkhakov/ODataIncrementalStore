// ois-serve — a Core Data store served over OData.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   ois-serve -Config service.plist
//   ois-serve -Model Catalog.momd -StoreType SQLite -StoreURL file:///var/lib/catalog.sqlite \
//             -ServiceRoot https://api.example.com/odata/ -Port 8080
//
// Settings come from the property list -Config names, and any of them can
// be given on the command line instead, which wins:
//
//   Model         the compiled model (.momd, .mom; on GNUstep an
//                 .xcdatamodeld too)
//   StoreType     SQLite, InMemory, XML, Binary (Apple only), or a store type a linked
//                 or loaded backend registers (CDPostgreSQLStore, ...)
//   StoreURL      the store's URL; a plain path is a file
//   StoreOptions  a dictionary, handed to the coordinator as it is
//   ServiceRoot   the public URL of the service, which its links begin with
//                 (default http://127.0.0.1:<Port>/odata/)
//   Port          default 8080
//   Localhost     YES (the default): listen on loopback only, for a proxy
//                 on the same machine
//   MaxPageSize   server-driven paging, 0 for none
//   MaxVersion    4.01 (default) or 4.0
//   Namespace, Container   the names $metadata gives the schema
//   TrustedUserHeader   who is asking, from this header the proxy sets once
//                 it has signed them in with the identity provider
//                 (X-Forwarded-User from oauth2-proxy, Remote-User from
//                 Authelia); a request without it is answered 401. Unset
//                 (the default): no one is asked. See ODataAuthentication.h
//   TrustedClaimHeaders   a dictionary, claim name to header (default:
//                 email, preferred_username, groups from X-Forwarded-*)
//   ProxySecretHeader, ProxySecretEnvironment   a header the proxy adds,
//                 and the environment variable holding the secret it
//                 carries: a request without it did not come through the
//                 proxy
//   JWTIssuer, JWTAudience   instead of a proxy: who is asking, from the
//                 access token the client sends (Authorization: Bearer), a
//                 JWT from this issuer (as its iss has it) for this
//                 audience, checked with the keys the issuer's discovery
//                 document names
//   JWTKeysURL    the issuer's JWK Set, when discovery is not to be used
//   IntrospectionEndpoint, IntrospectionClientID,
//   IntrospectionSecretEnvironment   or: any access token, checked by
//                 asking the provider (RFC 7662) as this client, its secret
//                 in the environment variable named
//   RequiredScopes  scopes every token needs (JWT or introspection)
//   AllowAnonymous  YES: a request that names no one is answered too, as
//                 no one's
//   Bundles       paths of bundles to load; a principal class that
//                 conforms to ODataServiceConfiguring is sent
//                 +configureService: before the first request, to register
//                 handlers and set serviceOperations; an operation the
//                 service cannot declare stops it from starting
//   PrintMetadata YES: write $metadata to standard output and exit
//
// It serves until SIGINT or SIGTERM, logs to standard error, and exits 0
// on a clean stop, 1 on a configuration it cannot use.

#import "ODataService.h"
#import "ODataHTTPServer.h"

static void OISFail(NSString *message)
{
  fprintf(stderr, "ois-serve: %s\n", message.UTF8String);
  exit(1);
}

static NSDictionary *OISSettings(void)
{
  NSMutableDictionary *settings = [NSMutableDictionary dictionary];
  NSDictionary *arguments = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain];
  NSString *config = arguments[@"Config"];
  if (config) {
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:config];
    if (!file) OISFail([NSString stringWithFormat:@"%@ is not a property list", config]);
    [settings addEntriesFromDictionary:file];
  }
  [settings addEntriesFromDictionary:arguments];
  return settings;
}

static NSString *OISStoreType(NSString *name)
{
  NSMutableDictionary *known = [@{ @"SQLite": NSSQLiteStoreType, @"InMemory": NSInMemoryStoreType,
                                   @"XML": NSXMLStoreType } mutableCopy];
#if defined(__APPLE__)
  known[@"Binary"] = NSBinaryStoreType;  // FreeCoreData has none
#endif
  return known[name] ?: name;
}

static NSURL *OISURL(NSString *text)
{
  if (!text.length) return nil;
  return [text rangeOfString:@"://"].location != NSNotFound ? [NSURL URLWithString:text] : [NSURL fileURLWithPath:text];
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSDictionary *settings = OISSettings();
    NSString *modelPath = settings[@"Model"];
    if (!modelPath) OISFail(@"no -Model: give the compiled model, or a -Config that names it");
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:OISURL(modelPath)];
    if (!model.entities.count) OISFail([NSString stringWithFormat:@"%@ is not a model", modelPath]);

    // Backends and the application's own code, before the store is opened.
    NSMutableArray<Class> *configurers = [NSMutableArray array];
    id bundles = settings[@"Bundles"];
    if ([bundles isKindOfClass:[NSString class]]) bundles = @[ bundles ];
    for (NSString *path in bundles) {
      NSBundle *bundle = [NSBundle bundleWithPath:path];
      NSError *error = nil;
      if (![bundle loadAndReturnError:&error]) OISFail([NSString stringWithFormat:@"%@ does not load: %@", path, error.localizedDescription]);
      Class principal = bundle.principalClass;
      if ([principal conformsToProtocol:@protocol(ODataServiceConfiguring)]) [configurers addObject:principal];
    }

    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSString *type = OISStoreType(settings[@"StoreType"] ?: @"InMemory");
    NSURL *storeURL = OISURL(settings[@"StoreURL"]);
    NSError *error = nil;
    if (![coordinator addPersistentStoreWithType:type configuration:nil URL:storeURL options:settings[@"StoreOptions"] error:&error]) {
      OISFail([NSString stringWithFormat:@"the %@ store at %@ does not open: %@", type, storeURL ?: @"(none)", error.localizedDescription]);
    }

    NSUInteger port = settings[@"Port"] ? (NSUInteger)[settings[@"Port"] integerValue] : 8080;
    NSURL *root = OISURL(settings[@"ServiceRoot"]) ?: [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%lu/odata/", (unsigned long)port]];
    ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator serviceRoot:root];
    if (settings[@"Namespace"]) service.namespaceName = settings[@"Namespace"];
    if (settings[@"Container"]) service.containerName = settings[@"Container"];
    if (settings[@"MaxVersion"]) service.maxVersion = settings[@"MaxVersion"];
    if (settings[@"MaxPageSize"]) service.maxPageSize = (NSUInteger)[settings[@"MaxPageSize"] integerValue];
    NSString *userHeader = settings[@"TrustedUserHeader"];
    NSString *secretHeader = settings[@"ProxySecretHeader"];
    if (userHeader.length) {
      ODataTrustedHeaderAuthenticator *proxy = [[ODataTrustedHeaderAuthenticator alloc] initWithSubjectHeader:userHeader];
      if ([settings[@"TrustedClaimHeaders"] isKindOfClass:[NSDictionary class]]) proxy.claimHeaders = settings[@"TrustedClaimHeaders"];
      if (secretHeader.length) {
        // From the environment, not the command line, where anyone on the
        // machine can read it.
        NSString *variable = settings[@"ProxySecretEnvironment"];
        NSString *secret = variable.length ? [NSProcessInfo processInfo].environment[variable] : nil;
        if (!secret.length) OISFail(@"-ProxySecretHeader needs the secret in the environment variable -ProxySecretEnvironment names");
        proxy.secretHeader = secretHeader;
        proxy.secret = secret;
      }
      service.authenticator = proxy;
    } else if (secretHeader.length) {
      OISFail(@"-ProxySecretHeader without -TrustedUserHeader: name the header the proxy puts the user in");
    }
    NSString *issuer = settings[@"JWTIssuer"];
    NSString *introspection = settings[@"IntrospectionEndpoint"];
    if ((userHeader.length > 0) + (issuer.length > 0) + (introspection.length > 0) > 1) {
      OISFail(@"one of -TrustedUserHeader, -JWTIssuer and -IntrospectionEndpoint: who is asking is known one way");
    }
    id scopes = settings[@"RequiredScopes"];
    if ([scopes isKindOfClass:[NSString class]]) scopes = [scopes componentsSeparatedByString:@" "];
    NSSet *requiredScopes = [scopes isKindOfClass:[NSArray class]] ? [NSSet setWithArray:scopes] : nil;
    if (issuer.length) {
      ODataJWTAuthenticator *jwt = [[ODataJWTAuthenticator alloc] initWithIssuer:issuer audience:settings[@"JWTAudience"]];
      if (!settings[@"JWTAudience"]) fprintf(stderr, "ois-serve: warning: no -JWTAudience: a token %s issued for anything is taken\n", issuer.UTF8String);
      if (settings[@"JWTKeysURL"]) jwt.keySetURL = OISURL(settings[@"JWTKeysURL"]);
      jwt.requiredScopes = requiredScopes;
      service.authenticator = jwt;
    }
    if (introspection.length) {
      NSString *variable = settings[@"IntrospectionSecretEnvironment"];
      NSString *secret = variable.length ? [NSProcessInfo processInfo].environment[variable] : nil;
      NSString *client = settings[@"IntrospectionClientID"];
      if (!client.length || !secret.length) {
        OISFail(@"-IntrospectionEndpoint needs -IntrospectionClientID, and the secret in the environment variable -IntrospectionSecretEnvironment names");
      }
      ODataTokenIntrospectionAuthenticator *introspector =
        [[ODataTokenIntrospectionAuthenticator alloc] initWithEndpoint:OISURL(introspection) clientID:client clientSecret:secret];
      introspector.requiredScopes = requiredScopes;
      service.authenticator = introspector;
    }
    if (settings[@"AllowAnonymous"]) service.allowsAnonymousRequests = [settings[@"AllowAnonymous"] boolValue];
    for (Class configurer in configurers) [(id<ODataServiceConfiguring>)configurer configureService:service];

    if ([settings[@"PrintMetadata"] boolValue]) {
      printf("%s\n", [service metadataXMLForVersion:service.maxVersion].UTF8String);
      return 0;
    }
    for (NSString *problem in service.metadataProblems) fprintf(stderr, "ois-serve: $metadata: %s\n", problem.UTF8String);
    // An operation that cannot be declared would answer 404 until someone
    // noticed; better not to start.
    for (NSString *problem in service.operationProblems) fprintf(stderr, "ois-serve: operation: %s\n", problem.UTF8String);
    if (service.operationProblems.count) OISFail(@"fix the operations above, or leave them out of the bundle");

    ODataHTTPServer *server = [[ODataHTTPServer alloc] initWithService:service];
    id localhost = settings[@"Localhost"];
    server.bindToLocalhost = localhost ? [localhost boolValue] : YES;
    if (userHeader.length && !server.bindToLocalhost && !secretHeader.length) {
      fprintf(stderr, "ois-serve: warning: anyone who reaches port %lu can send %s; set -ProxySecretHeader, or listen on loopback\n",
              (unsigned long)port, userHeader.UTF8String);
    }
    fprintf(stderr, "ois-serve: %s on port %lu%s, %lu entity sets\n", root.absoluteString.UTF8String, (unsigned long)port,
            server.bindToLocalhost ? " (loopback)" : "", (unsigned long)service.entitySets.count);
    if (![server runOnPort:port error:&error]) OISFail([NSString stringWithFormat:@"cannot listen on %lu: %@", (unsigned long)port, error.localizedDescription]);
    fprintf(stderr, "ois-serve: stopped\n");
  }
  return 0;
}
