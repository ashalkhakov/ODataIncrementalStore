// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataServerApplication.h"
#import "ODataService.h"
#import "ODataAuthentication.h"
#import "ODataError.h"
#include <dlfcn.h>

NSErrorDomain const ODataServerErrorDomain = @"org.gnu.ois.ODataServer";

static NSError *OISServerError(NSString *message)
{
  return [NSError errorWithDomain:ODataServerErrorDomain code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

static BOOL OISFailWith(NSError **error, NSString *message)
{
  if (error) *error = OISServerError(message);
  return NO;
}

static NSURL *OISURL(id text)
{
  if (![text isKindOfClass:[NSString class]] || ![text length]) return nil;
  return [text rangeOfString:@"://"].location != NSNotFound ? [NSURL URLWithString:text] : [NSURL fileURLWithPath:text];
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

// A store type nothing has registered: a backend's library, by its name
// (CDPostgreSQLStore is libCDPostgreSQLStore), registers it when loaded.
// Not found is not an error here: opening the store says what is wrong.
static void OISLoadBackendFor(NSString *type)
{
  if ([NSPersistentStoreCoordinator registeredStoreTypes][type]) return;
  if ([type rangeOfCharacterFromSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]].location != NSNotFound) return;
#if defined(__APPLE__)
  NSString *library = [NSString stringWithFormat:@"lib%@.dylib", type];
#else
  NSString *library = [NSString stringWithFormat:@"lib%@.so", type];
#endif
  dlopen(library.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
}

#pragma mark - Configuration

@implementation ODataServerConfiguration {
  NSMutableArray<NSString *> *_warnings;
}

- (instancetype)initWithSettings:(NSDictionary *)settings
{
  self = [super init];
  if (!self) return nil;
  _settings = [settings copy] ?: @{};
  _warnings = [NSMutableArray array];
  return self;
}

+ (instancetype)configurationFromCommandLine:(NSError **)error
{
  NSDictionary *arguments = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain];
  return [self configurationWithArguments:arguments environment:[NSProcessInfo processInfo].environment error:error];
}

// Every setting this class reads, for the environment's names of them.
+ (NSArray<NSString *> *)knownSettings
{
  return @[ @"Config", @"Model", @"StoreType", @"StoreURL", @"StoreOptions", @"ServiceRoot", @"Port", @"Localhost", @"MaxBodySize",
            @"MaxPageSize", @"MaxVersion", @"Namespace", @"Container", @"MaxURLLength", @"MaxExpandDepth", @"MaxBatchRequests",
            @"MaxRowsInMemory", @"MaxJSONDepth", @"MaxAsyncRequests", @"ReplyTimeout", @"AsyncResultDuration",
            @"RepeatabilityDuration", @"TrustedUserHeader", @"TrustedClaimHeaders", @"ProxySecretHeader",
            @"ProxySecretEnvironment", @"JWTIssuer", @"JWTAudience", @"JWTKeysURL", @"IntrospectionEndpoint",
            @"IntrospectionClientID", @"IntrospectionSecretEnvironment", @"RequiredScopes", @"AllowAnonymous", @"HealthPath",
            @"AccessLog", @"Bundles", @"Libraries", @"PrintMetadata" ];
}

+ (NSString *)environmentVariableForSetting:(NSString *)name
{
  // A new word at a capital after a small letter (MaxPage), or at the last
  // capital of a run before a small letter (JWTIssuer, MaxURLLength).
  NSMutableString *variable = [NSMutableString stringWithString:@"OIS_"];
  for (NSUInteger i = 0; i < name.length; i++) {
    unichar c = [name characterAtIndex:i];
    BOOL upper = c >= 'A' && c <= 'Z';
    if (upper && i > 0) {
      unichar before = [name characterAtIndex:i - 1];
      unichar after = i + 1 < name.length ? [name characterAtIndex:i + 1] : 0;
      BOOL lowerBefore = (before >= 'a' && before <= 'z') || (before >= '0' && before <= '9');
      BOOL upperBefore = before >= 'A' && before <= 'Z';
      BOOL lowerAfter = after >= 'a' && after <= 'z';
      if (lowerBefore || (upperBefore && lowerAfter)) [variable appendString:@"_"];
    }
    [variable appendFormat:@"%C", (unichar)(upper || !(c >= 'a' && c <= 'z') ? c : c - 32)];
  }
  return variable;
}

// An OIS_ variable not known by name: its words, each capitalized
// (OIS_REPORT_TITLE: ReportTitle), for an application's own settings.
static NSString *OISSettingOfVariable(NSString *variable)
{
  NSMutableString *name = [NSMutableString string];
  for (NSString *word in [[variable substringFromIndex:4] componentsSeparatedByString:@"_"]) {
    if (!word.length) continue;
    [name appendString:[word substringToIndex:1].uppercaseString];
    [name appendString:[word substringFromIndex:1].lowercaseString];
  }
  return name;
}

static id OISEnvironmentValue(NSString *text)
{
  NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if ([trimmed hasPrefix:@"{"] || [trimmed hasPrefix:@"["]) {
    id json = [NSJSONSerialization JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    if (json) return json;
  }
  return text;
}

+ (instancetype)configurationWithArguments:(NSDictionary *)arguments environment:(NSDictionary *)environment error:(NSError **)error
{
  NSMutableDictionary *fromEnvironment = [NSMutableDictionary dictionary];
  NSMutableDictionary *known = [NSMutableDictionary dictionary];
  for (NSString *name in [self knownSettings]) known[[self environmentVariableForSetting:name]] = name;
  for (NSString *variable in environment) {
    if (![variable hasPrefix:@"OIS_"] || variable.length <= 4) continue;
    fromEnvironment[known[variable] ?: OISSettingOfVariable(variable)] = OISEnvironmentValue(environment[variable]);
  }

  NSMutableDictionary *settings = [NSMutableDictionary dictionary];
  NSString *config = arguments[@"Config"] ?: fromEnvironment[@"Config"];
  if (config) {
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:config];
    if (!file) {
      OISFailWith(error, [NSString stringWithFormat:@"%@ is not a property list", config]);
      return nil;
    }
    [settings addEntriesFromDictionary:file];
  }
  [settings addEntriesFromDictionary:fromEnvironment];
  [settings addEntriesFromDictionary:arguments];
  return [[self alloc] initWithSettings:settings];
}

- (id)setting:(NSString *)name
{
  return self.settings[name];
}

- (NSUInteger)count:(NSString *)name
{
  return (NSUInteger)[[self setting:name] integerValue];
}

- (BOOL)flag:(NSString *)name otherwise:(BOOL)otherwise
{
  id value = [self setting:name];
  return value ? [value boolValue] : otherwise;
}

- (NSUInteger)port
{
  id value = [self setting:@"Port"];
  return value ? (NSUInteger)[value integerValue] : 8080;
}

- (BOOL)bindToLocalhost
{
  return [self flag:@"Localhost" otherwise:YES];
}

- (NSUInteger)maxBodySize
{
  id value = [self setting:@"MaxBodySize"];
  return value ? (NSUInteger)[value integerValue] : 64 * 1024 * 1024;
}

// A list of paths: an array, or text, ':' between paths.
- (NSArray<NSString *> *)pathsIn:(NSString *)name
{
  id paths = [self setting:name];
  if ([paths isKindOfClass:[NSString class]]) {
    NSMutableArray *split = [NSMutableArray array];
    for (NSString *path in [paths componentsSeparatedByString:@":"]) {
      if (path.length) [split addObject:path];
    }
    return split;
  }
  return [paths isKindOfClass:[NSArray class]] ? paths : @[];
}

- (NSArray<NSString *> *)bundlePaths
{
  return [self pathsIn:@"Bundles"];
}

- (NSArray<NSString *> *)libraryPaths
{
  return [self pathsIn:@"Libraries"];
}

- (NSString *)healthPath
{
  id path = [self setting:@"HealthPath"];
  return [path isKindOfClass:[NSString class]] ? path : @"/health";
}

- (BOOL)accessLog
{
  return [self flag:@"AccessLog" otherwise:YES];
}

- (BOOL)printsMetadata
{
  return [self flag:@"PrintMetadata" otherwise:NO];
}

- (NSArray<NSString *> *)warnings
{
  return [_warnings copy];
}

// A secret is taken from the environment, not the command line, where
// anyone on the machine can read it.
- (NSString *)secretIn:(NSString *)setting
{
  NSString *variable = [self setting:setting];
  return [variable isKindOfClass:[NSString class]] && variable.length ? [NSProcessInfo processInfo].environment[variable] : nil;
}

- (id<ODataAuthenticator>)authenticatorWithError:(NSError **)error
{
  NSString *userHeader = [self setting:@"TrustedUserHeader"];
  NSString *secretHeader = [self setting:@"ProxySecretHeader"];
  NSString *issuer = [self setting:@"JWTIssuer"];
  NSString *introspection = [self setting:@"IntrospectionEndpoint"];
  if ((userHeader.length > 0) + (issuer.length > 0) + (introspection.length > 0) > 1) {
    OISFailWith(error, @"one of -TrustedUserHeader, -JWTIssuer and -IntrospectionEndpoint: who is asking is known one way");
    return nil;
  }
  if (secretHeader.length && !userHeader.length) {
    OISFailWith(error, @"-ProxySecretHeader without -TrustedUserHeader: name the header the proxy puts the user in");
    return nil;
  }
  id scopes = [self setting:@"RequiredScopes"];
  if ([scopes isKindOfClass:[NSString class]]) scopes = [scopes componentsSeparatedByString:@" "];
  NSSet *requiredScopes = [scopes isKindOfClass:[NSArray class]] ? [NSSet setWithArray:scopes] : nil;

  if (userHeader.length) {
    ODataTrustedHeaderAuthenticator *proxy = [[ODataTrustedHeaderAuthenticator alloc] initWithSubjectHeader:userHeader];
    if ([[self setting:@"TrustedClaimHeaders"] isKindOfClass:[NSDictionary class]]) proxy.claimHeaders = [self setting:@"TrustedClaimHeaders"];
    if (secretHeader.length) {
      NSString *secret = [self secretIn:@"ProxySecretEnvironment"];
      if (!secret.length) {
        OISFailWith(error, @"-ProxySecretHeader needs the secret in the environment variable -ProxySecretEnvironment names");
        return nil;
      }
      proxy.secretHeader = secretHeader;
      proxy.secret = secret;
    } else if (!self.bindToLocalhost) {
      [_warnings addObject:[NSString stringWithFormat:@"anyone who reaches port %lu can send %@; set -ProxySecretHeader, or listen on loopback",
                                                      (unsigned long)self.port, userHeader]];
    }
    return proxy;
  }
  if (issuer.length) {
    NSString *audience = [self setting:@"JWTAudience"];
    ODataJWTAuthenticator *jwt = [[ODataJWTAuthenticator alloc] initWithIssuer:issuer audience:audience];
    if (!audience) [_warnings addObject:[NSString stringWithFormat:@"no -JWTAudience: a token %@ issued for anything is taken", issuer]];
    if ([self setting:@"JWTKeysURL"]) jwt.keySetURL = OISURL([self setting:@"JWTKeysURL"]);
    jwt.requiredScopes = requiredScopes;
    return jwt;
  }
  if (introspection.length) {
    NSString *secret = [self secretIn:@"IntrospectionSecretEnvironment"];
    NSString *client = [self setting:@"IntrospectionClientID"];
    if (!client.length || !secret.length) {
      OISFailWith(error, @"-IntrospectionEndpoint needs -IntrospectionClientID, and the secret in the environment variable "
                         @"-IntrospectionSecretEnvironment names");
      return nil;
    }
    ODataTokenIntrospectionAuthenticator *introspector =
      [[ODataTokenIntrospectionAuthenticator alloc] initWithEndpoint:OISURL(introspection) clientID:client clientSecret:secret];
    introspector.requiredScopes = requiredScopes;
    return introspector;
  }
  if (error) *error = nil;
  return nil;
}

- (ODataService *)serviceWithAuthenticator:(id<ODataAuthenticator>)authenticator error:(NSError **)error
{
  NSString *modelPath = [self setting:@"Model"];
  if (!modelPath) {
    OISFailWith(error, @"no -Model: give the compiled model, or a -Config that names it");
    return nil;
  }
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:OISURL(modelPath)];
  if (!model.entities.count) {
    OISFailWith(error, [NSString stringWithFormat:@"%@ is not a model", modelPath]);
    return nil;
  }
  for (NSString *path in self.libraryPaths) {
    if (!dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
      const char *why = dlerror();
      OISFailWith(error, [NSString stringWithFormat:@"%@ does not load: %s", path, why ? why : "?"]);
      return nil;
    }
  }
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSString *type = OISStoreType([self setting:@"StoreType"] ?: @"InMemory");
  OISLoadBackendFor(type);
  NSURL *storeURL = OISURL([self setting:@"StoreURL"]);
  NSError *failure = nil;
  if (![coordinator addPersistentStoreWithType:type configuration:nil URL:storeURL options:[self setting:@"StoreOptions"] error:&failure]) {
    OISFailWith(error, [NSString stringWithFormat:@"the %@ store at %@ does not open: %@", type, storeURL ?: @"(none)", failure.localizedDescription]);
    return nil;
  }

  NSURL *root = OISURL([self setting:@"ServiceRoot"])
      ?: [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%lu/odata/", (unsigned long)self.port]];
  ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator serviceRoot:root];
  if ([self setting:@"Namespace"]) service.namespaceName = [self setting:@"Namespace"];
  if ([self setting:@"Container"]) service.containerName = [self setting:@"Container"];
  if ([self setting:@"MaxVersion"]) service.maxVersion = [self setting:@"MaxVersion"];
  // What one request may ask (ODataService.h): each a number, 0 for none.
  if ([self setting:@"MaxPageSize"]) service.maxPageSize = [self count:@"MaxPageSize"];
  if ([self setting:@"MaxURLLength"]) service.maxURLLength = [self count:@"MaxURLLength"];
  if ([self setting:@"MaxExpandDepth"]) service.maxExpandDepth = [self count:@"MaxExpandDepth"];
  if ([self setting:@"MaxBatchRequests"]) service.maxBatchRequests = [self count:@"MaxBatchRequests"];
  if ([self setting:@"MaxRowsInMemory"]) service.maxRowsInMemory = [self count:@"MaxRowsInMemory"];
  if ([self setting:@"MaxJSONDepth"]) service.maxJSONDepth = [self count:@"MaxJSONDepth"];
  if ([self setting:@"MaxAsyncRequests"]) service.maxAsyncRequests = [self count:@"MaxAsyncRequests"];
  if ([self setting:@"ReplyTimeout"]) service.replyTimeout = [[self setting:@"ReplyTimeout"] doubleValue];
  if ([self setting:@"AsyncResultDuration"]) service.asyncResultDuration = [[self setting:@"AsyncResultDuration"] doubleValue];
  if ([self setting:@"RepeatabilityDuration"]) service.repeatabilityDuration = [[self setting:@"RepeatabilityDuration"] doubleValue];
  service.authenticator = authenticator;
  if ([self setting:@"AllowAnonymous"]) service.allowsAnonymousRequests = [[self setting:@"AllowAnonymous"] boolValue];
  return service;
}

@end

#pragma mark - The application

@interface ODataServerApplication ()
@property (nonatomic, readwrite, strong, nullable) id<ODataAuthenticator> authenticator;
@property (nonatomic, readwrite, strong, nullable) ODataService *service;
@property (nonatomic, readwrite, strong, nullable) ODataServerRouter *router;
@property (nonatomic, readwrite, strong, nullable) ODataServerPipeline *pipeline;
@property (nonatomic, readwrite, strong, nullable) ODataHTTPServer *server;
// Principal classes of bundles that configure the service (ODataServerMain).
@property (nonatomic, copy) NSArray<Class> *serviceConfigurers;
@end

@implementation ODataServerApplication

- (instancetype)initWithConfiguration:(ODataServerConfiguration *)configuration
{
  self = [super init];
  if (!self) return nil;
  _configuration = configuration;
  _serviceConfigurers = @[];
  return self;
}

- (void)configureService:(ODataService *)service
{
}

- (void)configureRouter:(ODataServerRouter *)router
{
}

- (void)configurePipeline:(ODataServerPipeline *)pipeline
{
}

- (void)configureServer:(ODataHTTPServer *)server
{
}

- (BOOL)prepare:(NSError **)error
{
  if (self.server) return YES;
  ODataServerConfiguration *configuration = self.configuration;
  NSError *failure = nil;
  id<ODataAuthenticator> authenticator = [configuration authenticatorWithError:&failure];
  if (failure) {
    if (error) *error = failure;
    return NO;
  }
  self.authenticator = authenticator;

  ODataService *service = [configuration serviceWithAuthenticator:authenticator error:error];
  if (!service) return NO;
  self.service = service;
  [self configureService:service];
  for (Class configurer in self.serviceConfigurers) [(id<ODataServiceConfiguring>)configurer configureService:service];
  // An operation that cannot be declared would answer 404 until someone
  // noticed: better not to start.
  if (service.operationProblems.count) {
    return OISFailWith(error, [NSString stringWithFormat:@"the service cannot declare these operations; fix them, or leave them out:\n  %@",
                                                         [service.operationProblems componentsJoinedByString:@"\n  "]]);
  }

  ODataServerRouter *router = [[ODataServerRouter alloc] init];
  if (configuration.healthPath.length) {
    [router addRoute:[ODataServerRoute routeWithMethod:@"GET" path:configuration.healthPath handler:[[ODataHealthHandler alloc] init]]];
  }
  NSString *root = service.serviceRoot.path.length ? service.serviceRoot.path : @"/";
  [router addRoute:[ODataServerRoute routeWithMethod:nil path:[root stringByAppendingPathComponent:@"*"]
                                           handler:[[ODataServiceHandler alloc] initWithService:service]]];
  self.router = router;
  [self configureRouter:router];

  NSMutableArray *stages = [NSMutableArray arrayWithObject:[[ODataRequestIDStage alloc] init]];
  if (configuration.accessLog) [stages addObject:[[ODataAccessLogStage alloc] init]];
  if (authenticator) [stages addObject:[[ODataAuthenticationStage alloc] initWithAuthenticator:authenticator]];
  ODataServerPipeline *pipeline = [[ODataServerPipeline alloc] initWithStages:stages handler:router];
  self.pipeline = pipeline;
  [self configurePipeline:pipeline];

  ODataHTTPServer *server = [[ODataHTTPServer alloc] initWithHandler:pipeline];
  server.bindToLocalhost = configuration.bindToLocalhost;
  server.maxBodySize = configuration.maxBodySize;
  self.server = server;
  [self configureServer:server];
  return YES;
}

- (int)run
{
  NSString *name = [NSProcessInfo processInfo].processName;
  NSError *error = nil;
  if (![self prepare:&error]) {
    fprintf(stderr, "%s: %s\n", name.UTF8String, error.localizedDescription.UTF8String);
    return 1;
  }
  ODataService *service = self.service;
  if (self.configuration.printsMetadata) {
    printf("%s\n", [service metadataXMLForVersion:service.maxVersion].UTF8String);
    return 0;
  }
  for (NSString *warning in self.configuration.warnings) fprintf(stderr, "%s: warning: %s\n", name.UTF8String, warning.UTF8String);
  for (NSString *problem in service.metadataProblems) fprintf(stderr, "%s: $metadata: %s\n", name.UTF8String, problem.UTF8String);
  NSUInteger port = self.configuration.port;
  fprintf(stderr, "%s: %s on port %lu%s, %lu entity sets\n", name.UTF8String, service.serviceRoot.absoluteString.UTF8String,
          (unsigned long)port, self.server.bindToLocalhost ? " (loopback)" : "", (unsigned long)service.entitySets.count);
  if (![self.server runOnPort:port error:&error]) {
    fprintf(stderr, "%s: cannot listen on %lu: %s\n", name.UTF8String, (unsigned long)port, error.localizedDescription.UTF8String);
    return 1;
  }
  fprintf(stderr, "%s: stopped\n", name.UTF8String);
  return 0;
}

@end

int ODataServerMain(int argc, const char *argv[], Class applicationClass)
{
  @autoreleasepool {
    NSString *name = [NSProcessInfo processInfo].processName;
    NSError *error = nil;
    ODataServerConfiguration *configuration = [ODataServerConfiguration configurationFromCommandLine:&error];
    if (!configuration) {
      fprintf(stderr, "%s: %s\n", name.UTF8String, error.localizedDescription.UTF8String);
      return 1;
    }
    // Backends and the application's own code, before the store is opened.
    Class chosen = applicationClass ?: [ODataServerApplication class];
    NSMutableArray<Class> *configurers = [NSMutableArray array];
    for (NSString *path in configuration.bundlePaths) {
      NSBundle *bundle = [NSBundle bundleWithPath:path];
      if (![bundle loadAndReturnError:&error]) {
        fprintf(stderr, "%s: %s does not load: %s\n", name.UTF8String, path.UTF8String, error.localizedDescription.UTF8String);
        return 1;
      }
      Class principal = bundle.principalClass;
      if ([principal isSubclassOfClass:[ODataServerApplication class]] && principal != [ODataServerApplication class]) {
        if (chosen != [ODataServerApplication class] && chosen != principal) {
          fprintf(stderr, "%s: %s is an application too, and there is one already (%s)\n", name.UTF8String, path.UTF8String,
                  NSStringFromClass(chosen).UTF8String);
          return 1;
        }
        chosen = principal;
      } else if ([principal conformsToProtocol:@protocol(ODataServiceConfiguring)]) {
        [configurers addObject:principal];
      }
    }
    ODataServerApplication *application = [[chosen alloc] initWithConfiguration:configuration];
    application.serviceConfigurers = configurers;
    return [application run];
  }
}
