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
//   Bundles       paths of bundles to load; a principal class that
//                 conforms to ODataServiceConfiguring is sent
//                 +configureService: before the first request, to register
//                 handlers and set serviceOperations; an operation the
//                 service cannot declare stops it from starting
//   PrintMetadata YES: write $metadata to standard output and exit
//
// It serves until SIGINT or SIGTERM, logs to standard error, and exits 0
// on a clean stop, 1 on a configuration it cannot use.

#import "ODataIncrementalStore.h"
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
    fprintf(stderr, "ois-serve: %s on port %lu%s, %lu entity sets\n", root.absoluteString.UTF8String, (unsigned long)port,
            server.bindToLocalhost ? " (loopback)" : "", (unsigned long)service.entitySets.count);
    if (![server runOnPort:port error:&error]) OISFail([NSString stringWithFormat:@"cannot listen on %lu: %@", (unsigned long)port, error.localizedDescription]);
    fprintf(stderr, "ois-serve: stopped\n");
  }
  return 0;
}
