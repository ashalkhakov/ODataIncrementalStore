// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataService.h"
#import "ODataAuthentication.h"
#import "ODataError.h"
#import "ODataValue.h"
#import "ODataSchema.h"
#import "ODataMetadataWriter.h"
#import "ODataPredicateBuilder.h"
#import "ODataOperationCatalog.h"
#import "ODataServiceBatch.h"

NSString * const ODataUserInfoETag = @"OData.etag";

#pragma mark - Replies

@interface ODataReply ()
@property (nonatomic, strong, nullable) id target;
@property (nonatomic) SEL action;
@property (nonatomic, strong, nullable) NSManagedObjectContext *context;
@property (nonatomic, readwrite) BOOL deferred;
@property (nonatomic, readwrite) BOOL finished;
@property (nonatomic, readwrite, strong, nullable) id result;
@property (nonatomic, readwrite, strong, nullable) NSError *error;
@property (nonatomic) BOOL fired;
@property (nonatomic, readwrite, weak, nullable) ODataRequest *request;
@property (nonatomic) NSTimeInterval timeout;
@end

@implementation ODataReply

- (instancetype)initWithTarget:(id)target action:(SEL)action context:(NSManagedObjectContext *)context
{
  self = [super init];
  if (!self) return nil;
  _target = target;
  _action = action;
  _context = context;
  return self;
}

- (void)defer
{
  @synchronized (self) {
    if (self.deferred) return;
    self.deferred = YES;
  }
  if (self.timeout <= 0) return;
  // The timer keeps the reply: a handler that drops it must still be
  // answered for.
  ODataReply *reply = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.timeout * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
    [reply failWithError:ODataServiceError(504, @"The service took too long to answer")];
  });
}

// The first answer counts. A deferred one goes on in the request's context.
- (void)finishWithResult:(id)result error:(NSError *)error
{
  BOOL later;
  @synchronized (self) {
    if (self.finished) return;
    self.finished = YES;
    self.result = result;
    self.error = error;
    later = self.deferred;
  }
  if (later) {
    NSManagedObjectContext *context = self.context;
    [context performBlock:^{
      [self fire];
    }];
  }
}

- (void)finishWithResult:(id)result
{
  [self finishWithResult:result error:nil];
}

- (void)failWithError:(NSError *)error
{
  [self finishWithResult:nil error:error ?: ODataServiceError(500, @"The request failed")];
}

// The handler method has returned this.
- (void)returned:(id)value
{
  BOOL now;
  @synchronized (self) {
    now = !self.deferred;
    if (now && !self.finished) {
      self.finished = YES;
      self.result = value;
    }
  }
  if (now) [self fire];
}

- (void)fire
{
  id target;
  @synchronized (self) {
    if (self.fired) return;
    self.fired = YES;
    target = self.target;
    self.target = nil;
  }
  void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:self.action];
  send(target, self.action, self);
}

@end

#pragma mark - Requests

@interface ODataRequest ()
@property (nonatomic, readwrite, weak) ODataService *service;
@property (nonatomic, readwrite) NSURLRequest *URLRequest;
@property (nonatomic, readwrite, copy) NSString *method;
@property (nonatomic, readwrite, strong) ODataResourcePath *path;
@property (nonatomic, readwrite, strong) ODataQueryOptions *options;
@property (nonatomic, readwrite, strong, nullable) NSEntityDescription *entity;
@property (nonatomic, readwrite, strong) NSManagedObjectContext *context;
@property (nonatomic, readwrite, copy) NSString *version;
@property (nonatomic, readwrite, copy) NSDictionary *preferences;
@property (nonatomic, readwrite, strong) NSMutableDictionary *userInfo;
@property (nonatomic, readwrite, strong, nullable) NSFetchRequest *collectionFetchRequest;
@property (nonatomic, readwrite, strong, nullable) ODataPrincipal *principal;
@end

@implementation ODataRequest

- (instancetype)initWithURLRequest:(NSURLRequest *)request
{
  self = [super init];
  if (!self) return nil;
  _URLRequest = request;
  _method = (request.HTTPMethod ?: @"GET").uppercaseString;
  _userInfo = [NSMutableDictionary dictionary];
  _preferences = @{};
  _version = @"4.01";
  return self;
}

- (NSString *)valueForHeader:(NSString *)name
{
  NSDictionary *headers = self.URLRequest.allHTTPHeaderFields;
  for (NSString *key in headers) {
    if ([key caseInsensitiveCompare:name] == NSOrderedSame) return headers[key];
  }
  return nil;
}

@end

#pragma mark - Entity set handlers

@interface ODataEntitySetHandler ()
@property (nonatomic, readwrite, weak, nullable) ODataService *service;
@end

@implementation ODataEntitySetHandler

- (instancetype)initWithEntity:(NSEntityDescription *)entity
{
  self = [super init];
  if (!self) return nil;
  _entity = entity;
  _allowsInsert = YES;
  _allowsUpdate = YES;
  _allowsDelete = YES;
  return self;
}

- (NSPredicate *)predicateForVisibleObjectsInRequest:(ODataRequest *)request
{
  return nil;
}

- (NSArray *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSError *error = nil;
  NSArray *objects = [request.context executeFetchRequest:fetchRequest error:&error];
  if (!objects) [reply failWithError:error];
  return objects;
}

- (NSNumber *)countForFetchRequest:(NSFetchRequest *)fetchRequest request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSError *error = nil;
  NSUInteger count = [request.context countForFetchRequest:fetchRequest error:&error];
  if (count == NSNotFound) {
    [reply failWithError:error];
    return nil;
  }
  return @(count);
}

- (NSManagedObject *)objectWithKey:(NSDictionary *)key request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *name in key) {
    [parts addObject:[NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:name]
                                                        rightExpression:[NSExpression expressionForConstantValue:key[name]]
                                                               modifier:NSDirectPredicateModifier
                                                                   type:NSEqualToPredicateOperatorType
                                                                options:0]];
  }
  NSPredicate *visible = [self predicateForVisibleObjectsInRequest:request];
  if (visible) [parts addObject:visible];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:parts];
  fetch.fetchLimit = 1;
  NSError *error = nil;
  NSArray *found = [request.context executeFetchRequest:fetch error:&error];
  if (!found) [reply failWithError:error];
  return found.firstObject;
}

- (void)applyValues:(NSDictionary *)values to:(NSManagedObject *)object
{
  for (NSString *name in values) {
    id value = values[name];
    [object setValue:value == [NSNull null] ? nil : value forKey:name];
  }
}

- (NSManagedObject *)insertObjectWithValues:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  NSManagedObject *object = [[NSManagedObject alloc] initWithEntity:request.entity ?: self.entity
                                     insertIntoManagedObjectContext:request.context];
  [self applyValues:values to:object];
  return object;
}

- (NSManagedObject *)updateObject:(NSManagedObject *)object values:(NSDictionary *)values request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [self applyValues:values to:object];
  return object;
}

- (void)deleteObject:(NSManagedObject *)object request:(ODataRequest *)request reply:(ODataReply *)reply
{
  [request.context deleteObject:object];
}

@end

#pragma mark - The service's own state

@interface ODataService ()
- (void)prepare;
@property (nonatomic, strong) ODataPredicateBuilder *predicates;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ODataEntitySetHandler *> *handlers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *metadataByVersion;
@property (nonatomic, strong) ODataMetadataWriter *writer;
@property (nonatomic, strong) OISOperationCatalog *catalog;
@property (nonatomic) BOOL prepared;
- (ODataEntitySetHandler *)handlerForEntity:(NSEntityDescription *)entity;
- (NSString *)entitySetForEntity:(NSEntityDescription *)entity;
- (NSAttributeDescription *)versionAttributeOfEntity:(NSEntityDescription *)entity;
@end

static NSEntityDescription *OISRootEntity(NSEntityDescription *entity)
{
  while (entity.superentity) entity = entity.superentity;
  return entity;
}

static NSString *OISPercentDecoded(NSString *text)
{
  return [text stringByRemovingPercentEncoding] ?: text;
}

typedef NS_ENUM(NSInteger, OISTargetKind) {
  OISTargetServiceDocument,
  OISTargetMetadata,
  OISTargetCollection,
  OISTargetEntity,
  OISTargetProperty,
  OISTargetValue,
  OISTargetCount,
  OISTargetOperation,
  OISTargetReference
};

#pragma mark - One call

// One request, from the URL to the response. Each step that asks a handler
// for something goes on in the method its reply names.
@interface OISServiceCall : NSObject
@property (nonatomic, strong) ODataService *service;
@property (nonatomic, strong) ODataExchange *exchange;
@property (nonatomic, strong) ODataRequest *request;
@property (nonatomic, strong) ODataValueCoder *coder;
@property (nonatomic, copy) NSString *metadataLevel;  // minimal, full, none
@property (nonatomic, copy) NSString *resourcePath;   // as the request wrote it, decoded
@property (nonatomic) BOOL headOnly;
@property (nonatomic) BOOL done;

// Where the path leads.
@property (nonatomic) OISTargetKind kind;
@property (nonatomic) NSUInteger index;
@property (nonatomic, strong) NSEntityDescription *entity;
@property (nonatomic, strong) ODataEntitySetHandler *handler;
@property (nonatomic, strong, nullable) NSManagedObject *object;
@property (nonatomic, strong, nullable) NSManagedObject *parent;
@property (nonatomic, strong, nullable) NSRelationshipDescription *navigation;
@property (nonatomic, strong, nullable) NSAttributeDescription *attribute;
@property (nonatomic, strong, nullable) OISServedOperation *operation;
// How the entity in hand was reached, when through a navigation property:
// what $ref after it refers to.
@property (nonatomic, strong, nullable) NSManagedObject *referrer;
@property (nonatomic, strong, nullable) NSRelationshipDescription *referrerNavigation;
// $id: the entity a DELETE of a collection's $ref removes.
@property (nonatomic, copy, nullable) NSString *referenceID;
@property (nonatomic) BOOL referencesCollection;  // Categories(1)/Products/$ref, Products/$ref
@property (nonatomic) BOOL referencesOnly;        // a collection read as references
// The entities a function returned, read on as a collection.
@property (nonatomic, copy, nullable) NSArray<NSManagedObject *> *members;
// A deep insert's response: the entity with what it created expanded.
@property (nonatomic, strong, nullable) ODataQueryOptions *responseOptions;
// A nested insert's answer, taken at once.
@property (nonatomic, strong, nullable) ODataReply *nestedReply;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, ODataExpression *> *operationArguments;
// Parameter aliases whose values are JSON (@p=[...], @p={...}): an
// operation's complex and collection arguments.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *JSONAliases;

// A read in progress.
@property (nonatomic, strong, nullable) NSFetchRequest *fetch;
@property (nonatomic, strong, nullable) NSArray *objects;
@property (nonatomic, strong, nullable) NSNumber *count;
@property (nonatomic, copy, nullable) NSString *nextLink;
@property (nonatomic) NSUInteger pageSize;
@property (nonatomic) NSUInteger skipToken;
@property (nonatomic) BOOL pagedByPreference;

// A write in progress.
@property (nonatomic) BOOL replace;
// NO in a change set: its requests share a context, saved once they have
// all succeeded.
@property (nonatomic) BOOL saves;
// Who is asking is known: the authenticator has answered, or a batch
// the request is part of has been authenticated.
@property (nonatomic) BOOL authenticated;
@end

@implementation OISServiceCall

- (ODataPropertyMapper *)mapper
{
  return self.service.mapper;
}

- (ODataReply *)replyWithAction:(SEL)action
{
  ODataReply *reply = [[ODataReply alloc] initWithTarget:self action:action context:self.request.context];
  reply.request = self.request;
  reply.timeout = self.service.replyTimeout;
  return reply;
}

#pragma mark Responses

- (void)respondStatus:(NSInteger)status headers:(NSDictionary *)headers body:(NSData *)body
{
  if (self.done) return;
  self.done = YES;
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
  all[@"OData-Version"] = self.request.version ?: @"4.01";
  NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.exchange.request.URL
                                                            statusCode:status
                                                           HTTPVersion:@"HTTP/1.1"
                                                          headerFields:all];
  self.exchange.URLResponse = response;
  self.exchange.data = self.headOnly ? [NSData data] : (body ?: [NSData data]);
  [self.exchange finish];
}

- (NSString *)JSONContentType
{
  return [NSString stringWithFormat:@"application/json;odata.metadata=%@;odata.streaming=true;IEEE754Compatible=%@;charset=utf-8",
          self.metadataLevel ?: @"minimal", self.coder.IEEE754Compatible ? @"true" : @"false"];
}

- (void)respondJSON:(id)json status:(NSInteger)status headers:(NSDictionary *)headers
{
  NSError *error = nil;
  NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
  if (!data) {
    [self respondError:ODataServiceError(500, [NSString stringWithFormat:@"The response could not be written: %@", error.localizedDescription])];
    return;
  }
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
  all[@"Content-Type"] = [self JSONContentType];
  [self respondStatus:status headers:all body:data];
}

- (void)respondText:(NSString *)text contentType:(NSString *)type headers:(NSDictionary *)headers
{
  NSMutableDictionary *all = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
  all[@"Content-Type"] = type;
  [self respondStatus:200 headers:all body:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

// What an error answers with: a service error's own status; a failed
// validation's 400, with a detail for each property; a conflict's 409;
// anything else 500.
- (void)respondError:(NSError *)error
{
  NSInteger status = 500;
  NSMutableArray *details = [NSMutableArray array];
  NSString *target = error.userInfo[ODataErrorTargetKey];
  if ([error.domain isEqualToString:ODataServiceErrorDomain]) {
    status = error.code >= 400 && error.code < 600 ? error.code : 500;
    for (NSDictionary *detail in error.userInfo[ODataErrorDetailsKey] ?: @[]) [details addObject:detail];
  } else if ([error.domain isEqualToString:NSCocoaErrorDomain] && error.code >= NSValidationErrorMinimum && error.code <= NSValidationErrorMaximum) {
    status = 400;
    NSArray *each = error.code == NSValidationMultipleErrorsError ? error.userInfo[NSDetailedErrorsKey] : @[ error ];
    for (NSError *e in each) {
      NSMutableDictionary *detail = [NSMutableDictionary dictionary];
      detail[@"code"] = [NSString stringWithFormat:@"%ld", (long)e.code];
      detail[@"message"] = e.localizedDescription ?: @"Validation failed";
      NSManagedObject *object = e.userInfo[NSValidationObjectErrorKey];
      NSString *key = e.userInfo[NSValidationKeyErrorKey];
      NSPropertyDescription *property = key ? object.entity.propertiesByName[key] : nil;
      if ([property isKindOfClass:[NSAttributeDescription class]]) {
        detail[@"target"] = [self.mapper propertyForAttribute:(NSAttributeDescription *)property];
      } else if ([property isKindOfClass:[NSRelationshipDescription class]]) {
        detail[@"target"] = [self.mapper propertyForRelationship:(NSRelationshipDescription *)property];
      }
      [details addObject:detail];
    }
    if (details.count == 1) target = details[0][@"target"];
  } else if ([error.domain isEqualToString:NSCocoaErrorDomain] && (error.code == 133020 || error.code == 133021)) {
    status = 409;  // NSManagedObjectMergeError, NSManagedObjectConstraintMergeError
  } else if (!error) {
    error = ODataServiceError(500, @"The request failed");
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  body[@"code"] = error.userInfo[ODataErrorCodeKey] ?: [NSString stringWithFormat:@"%ld", (long)status];
  body[@"message"] = error.localizedDescription ?: @"";
  if (target) body[@"target"] = target;
  if (details.count) body[@"details"] = details;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  if (status == 405 && error.userInfo[@"Allow"]) headers[@"Allow"] = error.userInfo[@"Allow"];
  if (status == 401) {
    id<ODataAuthenticator> authenticator = self.service.authenticator;
    NSString *challenge = [authenticator respondsToSelector:@selector(challengeForRequest:)] ? [authenticator challengeForRequest:self.request] : nil;
    headers[@"WWW-Authenticate"] = challenge.length ? challenge : @"Bearer";
  }
  [self respondJSON:@{ @"error": body } status:status headers:headers];
}

- (void)fail:(NSInteger)status message:(NSString *)message
{
  [self respondError:ODataServiceError(status, message)];
}

- (void)methodNotAllowed:(NSArray<NSString *> *)allowed
{
  NSString *allow = [allowed componentsJoinedByString:@", "];
  NSError *error = [NSError errorWithDomain:ODataServiceErrorDomain code:405 userInfo:@{
    NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not allowed here", self.request.method],
    @"Allow": allow,
  }];
  [self respondError:error];
}

#pragma mark Reading the request

// The resource path after the service root, and the query options, both
// decoded.
- (BOOL)readURL
{
  NSURL *url = self.exchange.request.URL;
  NSString *rootPath = self.service.serviceRoot.path ?: @"/";
  if (![rootPath hasSuffix:@"/"]) rootPath = [rootPath stringByAppendingString:@"/"];
  NSString *path = url.path.length ? url.path : @"/";
  // NSURL drops a trailing slash from -path; the root itself may be asked
  // for with or without one.
  NSString *requestPath = [path hasSuffix:@"/"] ? path : [path stringByAppendingString:@"/"];
  if (![requestPath hasPrefix:rootPath]) {
    [self fail:404 message:[NSString stringWithFormat:@"%@ is not under the service root %@", path, rootPath]];
    return NO;
  }
  // The path as it was sent, so that an escaped character in a key keeps
  // its meaning until the parser has read the key.
  NSString *encoded = [self encodedPathOf:url];
  NSString *resource = encoded.length > rootPath.length ? [encoded substringFromIndex:rootPath.length] : @"";
  if ([resource hasSuffix:@"/"]) resource = [resource substringToIndex:resource.length - 1];
  self.resourcePath = OISPercentDecoded(resource);

  NSError *error = nil;
  ODataResourcePath *resourcePath = [ODataResourcePath pathWithString:self.resourcePath error:&error];
  if (!resourcePath) {
    [self respondError:ODataServiceError(400, error.localizedDescription)];
    return NO;
  }
  self.request.path = resourcePath;

  NSMutableDictionary *query = [NSMutableDictionary dictionary];
  NSMutableDictionary *JSONAliases = [NSMutableDictionary dictionary];
  NSString *raw = url.query;
  for (NSString *pair in raw.length ? [raw componentsSeparatedByString:@"&"] : @[]) {
    if (!pair.length) continue;
    NSRange equals = [pair rangeOfString:@"="];
    NSString *key = OISPercentDecoded(equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location]);
    NSString *value = equals.location == NSNotFound ? @"" : OISPercentDecoded([pair substringFromIndex:equals.location + 1]);
    if (query[key] || JSONAliases[key]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is given twice", key]];
      return NO;
    }
    NSString *trimmed = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([key hasPrefix:@"@"] && trimmed.length && strchr("[{\"", (char)[trimmed characterAtIndex:0])) {
      id json = [NSJSONSerialization JSONObjectWithData:[trimmed dataUsingEncoding:NSUTF8StringEncoding]
                                                options:NSJSONReadingAllowFragments
                                                  error:NULL];
      if (!json) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ is not JSON", key]];
        return NO;
      }
      JSONAliases[[key substringFromIndex:1]] = json;
      continue;
    }
    if ([key isEqualToString:@"$id"]) self.referenceID = value;
    query[key] = value;
  }
  self.JSONAliases = JSONAliases;
  for (NSString *key in query) {
    if ([@[ @"$apply", @"$compute", @"$index", @"$schemaversion", @"$deltatoken" ] containsObject:key]) {
      [self fail:501 message:[NSString stringWithFormat:@"%@ is not supported", key]];
      return NO;
    }
  }
  ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:query error:&error];
  if (!options) {
    [self respondError:ODataServiceError(400, error.localizedDescription)];
    return NO;
  }
  if (options.search) {
    [self fail:501 message:@"$search is not supported"];
    return NO;
  }
  self.request.options = options;
  return YES;
}

- (NSString *)encodedPathOf:(NSURL *)url
{
  NSString *absolute = url.absoluteString;
  NSRange scheme = [absolute rangeOfString:@"://"];
  NSUInteger start = 0;
  if (scheme.location != NSNotFound) {
    NSRange slash = [absolute rangeOfString:@"/" options:0 range:NSMakeRange(NSMaxRange(scheme), absolute.length - NSMaxRange(scheme))];
    start = slash.location == NSNotFound ? absolute.length : slash.location;
  }
  NSString *rest = [absolute substringFromIndex:start];
  NSRange end = [rest rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"?#"]];
  NSString *path = end.location == NSNotFound ? rest : [rest substringToIndex:end.location];
  return path.length ? path : @"/";
}

// OData-MaxVersion picks 4.0 or 4.01; OData-Version must be one the
// service speaks.
- (BOOL)negotiateVersion
{
  NSString *max = self.service.maxVersion;
  NSString *asked = [self.request valueForHeader:@"OData-MaxVersion"];
  NSString *version = [max isEqualToString:@"4.0"] ? @"4.0" : @"4.01";
  if (asked && [asked compare:@"4.01" options:NSNumericSearch] == NSOrderedAscending) version = @"4.0";
  self.request.version = version;
  NSString *sent = [self.request valueForHeader:@"OData-Version"];
  if (sent && ![sent isEqualToString:@"4.0"] && ![sent isEqualToString:@"4.01"]) {
    [self fail:400 message:[NSString stringWithFormat:@"OData-Version %@ is not supported", sent]];
    return NO;
  }
  if (sent && [sent compare:version options:NSNumericSearch] == NSOrderedDescending) {
    [self fail:400 message:[NSString stringWithFormat:@"The request is in OData-Version %@, and this service speaks %@", sent, version]];
    return NO;
  }
  return YES;
}

// $format, or Accept: JSON, with its odata.metadata and
// IEEE754Compatible parameters.
- (BOOL)negotiateFormat
{
  NSString *format = self.request.options.format;
  NSString *accept = [self.request valueForHeader:@"Accept"];
  NSString *given = format ?: accept ?: @"";
  NSString *lower = given.lowercaseString;
  BOOL metadata = self.kind == OISTargetMetadata;
  if (format) {
    BOOL json = [lower isEqualToString:@"json"] || [lower hasPrefix:@"application/json"];
    BOOL xml = [lower isEqualToString:@"xml"] || [lower hasPrefix:@"application/xml"];
    if (metadata && json) {
      [self fail:501 message:@"$metadata as JSON is not supported"];
      return NO;
    }
    if (!(metadata ? xml : json)) {
      [self fail:406 message:[NSString stringWithFormat:@"$format=%@ is not a format this resource has", format]];
      return NO;
    }
  } else if (accept.length && !metadata && self.kind != OISTargetCount && self.kind != OISTargetValue) {
    BOOL acceptable = NO;
    for (NSString *range in [lower componentsSeparatedByString:@","]) {
      NSString *type = [[range componentsSeparatedByString:@";"][0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
      if ([type isEqualToString:@"application/json"] || [type isEqualToString:@"*/*"] || [type isEqualToString:@"application/*"]) acceptable = YES;
    }
    if (!acceptable) {
      [self fail:406 message:@"This service answers in application/json"];
      return NO;
    }
  }
  self.metadataLevel = @"minimal";
  for (NSString *parameter in [lower componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";,"]]) {
    NSString *p = [parameter stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    for (NSString *name in @[ @"odata.metadata=", @"metadata=" ]) {
      if ([p hasPrefix:name]) {
        NSString *level = [p substringFromIndex:name.length];
        if ([@[ @"minimal", @"full", @"none" ] containsObject:level]) self.metadataLevel = level;
      }
    }
    if ([p isEqualToString:@"ieee754compatible=true"]) self.coder.IEEE754Compatible = YES;
  }
  return YES;
}

- (void)readPreferences
{
  NSMutableDictionary *preferences = [NSMutableDictionary dictionary];
  NSString *prefer = [self.request valueForHeader:@"Prefer"];
  for (NSString *item in prefer.length ? [prefer componentsSeparatedByString:@","] : @[]) {
    NSString *part = [[item componentsSeparatedByString:@";"][0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSRange equals = [part rangeOfString:@"="];
    NSString *name = (equals.location == NSNotFound ? part : [part substringToIndex:equals.location]).lowercaseString;
    NSString *value = equals.location == NSNotFound ? @"" : [part substringFromIndex:equals.location + 1];
    value = [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" "]];
    if ([name isEqualToString:@"maxpagesize"]) name = @"odata.maxpagesize";
    if (name.length) preferences[name] = value;
  }
  self.request.preferences = preferences;
}

#pragma mark Starting

- (void)run
{
  self.request.method = [self.request.method isEqualToString:@"HEAD"] ? @"GET" : self.request.method;
  if (self.authenticated || !self.service.authenticator) {
    [self answer];
    return;
  }
  // Who is asking, first: an authenticator may take its time.
  ODataReply *reply = [self replyWithAction:@selector(didAuthenticate:)];
  [self.service.authenticator authenticateRequest:self.request reply:reply];
  [reply returned:nil];
}

- (void)didAuthenticate:(ODataReply *)reply
{
  self.authenticated = YES;
  if (reply.error) {
    [self respondError:reply.error];
    return;
  }
  ODataPrincipal *principal = [reply.result isKindOfClass:[ODataPrincipal class]] ? reply.result : nil;
  if (!principal && !self.service.allowsAnonymousRequests) {
    [self fail:401 message:@"The request names no one: sign in"];
    return;
  }
  self.request.principal = principal;
  [self answer];
}

- (void)answer
{
  if (![self negotiateVersion] || ![self readURL]) return;
  [self readPreferences];

  NSArray<ODataPathSegment *> *segments = self.request.path.segments;
  if (!segments.count) {
    self.kind = OISTargetServiceDocument;
    [self dispatch];
    return;
  }
  ODataPathSegment *first = segments[0];
  if ([first.name isEqualToString:@"$metadata"] && segments.count == 1) {
    self.kind = OISTargetMetadata;
    [self dispatch];
    return;
  }
  if ([first.name isEqualToString:@"$batch"]) {
    if (segments.count > 1 || !self.saves) {
      [self fail:(segments.count > 1 ? 404 : 400) message:@"$batch is a resource of its own, and cannot be nested"];
      return;
    }
    // The batch answers the exchange itself, once its requests have.
    self.done = YES;
    OISBatchCall *batch = [[OISBatchCall alloc] initWithService:self.service exchange:self.exchange version:self.request.version
                                                      principal:self.request.principal];
    [batch start];
    return;
  }
  ODataEntitySetHandler *handler = first.isCall ? nil : [self.service handlerForEntitySet:first.name];
  OISServedOperation *import = handler ? nil : [self.service.catalog importNamed:first.name];
  if (import) {
    // CountProducts(), Echo(Text='x'): an unqualified name's parentheses
    // read as a key predicate, by name.
    NSDictionary *arguments = first.keys ?: first.arguments;
    if (arguments[@""]) {
      [self fail:400 message:[NSString stringWithFormat:@"The arguments of %@ are given by name", import.name]];
      return;
    }
    self.index = 1;
    [self callOperation:import arguments:arguments];
    return;
  }
  if (!handler) {
    [self fail:404 message:[NSString stringWithFormat:@"The service has no entity set %@", first.name]];
    return;
  }
  self.handler = handler;
  self.entity = handler.entity;
  self.kind = OISTargetCollection;
  // A key is looked for with the index at its segment, and the walk goes on
  // after it.
  self.index = 0;
  if (first.keys) {
    [self findObjectWithParts:first.keys];
    return;
  }
  self.index = 1;
  [self walk];
}

// Along the path, one segment at a time, from the collection or entity at
// self.index.
- (void)walk
{
  NSArray<ODataPathSegment *> *segments = self.request.path.segments;
  while (self.index < segments.count) {
    ODataPathSegment *segment = segments[self.index];
    NSString *name = segment.name;
    switch (self.kind) {
      case OISTargetCollection:
        if ([name isEqualToString:@"$ref"] && self.index + 1 == segments.count && !segment.keys) {
          self.kind = OISTargetReference;
          self.referencesCollection = YES;
          self.index++;
          continue;
        }
        if ([name rangeOfString:@"."].location != NSNotFound) {
          OISServedOperation *operation = [self.service.catalog operationNamed:name boundTo:self.entity collection:YES];
          if (operation) {
            self.index++;
            [self callOperation:operation arguments:segment.arguments];
            return;
          }
        }
        if ([name isEqualToString:@"$count"] && self.index + 1 == segments.count && !segment.keys) {
          self.kind = OISTargetCount;
          self.index++;
          continue;
        }
        if (!segment.keys && !segment.isCall && ![name hasPrefix:@"$"] && [name rangeOfString:@"."].location == NSNotFound &&
            [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)].count == 1) {
          // A key as a segment: Products/1 (Part 2 section 4.3.6).
          [self findObjectWithParts:@{ @"": [self literalForKeySegment:name] }];
          return;
        }
        if ([name rangeOfString:@"."].location != NSNotFound && !segment.keys && !segment.isCall) {
          // A type cast: the members of that derived type (Part 2 section 4.11).
          NSEntityDescription *derived = [self entityForTypeName:name];
          if (derived && [derived isKindOfEntity:self.entity]) {
            self.entity = derived;
            self.index++;
            continue;
          }
        }
        [self fail:404 message:[NSString stringWithFormat:@"%@ cannot follow a collection here", name]];
        return;
      case OISTargetEntity: {
        if ([name rangeOfString:@"."].location != NSNotFound) {
          OISServedOperation *operation = [self.service.catalog operationNamed:name boundTo:self.object.entity collection:NO];
          if (operation) {
            self.index++;
            [self callOperation:operation arguments:segment.arguments];
            return;
          }
        }
        if ([name isEqualToString:@"$ref"] && self.index + 1 == segments.count && !segment.keys) {
          self.kind = OISTargetReference;
          self.index++;
          continue;
        }
        if ([name rangeOfString:@"."].location != NSNotFound && !segment.keys && !segment.isCall) {
          NSEntityDescription *derived = [self entityForTypeName:name];
          if (derived) {
            if (![self.object.entity isKindOfEntity:derived]) {
              [self fail:404 message:[NSString stringWithFormat:@"That %@ is not a %@", self.object.entity.name, name]];
              return;
            }
            self.index++;
            continue;
          }
        }
        if ([name isEqualToString:@"$ref"] || [name isEqualToString:@"$value"] || [name rangeOfString:@"."].location != NSNotFound) {
          [self fail:501 message:[NSString stringWithFormat:@"%@ is not supported", name]];
          return;
        }
        NSPropertyDescription *property = [self.mapper propertyForWireName:name entity:self.object.entity];
        if (!property) {
          [self fail:404 message:[NSString stringWithFormat:@"%@ has no property %@", self.object.entity.name, name]];
          return;
        }
        if ([property isKindOfClass:[NSAttributeDescription class]]) {
          if (segment.keys) {
            [self fail:400 message:[NSString stringWithFormat:@"%@ is not a collection", name]];
            return;
          }
          self.attribute = (NSAttributeDescription *)property;
          self.kind = OISTargetProperty;
          self.index++;
          if (self.index < segments.count && [segments[self.index].name isEqualToString:@"$value"]) {
            self.kind = OISTargetValue;
            self.index++;
          }
          continue;
        }
        NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
        ODataEntitySetHandler *handler = [self.service handlerForEntity:relationship.destinationEntity];
        if (!handler) {
          [self fail:404 message:[NSString stringWithFormat:@"%@ leads to no entity set", name]];
          return;
        }
        self.handler = handler;
        if (relationship.isToMany) {
          self.parent = self.object;
          self.navigation = relationship;
          self.object = nil;
          self.entity = relationship.destinationEntity;
          self.kind = OISTargetCollection;
          self.index++;
          if (segment.keys) {
            self.index--;
            [self findObjectWithParts:segment.keys];
            return;
          }
          continue;
        }
        if (segment.keys) {
          [self fail:400 message:[NSString stringWithFormat:@"%@ is not a collection", name]];
          return;
        }
        NSManagedObject *related = [self.object valueForKey:relationship.name];
        NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
        if (related && visible && ![visible evaluateWithObject:related]) related = nil;
        self.referrer = self.object;
        self.referrerNavigation = relationship;
        if (self.index + 2 == segments.count && [segments[self.index + 1].name isEqualToString:@"$ref"]) {
          // Products(1)/Category/$ref: the reference, which may be null.
          self.object = related;
          self.entity = relationship.destinationEntity;
          self.kind = OISTargetReference;
          self.index += 2;
          continue;
        }
        if (!related) {
          // A single-valued navigation property that is null (Part 1 section 11.2.6).
          [self respondStatus:204 headers:@{} body:nil];
          return;
        }
        self.object = related;
        self.entity = related.entity;
        self.index++;
        continue;
      }
      default:
        [self fail:400 message:[NSString stringWithFormat:@"%@ cannot follow a property value", name]];
        return;
    }
  }
  [self dispatch];
}

- (ODataExpression *)literalForKeySegment:(NSString *)text
{
  NSAttributeDescription *key = [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)].firstObject;
  // A string key is written bare in a segment; anything else as its literal.
  if (key.attributeType == NSStringAttributeType) {
    NSString *quoted = [NSString stringWithFormat:@"'%@'", [text stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
    return [ODataExpression expressionWithString:quoted error:NULL];
  }
  return [ODataExpression expressionWithString:text error:NULL];
}

// A key predicate's parts as Core Data values, by attribute name.
- (NSDictionary *)keyFromParts:(NSDictionary<NSString *, ODataExpression *> *)parts entity:(NSEntityDescription *)entity
{
  NSArray<NSAttributeDescription *> *attributes = [self.mapper keyAttributesForEntity:OISRootEntity(entity)];
  if (!attributes.count) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ has no key", entity.name]];
    return nil;
  }
  NSMutableDictionary *key = [NSMutableDictionary dictionary];
  for (NSAttributeDescription *attribute in attributes) {
    NSString *wire = [self.mapper propertyForAttribute:attribute];
    ODataExpression *part = parts[wire];
    if (!part && attributes.count == 1 && parts.count == 1) part = parts[@""];
    while (part.kind == ODataExpressionAlias) part = self.request.options.aliases[part.name];
    if (!part || part.kind != ODataExpressionLiteral) {
      [self fail:400 message:[NSString stringWithFormat:@"The key of %@ needs %@", entity.name, wire]];
      return nil;
    }
    id value = part.value ? [self.coder coreDataValueForJSON:part.value attribute:attribute] : nil;
    if (!value || value == [NSNull null]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value of %@", part, wire]];
      return nil;
    }
    key[attribute.name] = value;
  }
  if (parts.count > attributes.count) {
    [self fail:400 message:[NSString stringWithFormat:@"The key of %@ has %lu parts", entity.name, (unsigned long)attributes.count]];
    return nil;
  }
  return key;
}

- (void)findObjectWithParts:(NSDictionary *)parts
{
  NSDictionary *key = [self keyFromParts:parts entity:self.entity];
  if (!key) return;
  ODataReply *reply = [self replyWithAction:@selector(didFindObject:)];
  NSManagedObject *object = [self.handler objectWithKey:key request:self.request reply:reply];
  [reply returned:object];
}

- (void)didFindObject:(ODataReply *)reply
{
  if (reply.error) {
    [self respondError:reply.error];
    return;
  }
  NSManagedObject *object = reply.result;
  if (object && self.parent && self.navigation) {
    id members = [self.parent valueForKey:self.navigation.name];
    if (![members containsObject:object]) object = nil;
  }
  if (!object) {
    [self fail:404 message:[NSString stringWithFormat:@"%@ has no such entity", self.request.path.segments[self.index > 0 ? self.index - 1 : 0].name]];
    return;
  }
  self.object = object;
  self.entity = object.entity;
  self.kind = OISTargetEntity;
  self.referrer = self.parent;
  self.referrerNavigation = self.navigation;
  self.parent = nil;
  self.navigation = nil;
  self.index++;
  [self walk];
}

#pragma mark Dispatch

- (void)dispatch
{
  if (![self negotiateFormat]) return;
  NSString *method = self.request.method;
  self.request.entity = self.entity;
  switch (self.kind) {
    case OISTargetServiceDocument:
      if ([method isEqualToString:@"GET"]) [self serviceDocument];
      else [self methodNotAllowed:@[ @"GET" ]];
      return;
    case OISTargetMetadata:
      if ([method isEqualToString:@"GET"]) {
        [self respondText:[self.service metadataXMLForVersion:self.request.version] contentType:@"application/xml;charset=utf-8" headers:nil];
      } else {
        [self methodNotAllowed:@[ @"GET" ]];
      }
      return;
    case OISTargetCollection:
      if ([method isEqualToString:@"GET"]) [self readCollection];
      else if ([method isEqualToString:@"POST"]) [self insert];
      else [self methodNotAllowed:@[ @"GET", @"POST" ]];
      return;
    case OISTargetCount:
      if ([method isEqualToString:@"GET"]) [self readCount];
      else [self methodNotAllowed:@[ @"GET" ]];
      return;
    case OISTargetEntity:
      if ([method isEqualToString:@"GET"]) [self readEntity];
      else if ([method isEqualToString:@"PATCH"] || [method isEqualToString:@"MERGE"]) [self updateReplacing:NO];
      else if ([method isEqualToString:@"PUT"]) [self updateReplacing:YES];
      else if ([method isEqualToString:@"DELETE"]) [self remove];
      else [self methodNotAllowed:@[ @"GET", @"PATCH", @"PUT", @"DELETE" ]];
      return;
    case OISTargetOperation:
      if ([method isEqualToString:(self.operation.isAction ? @"POST" : @"GET")]) [self invokeOperation];
      else [self methodNotAllowed:@[ self.operation.isAction ? @"POST" : @"GET" ]];
      return;
    case OISTargetProperty:
    case OISTargetValue:
      if ([method isEqualToString:@"GET"]) [self readProperty];
      else if ([@[ @"PUT", @"PATCH", @"DELETE" ] containsObject:method]) [self writeProperty];
      else [self methodNotAllowed:@[ @"GET", @"PUT", @"PATCH", @"DELETE" ]];
      return;
    case OISTargetReference:
      if ([method isEqualToString:@"GET"]) [self readReference];
      else if ([@[ @"PUT", @"POST", @"DELETE" ] containsObject:method]) [self writeReference];
      else [self methodNotAllowed:@[ @"GET", @"PUT", @"POST", @"DELETE" ]];
      return;
  }
}

#pragma mark URLs

- (NSString *)rootString
{
  NSString *root = self.service.serviceRoot.absoluteString;
  return [root hasSuffix:@"/"] ? root : [root stringByAppendingString:@"/"];
}

- (NSString *)contextBase
{
  return [[self rootString] stringByAppendingString:@"$metadata"];
}

// Products(1), OrderItems(OrderID=1,ItemNo=2): an entity's canonical path.
- (NSString *)canonicalPathOf:(NSManagedObject *)object
{
  NSEntityDescription *root = OISRootEntity(object.entity);
  NSArray<NSAttributeDescription *> *key = [self.mapper keyAttributesForEntity:root];
  NSMutableArray *parts = [NSMutableArray array];
  for (NSAttributeDescription *attribute in key) {
    NSString *literal = [self.coder literalForValue:[object valueForKey:attribute.name] attribute:attribute];
    [parts addObject:key.count == 1 ? literal : [NSString stringWithFormat:@"%@=%@", [self.mapper propertyForAttribute:attribute], literal]];
  }
  return [NSString stringWithFormat:@"%@(%@)", [self.service entitySetForEntity:root], [parts componentsJoinedByString:@","]];
}

- (NSString *)selectListForOptions:(ODataQueryOptions *)options
{
  NSMutableArray *items = [NSMutableArray array];
  for (ODataSelectItem *item in options.select) [items addObject:item.isStar ? @"*" : [item.path componentsJoinedByString:@"/"]];
  BOOL v401 = [self.request.version isEqualToString:@"4.01"];
  for (ODataExpandItem *item in options.expand) {
    if (item.isStar || item.isRef || item.isCount) continue;
    NSString *nested = [self selectListForOptions:item.options];
    if (nested.length) {
      [items addObject:[NSString stringWithFormat:@"%@%@", [item.path componentsJoinedByString:@"/"], nested]];
    } else if (v401) {
      [items addObject:[NSString stringWithFormat:@"%@()", [item.path componentsJoinedByString:@"/"]]];
    }
  }
  return items.count ? [NSString stringWithFormat:@"(%@)", [items componentsJoinedByString:@","]] : @"";
}

#pragma mark ETags

- (NSString *)etagOf:(NSManagedObject *)object
{
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:object.entity];
  if (version) return [NSString stringWithFormat:@"W/\"%@\"", [object valueForKey:version.name] ?: @0];
  // A hash of the values, in a fixed order: it changes when they do.
  uint64_t hash = 14695981039346656037ULL;
  NSArray *names = [object.entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSAttributeDescription *attribute = object.entity.attributesByName[name];
    if (attribute.isTransient) continue;
    id json = [self.coder JSONForCoreDataValue:[object valueForKey:name] attribute:attribute];
    NSString *text = [NSString stringWithFormat:@"%@=%@;", name, json];
    NSData *bytes = [text dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = bytes.bytes;
    for (NSUInteger i = 0; i < bytes.length; i++) {
      hash ^= p[i];
      hash *= 1099511628211ULL;
    }
  }
  return [NSString stringWithFormat:@"W/\"%016llx\"", (unsigned long long)hash];
}

// If-Match: the entity's ETag, one of a list, or *.
- (BOOL)ifMatchAllows:(NSManagedObject *)object
{
  NSString *condition = [self.request valueForHeader:@"If-Match"];
  if (!condition.length) return YES;
  NSString *current = [self etagOf:object];
  for (NSString *tag in [condition componentsSeparatedByString:@","]) {
    NSString *t = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([t isEqualToString:@"*"] || [t isEqualToString:current]) return YES;
  }
  return NO;
}

#pragma mark Serialising

- (NSArray<NSAttributeDescription *> *)servedAttributesOf:(NSEntityDescription *)entity
{
  // Sorted by name: -properties has no specified order.
  NSMutableArray *attributes = [NSMutableArray array];
  for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attribute = entity.attributesByName[name];
    if ([self.service.writer typeNameForAttribute:attribute]) [attributes addObject:attribute];
  }
  return attributes;
}

- (NSMutableDictionary *)JSONForObject:(NSManagedObject *)object
                               options:(ODataQueryOptions *)options
                              expected:(NSEntityDescription *)expected
                                 error:(NSError **)error
{
  NSMutableDictionary *json = [NSMutableDictionary dictionary];
  BOOL none = [self.metadataLevel isEqualToString:@"none"];
  BOOL full = [self.metadataLevel isEqualToString:@"full"];
  if (!none) json[@"@odata.etag"] = [self etagOf:object];
  if (full || (!none && expected && object.entity != expected)) {
    json[@"@odata.type"] = [@"#" stringByAppendingString:[self.service.writer typeNameForEntity:object.entity]];
  }
  if (full) {
    NSString *path = [self canonicalPathOf:object];
    json[@"@odata.id"] = path;
    json[@"@odata.editLink"] = path;
  }

  NSArray<NSAttributeDescription *> *attributes = [self servedAttributesOf:object.entity];
  BOOL star = !options.select.count;
  NSMutableSet *selected = [NSMutableSet set];
  for (ODataSelectItem *item in options.select) {
    if (item.isStar) {
      star = YES;
      continue;
    }
    if (item.path.count == 2 && [item.path[0] rangeOfString:@"."].location != NSNotFound) {
      // Default.Manager/Budget: the property, of the objects of that type.
      NSEntityDescription *derived = [self entityForTypeName:item.path[0]];
      NSPropertyDescription *property = derived ? [self.mapper propertyForWireName:item.path[1] entity:derived] : nil;
      if (!property) {
        if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"$select=%@ names no property", [item.path componentsJoinedByString:@"/"]]);
        return nil;
      }
      if ([object.entity isKindOfEntity:derived]) [selected addObject:property.name];
      continue;
    }
    if (item.path.count != 1) {
      if (error) *error = ODataServiceError(501, [NSString stringWithFormat:@"$select=%@ is not supported", [item.path componentsJoinedByString:@"/"]]);
      return nil;
    }
    NSPropertyDescription *property = [self.mapper propertyForWireName:item.path[0] entity:object.entity];
    if (!property && ![self.mapper propertyForWireName:item.path[0] entity:expected ?: object.entity]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no property %@", object.entity.name, item.path[0]]);
      return nil;
    }
    if (property) [selected addObject:property.name];
  }
  for (NSAttributeDescription *attribute in attributes) {
    if (!star && ![selected containsObject:attribute.name]) continue;
    json[[self.mapper propertyForAttribute:attribute]] = [self.coder JSONForCoreDataValue:[object valueForKey:attribute.name] attribute:attribute];
  }
  for (ODataExpandItem *item in options.expand) {
    if (![self expand:item of:object into:json error:error]) return nil;
  }
  return json;
}

// $levels=max is taken as this deep, and no object is expanded inside
// itself (Part 2 section 5.1.3.1).
static const NSInteger OISMaxLevels = 32;

- (BOOL)expand:(ODataExpandItem *)item of:(NSManagedObject *)object into:(NSMutableDictionary *)json error:(NSError **)error
{
  NSNumber *levels = item.options.levels;
  NSInteger depth = !levels ? 1 : levels.integerValue < 0 ? OISMaxLevels : MAX(levels.integerValue, 1);
  return [self expand:item of:object into:json levels:depth path:[NSMutableSet setWithObject:object.objectID] error:error];
}

// One level further down the same navigation property, while $levels
// allows and the object is not one it came through.
- (BOOL)expandLevels:(ODataExpandItem *)item of:(NSManagedObject *)object into:(NSMutableDictionary *)json
              levels:(NSInteger)levels path:(NSMutableSet *)path error:(NSError **)error
{
  if (levels <= 1 || item.isRef || item.isCount || item.path.count != 1) return YES;
  if (![[self.mapper propertyForWireName:item.path[0] entity:object.entity] isKindOfClass:[NSRelationshipDescription class]]) return YES;
  if ([path containsObject:object.objectID]) return YES;
  [path addObject:object.objectID];
  BOOL ok = [self expand:item of:object into:json levels:levels - 1 path:path error:error];
  [path removeObject:object.objectID];
  return ok;
}

- (BOOL)expand:(ODataExpandItem *)item
            of:(NSManagedObject *)object
          into:(NSMutableDictionary *)json
        levels:(NSInteger)levels
          path:(NSMutableSet *)path
         error:(NSError **)error
{
  ODataQueryOptions *options = item.options;
  NSMutableArray<NSRelationshipDescription *> *relationships = [NSMutableArray array];
  if (item.isStar) {
    for (NSRelationshipDescription *relationship in object.entity.relationshipsByName.allValues) {
      if ([self.service handlerForEntity:relationship.destinationEntity]) [relationships addObject:relationship];
    }
  } else {
    if (item.path.count != 1) {
      if (error) *error = ODataServiceError(501, [NSString stringWithFormat:@"$expand=%@ is not supported", [item.path componentsJoinedByString:@"/"]]);
      return NO;
    }
    NSPropertyDescription *property = [self.mapper propertyForWireName:item.path[0] entity:object.entity];
    if (![property isKindOfClass:[NSRelationshipDescription class]]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no navigation property %@", object.entity.name, item.path[0]]);
      return NO;
    }
    [relationships addObject:(NSRelationshipDescription *)property];
  }

  for (NSRelationshipDescription *relationship in relationships) {
    NSString *wire = [self.mapper propertyForRelationship:relationship];
    NSEntityDescription *destination = relationship.destinationEntity;
    ODataEntitySetHandler *handler = [self.service handlerForEntity:destination];
    NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
    NSPredicate *filter = nil;
    if (options.filter) {
      filter = [self.service.predicates predicateForExpression:options.filter entity:destination aliases:self.request.options.aliases error:error];
      if (!filter) return NO;
    }
    NSArray *members;
    if (relationship.isToMany) {
      members = [[object valueForKey:relationship.name] allObjects];
    } else {
      id related = [object valueForKey:relationship.name];
      members = related ? @[ related ] : @[];
    }
    if (visible) members = [members filteredArrayUsingPredicate:visible];
    if (filter) members = [members filteredArrayUsingPredicate:filter];

    if (!relationship.isToMany) {
      NSManagedObject *related = members.firstObject;
      if (item.isRef) {
        json[wire] = related ? @{ @"@odata.id": [self canonicalPathOf:related] } : [NSNull null];
      } else {
        id nested = related ? [self JSONForObject:related options:options expected:destination error:error] : [NSNull null];
        if (!nested) return NO;
        if (related && ![self expandLevels:item of:related into:nested levels:levels path:path error:error]) return NO;
        json[wire] = nested;
      }
      continue;
    }

    NSMutableArray *sort = [NSMutableArray array];
    if (options.orderBy.count) {
      NSArray *descriptors = [self.service.predicates sortDescriptorsForOrderBy:options.orderBy entity:destination error:error];
      if (!descriptors) return NO;
      [sort addObjectsFromArray:descriptors];
    }
    for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(destination)]) {
      [sort addObject:[NSSortDescriptor sortDescriptorWithKey:attribute.name ascending:YES]];
    }
    members = [members sortedArrayUsingDescriptors:sort];
    if (options.includeCount.boolValue || item.isCount) json[[wire stringByAppendingString:@"@odata.count"]] = @(members.count);
    if (item.isCount) continue;
    NSUInteger skip = MIN(options.skip.unsignedIntegerValue, members.count);
    NSUInteger take = options.top ? MIN(options.top.unsignedIntegerValue, members.count - skip) : members.count - skip;
    members = [members subarrayWithRange:NSMakeRange(skip, take)];
    NSMutableArray *values = [NSMutableArray array];
    for (NSManagedObject *member in members) {
      if (item.isRef) {
        [values addObject:@{ @"@odata.id": [self canonicalPathOf:member] }];
        continue;
      }
      NSMutableDictionary *nested = [self JSONForObject:member options:options expected:destination error:error];
      if (!nested) return NO;
      if (![self expandLevels:item of:member into:nested levels:levels path:path error:error]) return NO;
      [values addObject:nested];
    }
    json[wire] = values;
  }
  return YES;
}

#pragma mark Reads

- (void)serviceDocument
{
  NSMutableArray *sets = [NSMutableArray array];
  for (NSString *name in self.service.entitySets) {
    [sets addObject:@{ @"name": name, @"kind": @"EntitySet", @"url": name }];
  }
  [self respondJSON:@{ @"@odata.context": [self contextBase], @"value": sets } status:200 headers:nil];
}

- (NSString *)setName
{
  return [self.service entitySetForEntity:OISRootEntity(self.entity)];
}

// The predicate a collection's rows answer to: the filter, the navigation
// they were reached through, and what the set lets the caller see.
- (NSPredicate *)collectionPredicateWithFilter:(BOOL)withFilter error:(NSError **)error
{
  NSMutableArray *parts = [NSMutableArray array];
  if (withFilter && self.request.options.filter) {
    NSPredicate *filter = [self.service.predicates predicateForExpression:self.request.options.filter
                                                                   entity:self.entity
                                                                  aliases:self.request.options.aliases
                                                                    error:error];
    if (!filter) return nil;
    [parts addObject:filter];
  }
  if (self.members) [parts addObject:[self predicateForObjects:self.members]];
  if (self.parent && self.navigation) {
    NSPredicate *members = [self membersOfNavigation];
    if (!members) {
      if (error) *error = ODataServiceError(500, [NSString stringWithFormat:@"%@ has no key to follow %@ by", self.parent.entity.name, self.navigation.name]);
      return nil;
    }
    [parts addObject:members];
  }
  NSPredicate *visible = [self.handler predicateForVisibleObjectsInRequest:self.request];
  if (visible) [parts addObject:visible];
  if (!parts.count) return [NSPredicate predicateWithValue:YES];
  return parts.count == 1 ? parts[0] : [NSCompoundPredicate andPredicateWithSubpredicates:parts];
}

static NSPredicate *OISEquals(NSString *keyPath, id value, NSComparisonPredicateModifier modifier)
{
  return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:keyPath]
                                            rightExpression:[NSExpression expressionForConstantValue:value]
                                                   modifier:modifier
                                                       type:NSEqualToPredicateOperatorType
                                                    options:0];
}

// These objects, by key: id IN (1, 2), or one AND of the key's parts each.
- (NSPredicate *)predicateForObjects:(NSArray<NSManagedObject *> *)objects
{
  NSArray<NSAttributeDescription *> *key = [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)];
  if (key.count == 1) {
    return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:key[0].name]
                                              rightExpression:[NSExpression expressionForConstantValue:[objects valueForKey:key[0].name]]
                                                     modifier:NSDirectPredicateModifier
                                                         type:NSInPredicateOperatorType
                                                      options:0];
  }
  NSMutableArray *each = [NSMutableArray array];
  for (NSManagedObject *object in objects) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSAttributeDescription *attribute in key) [parts addObject:OISEquals(attribute.name, [object valueForKey:attribute.name], NSDirectPredicateModifier)];
    [each addObject:[NSCompoundPredicate andPredicateWithSubpredicates:parts]];
  }
  return each.count ? [NSCompoundPredicate orPredicateWithSubpredicates:each] : [NSPredicate predicateWithValue:NO];
}

// The rows a navigation property leads to, by key rather than by object:
// category.id == 2, ANY suppliers.id == 2. Every store can compare
// attributes; not every store compares managed objects in a fetch
// (FreeCoreData's in-memory store matches none, and cannot count them).
- (NSPredicate *)membersOfNavigation
{
  NSRelationshipDescription *inverse = self.navigation.inverseRelationship;
  NSArray<NSAttributeDescription *> *parentKey = [self.mapper keyAttributesForEntity:OISRootEntity(self.parent.entity)];
  if (inverse && parentKey.count) {
    if (parentKey.count == 1) {
      NSString *path = [NSString stringWithFormat:@"%@.%@", inverse.name, parentKey[0].name];
      return OISEquals(path, [self.parent valueForKey:parentKey[0].name], inverse.isToMany ? NSAnyPredicateModifier : NSDirectPredicateModifier);
    }
    if (!inverse.isToMany) {
      NSMutableArray *parts = [NSMutableArray array];
      for (NSAttributeDescription *attribute in parentKey) {
        [parts addObject:OISEquals([NSString stringWithFormat:@"%@.%@", inverse.name, attribute.name],
                                   [self.parent valueForKey:attribute.name], NSDirectPredicateModifier)];
      }
      return [NSCompoundPredicate andPredicateWithSubpredicates:parts];
    }
  }
  // No inverse, or a compound key on the far side of a to-many one: the
  // members' own keys.
  NSArray<NSAttributeDescription *> *key = [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)];
  if (!key.count) return nil;
  NSSet *members = [self.parent valueForKey:self.navigation.name] ?: [NSSet set];
  if (key.count == 1) {
    NSArray *values = [members.allObjects valueForKey:key[0].name];
    return [NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:key[0].name]
                                              rightExpression:[NSExpression expressionForConstantValue:values]
                                                     modifier:NSDirectPredicateModifier
                                                         type:NSInPredicateOperatorType
                                                      options:0];
  }
  NSMutableArray *each = [NSMutableArray array];
  for (NSManagedObject *member in members) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSAttributeDescription *attribute in key) [parts addObject:OISEquals(attribute.name, [member valueForKey:attribute.name], NSDirectPredicateModifier)];
    [each addObject:[NSCompoundPredicate andPredicateWithSubpredicates:parts]];
  }
  return each.count ? [NSCompoundPredicate orPredicateWithSubpredicates:each] : [NSPredicate predicateWithValue:NO];
}

- (void)readCount
{
  NSError *error = nil;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
  fetch.predicate = [self collectionPredicateWithFilter:YES error:&error];
  if (!fetch.predicate) {
    [self respondError:error];
    return;
  }
  ODataReply *reply = [self replyWithAction:@selector(didCountForPath:)];
  [reply returned:[self.handler countForFetchRequest:fetch request:self.request reply:reply]];
}

- (void)didCountForPath:(ODataReply *)reply
{
  if (reply.error) {
    [self respondError:reply.error];
    return;
  }
  [self respondText:[reply.result description] ?: @"0" contentType:@"text/plain;charset=utf-8" headers:nil];
}

- (void)readCollection
{
  ODataQueryOptions *options = self.request.options;
  NSError *error = nil;
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
  fetch.predicate = [self collectionPredicateWithFilter:YES error:&error];
  if (!fetch.predicate) {
    [self respondError:error];
    return;
  }
  NSMutableArray *sort = [NSMutableArray array];
  if (options.orderBy.count) {
    NSArray *descriptors = [self.service.predicates sortDescriptorsForOrderBy:options.orderBy entity:self.entity error:&error];
    if (!descriptors) {
      [self respondError:error];
      return;
    }
    [sort addObjectsFromArray:descriptors];
  }
  // The key last, so that pages do not overlap.
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(self.entity)]) {
    [sort addObject:[NSSortDescriptor sortDescriptorWithKey:attribute.name ascending:YES]];
  }
  fetch.sortDescriptors = sort;

  // Paging: the smaller of the service's page and the client's.
  NSUInteger page = self.service.maxPageSize;
  NSString *preferred = self.request.preferences[@"odata.maxpagesize"];
  if (preferred.integerValue > 0 && (!page || (NSUInteger)preferred.integerValue < page)) {
    page = (NSUInteger)preferred.integerValue;
    self.pagedByPreference = YES;
  }
  if (options.skipToken) {
    NSScanner *scanner = [NSScanner scannerWithString:options.skipToken];
    NSInteger token = 0;
    if (![scanner scanInteger:&token] || !scanner.isAtEnd || token < 0) {
      [self fail:400 message:[NSString stringWithFormat:@"$skiptoken=%@ is not one this service wrote", options.skipToken]];
      return;
    }
    self.skipToken = (NSUInteger)token;
  }
  NSUInteger remaining = NSUIntegerMax;
  if (options.top) {
    NSUInteger top = options.top.unsignedIntegerValue;
    remaining = top > self.skipToken ? top - self.skipToken : 0;
  }
  NSUInteger limit = page ? MIN(page, remaining) : remaining;
  self.pageSize = limit;
  fetch.fetchOffset = options.skip.unsignedIntegerValue + self.skipToken;
  // One more than the page, to know whether there is a next one.
  if (limit != NSUIntegerMax) fetch.fetchLimit = limit < remaining ? limit + 1 : limit;
  if (limit == 0) fetch.fetchLimit = 1;

  NSMutableArray *prefetch = [NSMutableArray array];
  for (ODataExpandItem *item in options.expand) {
    if (item.path.count != 1) continue;
    NSPropertyDescription *property = [self.mapper propertyForWireName:item.path[0] entity:self.entity];
    if ([property isKindOfClass:[NSRelationshipDescription class]]) [prefetch addObject:property.name];
  }
  if (prefetch.count) fetch.relationshipKeyPathsForPrefetching = prefetch;
  self.fetch = fetch;

  ODataReply *reply = [self replyWithAction:@selector(didFetch:)];
  [reply returned:[self.handler objectsForFetchRequest:fetch request:self.request reply:reply]];
}

- (void)didFetch:(ODataReply *)reply
{
  if (reply.error) {
    [self respondError:reply.error];
    return;
  }
  NSArray *objects = reply.result ?: @[];
  if (self.pageSize != NSUIntegerMax && objects.count > self.pageSize) {
    objects = [objects subarrayWithRange:NSMakeRange(0, self.pageSize)];
    self.nextLink = [self nextLinkWithToken:self.skipToken + self.pageSize];
  }
  self.objects = objects;
  if (!self.request.options.includeCount.boolValue) {
    [self writeCollection];
    return;
  }
  NSFetchRequest *count = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
  count.predicate = self.fetch.predicate;
  ODataReply *countReply = [self replyWithAction:@selector(didCount:)];
  [countReply returned:[self.handler countForFetchRequest:count request:self.request reply:countReply]];
}

- (void)didCount:(ODataReply *)reply
{
  if (reply.error) {
    [self respondError:reply.error];
    return;
  }
  self.count = reply.result;
  [self writeCollection];
}

// This request again, from this many rows on.
- (NSString *)nextLinkWithToken:(NSUInteger)token
{
  NSMutableArray *pairs = [NSMutableArray array];
  NSString *raw = self.exchange.request.URL.query;
  for (NSString *pair in raw.length ? [raw componentsSeparatedByString:@"&"] : @[]) {
    NSString *key = OISPercentDecoded([pair componentsSeparatedByString:@"="][0]);
    if (pair.length && ![key isEqualToString:@"$skiptoken"]) [pairs addObject:pair];
  }
  [pairs addObject:[NSString stringWithFormat:@"$skiptoken=%lu", (unsigned long)token]];
  NSString *path = [self encodedPathOf:self.exchange.request.URL];
  NSString *rootPath = self.service.serviceRoot.path ?: @"/";
  if (![rootPath hasSuffix:@"/"]) rootPath = [rootPath stringByAppendingString:@"/"];
  NSString *resource = path.length > rootPath.length ? [path substringFromIndex:rootPath.length] : @"";
  return [NSString stringWithFormat:@"%@%@?%@", [self rootString], resource, [pairs componentsJoinedByString:@"&"]];
}

- (void)writeCollection
{
  NSError *error = nil;
  NSMutableArray *values = [NSMutableArray array];
  for (NSManagedObject *object in self.objects) {
    if (self.referencesOnly) {
      [values addObject:@{ @"@odata.id": [self canonicalPathOf:object] }];
      continue;
    }
    NSDictionary *json = [self JSONForObject:object options:self.request.options expected:self.entity error:&error];
    if (!json) {
      [self respondError:error];
      return;
    }
    [values addObject:json];
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) {
    body[@"@odata.context"] = self.referencesOnly
        ? [NSString stringWithFormat:@"%@#Collection($ref)", [self contextBase]]
        : [NSString stringWithFormat:@"%@#%@%@%@", [self contextBase], [self setName], [self castSuffixFor:self.entity],
                                     [self selectListForOptions:self.request.options]];
  }
  if (self.count) body[@"@odata.count"] = self.count;
  body[@"value"] = values;
  if (self.nextLink) body[@"@odata.nextLink"] = self.nextLink;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  if (self.pagedByPreference) headers[@"Preference-Applied"] = [NSString stringWithFormat:@"odata.maxpagesize=%lu", (unsigned long)self.pageSize];
  [self respondJSON:body status:200 headers:headers];
}

- (NSDictionary *)entityBodyFor:(NSManagedObject *)object error:(NSError **)error
{
  ODataQueryOptions *options = self.responseOptions ?: self.request.options;
  NSMutableDictionary *json = [self JSONForObject:object options:options expected:nil error:error];
  if (!json) return nil;
  if (![self.metadataLevel isEqualToString:@"none"]) {
    NSEntityDescription *root = OISRootEntity(object.entity);
    NSString *cast = object.entity == root ? @"" : [@"/" stringByAppendingString:[self.service.writer typeNameForEntity:object.entity]];
    json[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@%@%@/$entity", [self contextBase],
                               [self.service entitySetForEntity:root], cast, [self selectListForOptions:options]];
  }
  return json;
}

- (void)readEntity
{
  NSString *etag = [self etagOf:self.object];
  NSString *unless = [self.request valueForHeader:@"If-None-Match"];
  if (unless.length && ([unless isEqualToString:@"*"] || [[unless componentsSeparatedByString:@","] containsObject:etag])) {
    [self respondStatus:304 headers:@{ @"ETag": etag } body:nil];
    return;
  }
  NSError *error = nil;
  NSDictionary *json = [self entityBodyFor:self.object error:&error];
  if (!json) {
    [self respondError:error];
    return;
  }
  [self respondJSON:json status:200 headers:@{ @"ETag": etag }];
}

- (void)readProperty
{
  id value = [self.object valueForKey:self.attribute.name];
  NSDictionary *headers = @{ @"ETag": [self etagOf:self.object] };
  if (!value) {
    [self respondStatus:204 headers:headers body:nil];
    return;
  }
  id json = [self.coder JSONForCoreDataValue:value attribute:self.attribute];
  if (self.kind == OISTargetValue) {
    if ([value isKindOfClass:[NSData class]]) {
      NSMutableDictionary *all = [headers mutableCopy];
      all[@"Content-Type"] = @"application/octet-stream";
      [self respondStatus:200 headers:all body:value];
      return;
    }
    NSString *text = [json isKindOfClass:[NSString class]] ? json : [json description];
    [self respondText:text contentType:@"text/plain;charset=utf-8" headers:headers];
    return;
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) {
    body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@/%@", [self contextBase], [self canonicalPathOf:self.object],
                               [self.mapper propertyForAttribute:self.attribute]];
  }
  body[@"value"] = json;
  [self respondJSON:body status:200 headers:headers];
}

#pragma mark Operations

- (void)callOperation:(OISServedOperation *)operation arguments:(NSDictionary *)arguments
{
  // A function's entities can be read on from (Part 2 section 4.5.2); an
  // action's result, and a value, cannot.
  if (self.index < self.request.path.segments.count && (operation.isAction || !operation.returns.entity)) {
    [self fail:400 message:[NSString stringWithFormat:@"Nothing can follow %@", operation.name]];
    return;
  }
  self.operation = operation;
  self.operationArguments = arguments;
  self.kind = OISTargetOperation;
  [self dispatch];
}

// A JSON value as the value a parameter takes: an entity from its
// reference, anything else by its type.
- (id)valueOfJSON:(id)json parameter:(OISServedParameter *)parameter error:(NSError **)error
{
  if (!json || json == [NSNull null]) return nil;
  BOOL collection = [parameter.type hasPrefix:@"Collection("];
  NSString *element = collection ? [parameter.type substringWithRange:NSMakeRange(11, parameter.type.length - 12)] : parameter.type;
  if (parameter.entity) {
    NSArray *references = collection ? ([json isKindOfClass:[NSArray class]] ? json : nil) : @[ json ];
    if (!references) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ takes a collection", parameter.name]);
      return nil;
    }
    NSMutableArray *objects = [NSMutableArray array];
    for (id reference in references) {
      id text = [reference isKindOfClass:[NSDictionary class]] ? reference[@"@odata.id"] : reference;
      NSManagedObject *object = [self objectForReference:text error:error];
      if (!object) return nil;
      [objects addObject:object];
    }
    return collection ? objects : objects.firstObject;
  }
  if (collection) {
    if (![json isKindOfClass:[NSArray class]]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ takes a collection", parameter.name]);
      return nil;
    }
    NSMutableArray *values = [NSMutableArray array];
    for (id item in json) {
      id value = item == [NSNull null] ? item : [self.coder valueForJSON:item typeName:element];
      if (!value) {
        if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a value of %@", item, element]);
        return nil;
      }
      [values addObject:value];
    }
    return values;
  }
  // A number for a C number: a JSON number, or a string that reads as one
  // (IEEE754Compatible, INF, NaN).
  if (parameter.scalar && ![json isKindOfClass:[NSNumber class]]) {
    NSScanner *scanner = [json isKindOfClass:[NSString class]] ? [NSScanner scannerWithString:json] : nil;
    double number;
    BOOL numeric = scanner && ([scanner scanDouble:&number] && scanner.isAtEnd);
    if (!numeric && ![@[ @"INF", @"-INF", @"NaN" ] containsObject:json ?: @""]) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a value of %@", json, parameter.name]);
      return nil;
    }
  }
  id value = [self.coder valueForJSON:json typeName:element];
  if (!value || value == [NSNull null]) {
    if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is not a value of %@", json, parameter.name]);
  }
  return value == [NSNull null] ? nil : value;
}

// The arguments, by parameter, from a function's URL or an action's body;
// nil after answering with an error.
- (NSArray *)operationValues
{
  OISServedOperation *operation = self.operation;
  NSMutableDictionary *given = [NSMutableDictionary dictionary];  // name -> JSON
  NSMutableSet *names = [NSMutableSet setWithArray:[operation.parameters valueForKey:@"name"]];
  if (operation.isAction) {
    NSDictionary *body = @{};
    if (self.exchange.request.HTTPBody.length) {
      body = [self bodyJSON];
      if (!body) return nil;
    }
    for (NSString *key in body) {
      if ([key hasPrefix:@"@"]) continue;
      if (![names containsObject:key]) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ has no parameter %@", operation.name, key]];
        return nil;
      }
      given[key] = body[key];
    }
  } else {
    for (NSString *key in self.operationArguments) {
      if (![names containsObject:key]) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ has no parameter %@", operation.name, key]];
        return nil;
      }
      ODataExpression *argument = self.operationArguments[key];
      id json = nil;
      for (NSInteger depth = 0; argument.kind == ODataExpressionAlias && depth < 8; depth++) {
        json = self.JSONAliases[argument.name];
        if (json) break;
        argument = self.request.options.aliases[argument.name];
      }
      if (!json) {
        if (argument.kind != ODataExpressionLiteral) {
          [self fail:(argument ? 501 : 400) message:[NSString stringWithFormat:@"%@: an argument is a value or a parameter alias", key]];
          return nil;
        }
        json = argument.value ?: [NSNull null];
      }
      given[key] = json;
    }
  }

  NSMutableArray *values = [NSMutableArray array];
  for (OISServedParameter *parameter in operation.parameters) {
    NSError *error = nil;
    id value = [self valueOfJSON:given[parameter.name] parameter:parameter error:&error];
    if (error) {
      [self respondError:error];
      return nil;
    }
    if (!value && parameter.scalar) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ needs %@", operation.name, parameter.name]];
      return nil;
    }
    [values addObject:value ?: [NSNull null]];
  }
  return values;
}

static void OISSetScalarArgument(NSInvocation *invocation, NSInteger index, char type, NSNumber *number)
{
  switch (type) {
    case 'c': { char v = (char)number.boolValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'C': { unsigned char v = (unsigned char)number.boolValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'B': { bool v = number.boolValue; [invocation setArgument:&v atIndex:index]; break; }
    case 's': { int16_t v = number.shortValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'S': { uint16_t v = number.unsignedShortValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'i':
    case 'l': { int32_t v = number.intValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'I':
    case 'L': { uint32_t v = number.unsignedIntValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'q': { int64_t v = number.longLongValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'Q': { uint64_t v = number.unsignedLongLongValue; [invocation setArgument:&v atIndex:index]; break; }
    case 'f': { float v = number.floatValue; [invocation setArgument:&v atIndex:index]; break; }
    default: { double v = number.doubleValue; [invocation setArgument:&v atIndex:index]; break; }
  }
}

static NSNumber *OISScalarReturnValue(NSInvocation *invocation, char type)
{
  switch (type) {
    case 'c': { char v; [invocation getReturnValue:&v]; return @(v != 0); }
    case 'C': { unsigned char v; [invocation getReturnValue:&v]; return @(v != 0); }
    case 'B': { bool v; [invocation getReturnValue:&v]; return @(v); }
    case 's': { int16_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'S': { uint16_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'i':
    case 'l': { int32_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'I':
    case 'L': { uint32_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'q': { int64_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'Q': { uint64_t v; [invocation getReturnValue:&v]; return @(v); }
    case 'f': { float v; [invocation getReturnValue:&v]; return @(v); }
    default: { double v; [invocation getReturnValue:&v]; return @(v); }
  }
}

- (void)invokeOperation
{
  OISServedOperation *operation = self.operation;
  NSArray *values = [self operationValues];
  if (!values) return;

  id target;
  if (!operation.boundEntity) {
    target = self.service.serviceOperations;
  } else if (operation.boundToCollection) {
    target = NSClassFromString(operation.boundEntity.managedObjectClassName);
    NSError *error = nil;
    NSFetchRequest *collection = [NSFetchRequest fetchRequestWithEntityName:self.entity.name];
    collection.predicate = [self collectionPredicateWithFilter:NO error:&error];
    if (!collection.predicate) {
      [self respondError:error];
      return;
    }
    self.request.collectionFetchRequest = collection;
  } else {
    target = self.object;
  }
  if (!target) {
    [self fail:500 message:[NSString stringWithFormat:@"%@ has nothing to call", operation.signature]];
    return;
  }

  NSMethodSignature *signature = [target methodSignatureForSelector:operation.selector];
  NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
  invocation.target = target;
  invocation.selector = operation.selector;
  for (NSUInteger i = 0; i < operation.parameters.count; i++) {
    OISServedParameter *parameter = operation.parameters[i];
    id value = values[i] == [NSNull null] ? nil : values[i];
    if (parameter.scalar) {
      OISSetScalarArgument(invocation, (NSInteger)i + 2, parameter.scalar, value);
    } else {
      [invocation setArgument:&value atIndex:(NSInteger)i + 2];
    }
  }
  ODataReply *reply = [self replyWithAction:@selector(didInvokeOperation:)];
  [invocation setArgument:&reply atIndex:(NSInteger)operation.parameters.count + 2];
  [invocation invoke];

  id result = nil;
  if (operation.returns.scalar) {
    result = OISScalarReturnValue(invocation, operation.returns.scalar);
  } else if (operation.returns) {
    __unsafe_unretained id returned = nil;
    [invocation getReturnValue:&returned];
    result = returned;
  }
  [reply returned:result];
}

// A function's entities, read as any collection or entity: the rest of the
// path, and the query options.
- (void)composeOn:(id)result
{
  OISServedOperation *operation = self.operation;
  self.operation = nil;
  NSEntityDescription *entity = operation.returns.entity;
  ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
  if (!handler) {
    [self fail:500 message:[NSString stringWithFormat:@"%@ returns entities of no entity set", operation.signature]];
    return;
  }
  self.handler = handler;
  self.parent = nil;
  self.navigation = nil;
  self.referrer = nil;
  self.referrerNavigation = nil;
  if ([operation.returns.type hasPrefix:@"Collection("]) {
    NSArray *items = [result isKindOfClass:[NSSet class]] ? [result allObjects]
                   : [result isKindOfClass:[NSOrderedSet class]] ? [result array]
                   : [result isKindOfClass:[NSArray class]] ? result : nil;
    if (!items && result && result != [NSNull null]) {
      [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not a collection", operation.signature, [result class]]];
      return;
    }
    for (id item in items) {
      if (![item isKindOfClass:[NSManagedObject class]]) {
        [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not an entity", operation.signature, [item class]]];
        return;
      }
    }
    self.members = items ?: @[];
    self.entity = entity;
    self.object = nil;
    self.kind = OISTargetCollection;
  } else {
    if (!result || result == [NSNull null]) {
      [self respondStatus:204 headers:@{} body:nil];
      return;
    }
    if (![result isKindOfClass:[NSManagedObject class]]) {
      [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not an entity", operation.signature, [result class]]];
      return;
    }
    self.object = result;
    self.entity = [result entity];
    self.kind = OISTargetEntity;
  }
  [self walk];
}

- (void)didInvokeOperation:(ODataReply *)reply
{
  OISServedOperation *operation = self.operation;
  if (reply.error) {
    [self.request.context rollback];
    [self respondError:reply.error];
    return;
  }
  // An action may have changed things; a function has no business to.
  if (operation.isAction && self.request.context.hasChanges && ![self save]) return;
  if (!operation.isAction) [self.request.context rollback];
  if (!operation.isAction && operation.returns.entity) {
    [self composeOn:reply.result];
    return;
  }

  id result = reply.result;
  OISServedParameter *returns = operation.returns;
  if (!returns || !result || result == [NSNull null]) {
    [self respondStatus:204 headers:@{} body:nil];
    return;
  }
  BOOL collection = [returns.type hasPrefix:@"Collection("];
  NSString *element = collection ? [returns.type substringWithRange:NSMakeRange(11, returns.type.length - 12)] : returns.type;
  NSArray *items = nil;
  if (collection) {
    if ([result isKindOfClass:[NSArray class]]) items = result;
    else if ([result isKindOfClass:[NSSet class]]) items = [result allObjects];
    else if ([result isKindOfClass:[NSOrderedSet class]]) items = [result array];
    if (!items) {
      [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not a collection", operation.signature, [result class]]];
      return;
    }
  }
  NSError *error = nil;
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  BOOL none = [self.metadataLevel isEqualToString:@"none"];

  if (returns.entity) {
    NSEntityDescription *root = OISRootEntity(returns.entity);
    for (id item in items ?: @[ result ]) {
      if (![item isKindOfClass:[NSManagedObject class]]) {
        [self fail:500 message:[NSString stringWithFormat:@"%@ returned %@, not an entity", operation.signature, [item class]]];
        return;
      }
    }
    if (!collection) {
      NSDictionary *json = [self entityBodyFor:result error:&error];
      if (!json) {
        [self respondError:error];
        return;
      }
      [self respondJSON:json status:200 headers:@{ @"ETag": [self etagOf:result] }];
      return;
    }
    NSMutableArray *values = [NSMutableArray array];
    for (NSManagedObject *item in items) {
      NSDictionary *json = [self JSONForObject:item options:self.request.options expected:returns.entity error:&error];
      if (!json) {
        [self respondError:error];
        return;
      }
      [values addObject:json];
    }
    if (!none) {
      body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@%@", [self contextBase], [self.service entitySetForEntity:root],
                                 [self selectListForOptions:self.request.options]];
    }
    body[@"value"] = values;
    [self respondJSON:body status:200 headers:nil];
    return;
  }

  if (collection) {
    NSMutableArray *values = [NSMutableArray array];
    for (id item in items) [values addObject:[self.coder JSONForValue:(item == [NSNull null] ? nil : item) typeName:element]];
    body[@"value"] = values;
  } else {
    body[@"value"] = [self.coder JSONForValue:result typeName:element];
  }
  if (!none) body[@"@odata.context"] = [NSString stringWithFormat:@"%@#%@", [self contextBase], returns.type];
  [self respondJSON:body status:200 headers:nil];
}

#pragma mark Types

// The entity a qualified type name stands for (Default.Manager), among
// those the service serves; nil when none.
- (NSEntityDescription *)entityForTypeName:(NSString *)name
{
  for (NSEntityDescription *entity in self.service.writer.entities) {
    if ([[self.service.writer typeNameForEntity:entity] isEqualToString:name]) return entity;
  }
  return nil;
}

// Collections of a derived type are written with a cast after their set:
// Employees/Default.Manager.
- (NSString *)castSuffixFor:(NSEntityDescription *)entity
{
  return entity == OISRootEntity(entity) ? @"" : [@"/" stringByAppendingString:[self.service.writer typeNameForEntity:entity]];
}

#pragma mark References and single properties

- (void)readReference
{
  if (self.referencesCollection) {
    self.referencesOnly = YES;
    [self readCollection];
    return;
  }
  if (!self.object) {
    [self respondStatus:204 headers:@{} body:nil];
    return;
  }
  NSMutableDictionary *body = [NSMutableDictionary dictionary];
  if (![self.metadataLevel isEqualToString:@"none"]) body[@"@odata.context"] = [NSString stringWithFormat:@"%@#$ref", [self contextBase]];
  body[@"@odata.id"] = [self canonicalPathOf:self.object];
  [self respondJSON:body status:200 headers:nil];
}

// PUT a to-one reference, POST one to a collection, DELETE either (Part 1
// section 11.4.6): an update of the entity that holds the relationship.
- (void)writeReference
{
  NSString *method = self.request.method;
  NSManagedObject *holder = self.referencesCollection ? self.parent : self.referrer;
  NSRelationshipDescription *relationship = self.referencesCollection ? self.navigation : self.referrerNavigation;
  if (!holder || !relationship) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  ODataEntitySetHandler *handler = [self.service handlerForEntity:holder.entity];
  if (!handler.allowsUpdate) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  if (![self ifMatchAllows:holder]) {
    [self fail:412 message:@"The entity has changed since that ETag"];
    return;
  }
  NSManagedObject *target = nil;
  if (![method isEqualToString:@"DELETE"]) {
    NSDictionary *body = [self bodyJSON];
    if (!body) return;
    NSError *error = nil;
    target = [self objectForReference:body[@"@odata.id"] error:&error];
    if (!target) {
      [self respondError:error];
      return;
    }
  } else if (self.referencesCollection) {
    if (!self.referenceID) {
      [self fail:400 message:@"Name the entity to remove with $id"];
      return;
    }
    NSError *error = nil;
    target = [self objectForReference:self.referenceID error:&error];
    if (!target) {
      [self respondError:error];
      return;
    }
  } else {
    target = self.object;
  }
  if (target && ![target.entity isKindOfEntity:relationship.destinationEntity]) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ does not refer to a %@", [self.mapper propertyForRelationship:relationship], target.entity.name]];
    return;
  }

  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  if (relationship.isToMany) {
    BOOL adding = [method isEqualToString:@"POST"] && self.referencesCollection;
    BOOL removing = [method isEqualToString:@"DELETE"];
    if (!adding && !removing) {
      [self methodNotAllowed:self.referencesCollection ? @[ @"GET", @"POST", @"DELETE" ] : @[ @"GET", @"DELETE" ]];
      return;
    }
    NSMutableSet *members = [[holder valueForKey:relationship.name] mutableCopy] ?: [NSMutableSet set];
    if (removing && ![members containsObject:target]) {
      [self fail:404 message:@"The entity is not in the collection"];
      return;
    }
    if (adding) [members addObject:target];
    else [members removeObject:target];
    values[relationship.name] = members;
  } else {
    if (self.referencesCollection || [method isEqualToString:@"POST"]) {
      [self methodNotAllowed:@[ @"GET", @"PUT", @"DELETE" ]];
      return;
    }
    values[relationship.name] = [method isEqualToString:@"DELETE"] ? [NSNull null] : target;
  }
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:holder.entity];
  if (version) values[version.name] = @([[holder valueForKey:version.name] longLongValue] + 1);
  self.object = holder;
  ODataReply *reply = [self replyWithAction:@selector(didUpdate:)];
  [reply returned:[handler updateObject:holder values:values request:self.request reply:reply]];
}

// PUT or PATCH one property ({"value": ...}, or the raw text of its
// $value), DELETE it to null (Part 1 sections 11.4.9.1-2).
- (void)writeProperty
{
  if (!self.handler.allowsUpdate) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  if (![self ifMatchAllows:self.object]) {
    [self fail:412 message:@"The entity has changed since that ETag"];
    return;
  }
  NSAttributeDescription *attribute = self.attribute;
  NSString *wire = [self.mapper propertyForAttribute:attribute];
  if ([[self.mapper keyAttributesForEntity:OISRootEntity(self.object.entity)] containsObject:attribute]) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ is the key, and cannot change", wire]];
    return;
  }
  id json = [NSNull null];
  if (![self.request.method isEqualToString:@"DELETE"]) {
    if (self.kind == OISTargetValue) {
      NSData *data = self.exchange.request.HTTPBody ?: [NSData data];
      json = attribute.attributeType == NSBinaryDataAttributeType ? (id)data : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      if (!json) {
        [self fail:400 message:@"The body is not text"];
        return;
      }
    } else {
      NSDictionary *body = [self bodyJSON];
      if (!body) return;
      if (!body[@"value"]) {
        [self fail:400 message:@"A property is written as {\"value\": ...}"];
        return;
      }
      json = body[@"value"];
    }
  }
  id value = json;
  if (json != [NSNull null] && ![json isKindOfClass:[NSData class]]) {
    value = [self.coder coreDataValueForJSON:json attribute:attribute];
    if (!value || value == [NSNull null]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value of %@", json, wire]];
      return;
    }
  }
  NSMutableDictionary *values = [NSMutableDictionary dictionaryWithObject:value forKey:attribute.name];
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:self.object.entity];
  if (version) values[version.name] = @([[self.object valueForKey:version.name] longLongValue] + 1);
  ODataReply *reply = [self replyWithAction:@selector(didUpdate:)];
  [reply returned:[self.handler updateObject:self.object values:values request:self.request reply:reply]];
}

#pragma mark Writes

- (NSDictionary *)bodyJSON
{
  NSString *type = [self.request valueForHeader:@"Content-Type"].lowercaseString;
  if (type.length && ![type hasPrefix:@"application/json"]) {
    [self fail:415 message:@"The body must be application/json"];
    return nil;
  }
  NSData *data = self.exchange.request.HTTPBody;
  id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
  if (![json isKindOfClass:[NSDictionary class]]) {
    [self fail:400 message:@"The body must be a JSON object"];
    return nil;
  }
  return ODataNormalizedControlInformation(json, [self.request valueForHeader:@"OData-Version"] ?: self.request.version);
}

// The object an entity id names: Categories(1), or the whole URL.
- (NSManagedObject *)objectForReference:(id)reference error:(NSError **)error
{
  if (![reference isKindOfClass:[NSString class]]) {
    if (error) *error = ODataServiceError(400, @"An entity reference must be a string");
    return nil;
  }
  NSString *text = reference;
  NSString *root = [self rootString];
  NSString *rootPath = self.service.serviceRoot.path ?: @"/";
  if (![rootPath hasSuffix:@"/"]) rootPath = [rootPath stringByAppendingString:@"/"];
  if ([text hasPrefix:root]) text = [text substringFromIndex:root.length];
  else if ([text hasPrefix:rootPath]) text = [text substringFromIndex:rootPath.length];
  ODataResourcePath *path = [ODataResourcePath pathWithString:OISPercentDecoded(text) error:NULL];
  ODataPathSegment *first = path.segments.firstObject;
  ODataEntitySetHandler *handler = first ? [self.service handlerForEntitySet:first.name] : nil;
  NSDictionary *parts = first.keys;
  NSEntityDescription *saved = self.entity;
  self.entity = handler.entity;
  if (handler && !parts && path.segments.count == 2) parts = @{ @"": [self literalForKeySegment:path.segments[1].name] };
  NSDictionary *key = handler && parts && path.segments.count <= 2 ? [self keyFromPartsQuietly:parts entity:handler.entity] : nil;
  self.entity = saved;
  if (!key) {
    if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is not an entity of this service", reference]);
    return nil;
  }
  NSMutableArray *conditions = [NSMutableArray array];
  for (NSString *name in key) {
    [conditions addObject:[NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:name]
                                                             rightExpression:[NSExpression expressionForConstantValue:key[name]]
                                                                    modifier:NSDirectPredicateModifier
                                                                        type:NSEqualToPredicateOperatorType
                                                                     options:0]];
  }
  NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
  if (visible) [conditions addObject:visible];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:handler.entity.name];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:conditions];
  fetch.fetchLimit = 1;
  NSManagedObject *object = [[self.request.context executeFetchRequest:fetch error:NULL] firstObject];
  if (!object && error) *error = ODataServiceError(400, [NSString stringWithFormat:@"There is no %@", reference]);
  return object;
}

- (NSDictionary *)keyFromPartsQuietly:(NSDictionary *)parts entity:(NSEntityDescription *)entity
{
  BOOL wasDone = self.done;
  self.done = YES;  // a reference that does not resolve is the caller's to report
  NSDictionary *key = [self keyFromParts:parts entity:entity];
  self.done = wasDone;
  return key;
}

// A body's properties as Core Data values, by property name; relationships
// from @odata.bind, and from nested entities: created with a new object (a
// deep insert), or, for an object, created, updated or unlinked (a deep
// update, with Nav@delta too).
- (NSMutableDictionary *)valuesFromBody:(NSDictionary *)body entity:(NSEntityDescription *)entity forObject:(NSManagedObject *)object
{
  NSMutableDictionary *values = [NSMutableDictionary dictionary];
  for (NSString *key in body) {
    if ([key hasPrefix:@"@"]) continue;
    NSRange at = [key rangeOfString:@"@"];
    NSString *name = at.location == NSNotFound ? key : [key substringToIndex:at.location];
    NSString *annotation = at.location == NSNotFound ? nil : [key substringFromIndex:at.location + 1];
    if ([annotation hasPrefix:@"odata."]) annotation = [annotation substringFromIndex:6];
    if (annotation && ![annotation isEqualToString:@"bind"] && ![annotation isEqualToString:@"delta"]) continue;
    NSPropertyDescription *property = [self.mapper propertyForWireName:name entity:entity];
    if (!property) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ has no property %@", entity.name, name]];
      return nil;
    }
    id value = body[key];
    if ([property isKindOfClass:[NSAttributeDescription class]]) {
      if (annotation) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ is not a navigation property", name]];
        return nil;
      }
      NSAttributeDescription *attribute = (NSAttributeDescription *)property;
      if (value == [NSNull null]) {
        values[attribute.name] = [NSNull null];
        continue;
      }
      id converted = [self.coder coreDataValueForJSON:value attribute:attribute];
      if (!converted || converted == [NSNull null]) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value of %@", value, name]];
        return nil;
      }
      values[attribute.name] = converted;
      continue;
    }
    NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
    if ([annotation isEqualToString:@"delta"]) {
      if (!object || !relationship.isToMany || ![value isKindOfClass:[NSArray class]]) {
        [self fail:400 message:[NSString stringWithFormat:@"%@ is an array of changes to a collection of an existing entity", key]];
        return nil;
      }
      NSSet *members = [self applyDelta:value to:object relationship:relationship];
      if (!members) return nil;
      values[relationship.name] = members;
      continue;
    }
    if (!annotation) {
      // A deep insert: the related entities are created with this one. A
      // deep update: they are these, each one there updated, or created.
      id related = object ? [self nestedForUpdate:value relationship:relationship] : [self insertNested:value relationship:relationship];
      if (!related) return nil;
      values[relationship.name] = related;
      continue;
    }
    NSError *error = nil;
    if (!relationship.isToMany) {
      if (value == [NSNull null]) {
        values[relationship.name] = [NSNull null];
        continue;
      }
      NSManagedObject *target = [self objectForReference:value error:&error];
      if (!target) {
        [self respondError:error];
        return nil;
      }
      values[relationship.name] = target;
      continue;
    }
    if (![value isKindOfClass:[NSArray class]]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@@odata.bind takes an array", name]];
      return nil;
    }
    // An update adds to a collection, as 4.0 has it; an insert sets it.
    NSMutableSet *members = object ? [[object valueForKey:relationship.name] mutableCopy] : [NSMutableSet set];
    for (id reference in value) {
      NSManagedObject *target = [self objectForReference:reference error:&error];
      if (!target) {
        [self respondError:error];
        return nil;
      }
      [members addObject:target];
    }
    values[relationship.name] = members;
  }
  return values;
}

// The entities of a deep insert (Part 1 section 11.4.2.2): each through its
// set's handler, nested ones first. An object, or a set of them.
- (id)insertNested:(id)value relationship:(NSRelationshipDescription *)relationship
{
  NSString *name = [self.mapper propertyForRelationship:relationship];
  NSArray *bodies = relationship.isToMany ? ([value isKindOfClass:[NSArray class]] ? value : nil)
                                          : ([value isKindOfClass:[NSDictionary class]] ? @[ value ] : nil);
  if (!bodies) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ takes %@", name, relationship.isToMany ? @"an array of entities" : @"an entity"]];
    return nil;
  }
  NSMutableSet *created = [NSMutableSet set];
  for (NSDictionary *body in bodies) {
    NSManagedObject *object = [self insertNestedBody:body relationship:relationship];
    if (!object) return nil;
    [created addObject:object];
  }
  return relationship.isToMany ? created : created.anyObject;
}

// The entity type a nested body names with @odata.type, of the
// relationship's destination; the destination when it names none.
- (NSEntityDescription *)entityOfNested:(NSDictionary *)body relationship:(NSRelationshipDescription *)relationship
{
  NSString *name = [self.mapper propertyForRelationship:relationship];
  if (![body isKindOfClass:[NSDictionary class]]) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ takes entities", name]];
    return nil;
  }
  NSEntityDescription *entity = relationship.destinationEntity;
  id type = body[@"@odata.type"];
  if ([type isKindOfClass:[NSString class]]) {
    NSEntityDescription *named = [self entityForTypeName:ODataTypeNameFromControlInformation(type)];
    if (!named || ![named isKindOfEntity:entity]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is not a type of %@", type, name]];
      return nil;
    }
    entity = named;
  }
  return entity;
}

- (NSManagedObject *)insertNestedBody:(NSDictionary *)body relationship:(NSRelationshipDescription *)relationship
{
  NSEntityDescription *entity = [self entityOfNested:body relationship:relationship];
  if (!entity) return nil;
  ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
  if (!handler || !handler.allowsInsert) {
    [self fail:(handler ? 405 : 400) message:[NSString stringWithFormat:@"%@ cannot be inserted here", entity.name]];
    return nil;
  }
  NSMutableDictionary *values = [self valuesFromBody:body entity:entity forObject:nil];
  if (!values || ![self fillKeys:values entity:entity]) return nil;
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:entity];
  if (version) values[version.name] = @1;
  ODataReply *reply = [self nestedCallOn:entity what:@"created" call:^id(ODataReply *nested) {
    return [handler insertObjectWithValues:values request:self.request reply:nested];
  }];
  if (!reply) return nil;
  if (![reply.result isKindOfClass:[NSManagedObject class]]) {
    [self respondError:ODataServiceError(500, [NSString stringWithFormat:@"A nested %@ was not created", entity.name])];
    return nil;
  }
  return reply.result;
}

// A handler's answer, now: a nested entity's change cannot wait for one
// that answers later. nil, answered, when it fails.
- (ODataReply *)nestedCallOn:(NSEntityDescription *)entity what:(NSString *)what call:(id (^)(ODataReply *reply))call
{
  NSEntityDescription *requested = self.request.entity;
  self.request.entity = entity;
  ODataReply *reply = [self replyWithAction:@selector(didFinishNested:)];
  reply.timeout = 0;
  self.nestedReply = nil;
  [reply returned:call(reply)];
  self.request.entity = requested;
  if (reply.deferred) {
    [self fail:501 message:[NSString stringWithFormat:@"%@'s handler answers later, which a nested entity cannot wait for", entity.name]];
    return nil;
  }
  if (reply.error) {
    [self respondError:reply.error];
    return nil;
  }
  return reply;
}

- (void)didFinishNested:(ODataReply *)reply
{
  self.nestedReply = reply;
}

#pragma mark Deep updates

// A deep update's nested entities (Part 1 section 11.4.3.1): a to-one's
// entity, or null; a to-many's full set of entities, those it had and does
// not name any more unlinked (not deleted).
- (id)nestedForUpdate:(id)value relationship:(NSRelationshipDescription *)relationship
{
  NSString *name = [self.mapper propertyForRelationship:relationship];
  if (!relationship.isToMany) {
    if (value == [NSNull null]) return value;
    if (![value isKindOfClass:[NSDictionary class]]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ takes an entity or null", name]];
      return nil;
    }
    return [self upsertNested:value relationship:relationship];
  }
  if (![value isKindOfClass:[NSArray class]]) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ takes an array of entities", name]];
    return nil;
  }
  NSMutableSet *members = [NSMutableSet set];
  for (id body in value) {
    NSManagedObject *member = [self upsertNested:body relationship:relationship];
    if (!member) return nil;
    [members addObject:member];
  }
  return members;
}

// Nav@delta: the collection's members changed, added (created or updated
// as they come) and, with @removed, unlinked, or deleted for the reason
// "deleted".
- (NSSet *)applyDelta:(NSArray *)changes to:(NSManagedObject *)object relationship:(NSRelationshipDescription *)relationship
{
  NSMutableSet *members = [[object valueForKey:relationship.name] mutableCopy] ?: [NSMutableSet set];
  for (NSDictionary *change in changes) {
    if (![change isKindOfClass:[NSDictionary class]]) {
      [self fail:400 message:@"A delta holds entities"];
      return nil;
    }
    id removed = change[@"@removed"] ?: change[@"@odata.removed"];
    if (!removed) {
      NSManagedObject *member = [self upsertNested:change relationship:relationship];
      if (!member) return nil;
      [members addObject:member];
      continue;
    }
    NSEntityDescription *entity = [self entityOfNested:change relationship:relationship];
    if (!entity) return nil;
    NSError *error = nil;
    NSManagedObject *member = [self existingNested:change entity:entity error:&error];
    if (!member) {
      [self respondError:error ?: ODataServiceError(400, @"A removed entity names no entity: give its @id or its key")];
      return nil;
    }
    [members removeObject:member];
    NSString *reason = [removed isKindOfClass:[NSDictionary class]] ? removed[@"reason"] : nil;
    if ([reason isEqual:@"deleted"]) {
      ODataEntitySetHandler *handler = [self.service handlerForEntity:member.entity];
      if (!handler.allowsDelete) {
        [self fail:405 message:[NSString stringWithFormat:@"%@ cannot be deleted here", member.entity.name]];
        return nil;
      }
      if (![self nestedCallOn:member.entity what:@"deleted" call:^id(ODataReply *nested) {
            [handler deleteObject:member request:self.request reply:nested];
            return nil;
          }]) {
        return nil;
      }
    }
  }
  return members;
}

// The entity a nested body names: by @id, or by its key; nil, with no
// error, when it names none (and one is to be created).
- (NSManagedObject *)existingNested:(NSDictionary *)body entity:(NSEntityDescription *)entity error:(NSError **)error
{
  id reference = body[@"@id"] ?: body[@"@odata.id"];
  if ([reference isKindOfClass:[NSString class]]) return [self objectForReference:reference error:error];
  NSMutableArray *conditions = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(entity)]) {
    id given = body[[self.mapper propertyForAttribute:attribute]];
    id value = given && given != [NSNull null] ? [self.coder coreDataValueForJSON:given attribute:attribute] : nil;
    if (!value || value == [NSNull null]) return nil;
    [conditions addObject:[NSComparisonPredicate predicateWithLeftExpression:[NSExpression expressionForKeyPath:attribute.name]
                                                             rightExpression:[NSExpression expressionForConstantValue:value]
                                                                    modifier:NSDirectPredicateModifier
                                                                        type:NSEqualToPredicateOperatorType
                                                                     options:0]];
  }
  ODataEntitySetHandler *handler = [self.service handlerForEntity:entity];
  NSPredicate *visible = [handler predicateForVisibleObjectsInRequest:self.request];
  if (visible) [conditions addObject:visible];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:OISRootEntity(entity).name];
  fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:conditions];
  fetch.fetchLimit = 1;
  return [[self.request.context executeFetchRequest:fetch error:NULL] firstObject];
}

// A nested entity of a deep update: the one it names updated with the rest
// of it, as by PATCH; one it does not name, created.
- (NSManagedObject *)upsertNested:(NSDictionary *)body relationship:(NSRelationshipDescription *)relationship
{
  NSEntityDescription *entity = [self entityOfNested:body relationship:relationship];
  if (!entity) return nil;
  NSError *error = nil;
  NSManagedObject *existing = [self existingNested:body entity:entity error:&error];
  if (error) {
    [self respondError:error];
    return nil;
  }
  if (!existing) return [self insertNestedBody:body relationship:relationship];
  if (body[@"@odata.type"] && existing.entity != entity) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ is a %@", [self canonicalPathOf:existing], existing.entity.name]];
    return nil;
  }
  id etag = body[@"@odata.etag"] ?: body[@"@etag"];
  if ([etag isKindOfClass:[NSString class]] && ![etag isEqualToString:[self etagOf:existing]]) {
    [self fail:412 message:[NSString stringWithFormat:@"%@ has changed since that ETag", [self canonicalPathOf:existing]]];
    return nil;
  }
  BOOL changes = NO;
  NSMutableDictionary *values = [self updateValuesFromBody:body object:existing replace:NO changes:&changes];
  if (!values) return nil;
  if (!changes) return existing;  // only named: linked, not changed
  ODataEntitySetHandler *handler = [self.service handlerForEntity:existing.entity];
  if (!handler.allowsUpdate) {
    [self fail:405 message:[NSString stringWithFormat:@"%@ cannot be updated here", existing.entity.name]];
    return nil;
  }
  ODataReply *reply = [self nestedCallOn:existing.entity what:@"updated" call:^id(ODataReply *nested) {
    return [handler updateObject:existing values:values request:self.request reply:nested];
  }];
  return reply ? existing : nil;
}

// What a deep insert's body nested, as $expand: the response shows it.
- (NSString *)expansionOfBody:(NSDictionary *)body entity:(NSEntityDescription *)entity
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *key in [body.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([key rangeOfString:@"@"].location != NSNotFound) continue;
    NSPropertyDescription *property = [self.mapper propertyForWireName:key entity:entity];
    if (![property isKindOfClass:[NSRelationshipDescription class]]) continue;
    NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
    id value = body[key];
    NSDictionary *first = [value isKindOfClass:[NSArray class]] ? [value firstObject] : value;
    NSString *inner = [first isKindOfClass:[NSDictionary class]] ? [self expansionOfBody:first entity:relationship.destinationEntity] : nil;
    [items addObject:inner.length ? [NSString stringWithFormat:@"%@($expand=%@)", key, inner] : key];
  }
  return [items componentsJoinedByString:@","];
}

- (BOOL)fillKeys:(NSMutableDictionary *)values entity:(NSEntityDescription *)entity
{
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(entity)]) {
    id given = values[attribute.name];
    if (given && given != [NSNull null]) continue;
    switch (attribute.attributeType) {
      case NSInteger16AttributeType:
      case NSInteger32AttributeType:
      case NSInteger64AttributeType: {
        // One more than the largest so far.
        NSFetchRequest *last = [NSFetchRequest fetchRequestWithEntityName:OISRootEntity(entity).name];
        last.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:attribute.name ascending:NO] ];
        last.fetchLimit = 1;
        NSManagedObject *top = [[self.request.context executeFetchRequest:last error:NULL] firstObject];
        values[attribute.name] = @([[top valueForKey:attribute.name] longLongValue] + 1);
        break;
      }
      case NSStringAttributeType:
        values[attribute.name] = [NSUUID UUID].UUIDString;
        break;
      default:
        if (attribute.attributeType == NSUUIDAttributeType) {
          values[attribute.name] = [NSUUID UUID];
          break;
        }
        [self fail:400 message:[NSString stringWithFormat:@"A new %@ needs its %@", entity.name, [self.mapper propertyForAttribute:attribute]]];
        return NO;
    }
  }
  return YES;
}

- (void)insert
{
  if (!self.handler.allowsInsert) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  NSDictionary *body = [self bodyJSON];
  if (!body) return;
  NSEntityDescription *entity = self.entity;
  id type = body[@"@odata.type"];
  if ([type isKindOfClass:[NSString class]]) {
    NSEntityDescription *named = [self.mapper entity:entity forTypeName:type];
    if ([[self.service.writer typeNameForEntity:named] isEqualToString:ODataTypeNameFromControlInformation(type)]) {
      entity = named;
    } else {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is not a type of %@", type, [self setName]]];
      return;
    }
  }
  if (entity.isAbstract) {
    [self fail:400 message:[NSString stringWithFormat:@"%@ is abstract: name a derived type with @odata.type", entity.name]];
    return;
  }
  NSMutableDictionary *values = [self valuesFromBody:body entity:entity forObject:nil];
  if (!values || ![self fillKeys:values entity:entity]) return;
  NSString *expansion = [self expansionOfBody:body entity:entity];
  if (expansion.length) self.responseOptions = [ODataQueryOptions optionsWithQuery:@{ @"$expand": expansion } error:NULL];
  // Inserted through a navigation property: related to its parent.
  if (self.parent && self.navigation.inverseRelationship) {
    NSRelationshipDescription *inverse = self.navigation.inverseRelationship;
    values[inverse.name] = inverse.isToMany ? [NSSet setWithObject:self.parent] : self.parent;
  }
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:entity];
  if (version) values[version.name] = @1;
  self.request.entity = entity;
  ODataReply *reply = [self replyWithAction:@selector(didInsert:)];
  [reply returned:[self.handler insertObjectWithValues:values request:self.request reply:reply]];
}

- (void)didInsert:(ODataReply *)reply
{
  NSManagedObject *object = reply.result;
  if (reply.error || !object) {
    [self.request.context rollback];
    [self respondError:reply.error ?: ODataServiceError(500, @"The entity was not created")];
    return;
  }
  // A to-many parent whose inverse is not modelled still gets the new row.
  if (self.parent && self.navigation && !self.navigation.inverseRelationship) {
    [[self.parent mutableSetValueForKey:self.navigation.name] addObject:object];
  }
  if (![self save]) return;
  NSString *location = [[self rootString] stringByAppendingString:[self canonicalPathOf:object]];
  NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{ @"Location": location, @"ETag": [self etagOf:object] }];
  if ([self.request.preferences[@"return"] isEqualToString:@"minimal"]) {
    headers[@"OData-EntityId"] = location;
    headers[@"Preference-Applied"] = @"return=minimal";
    [self respondStatus:204 headers:headers body:nil];
    return;
  }
  if ([self.request.preferences[@"return"] isEqualToString:@"representation"]) headers[@"Preference-Applied"] = @"return=representation";
  NSError *error = nil;
  NSDictionary *json = [self entityBodyFor:object error:&error];
  if (!json) {
    [self respondError:error];
    return;
  }
  [self respondJSON:json status:201 headers:headers];
}

- (void)updateReplacing:(BOOL)replace
{
  if (!self.handler.allowsUpdate) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  if (![self ifMatchAllows:self.object]) {
    [self fail:412 message:@"The entity has changed since that ETag"];
    return;
  }
  NSDictionary *body = [self bodyJSON];
  if (!body) return;
  NSMutableDictionary *values = [self updateValuesFromBody:body object:self.object replace:replace changes:NULL];
  if (!values) return;
  NSString *expansion = [self expansionOfBody:body entity:self.object.entity];
  if (expansion.length) self.responseOptions = [ODataQueryOptions optionsWithQuery:@{ @"$expand": expansion } error:NULL];
  ODataReply *reply = [self replyWithAction:@selector(didUpdate:)];
  [reply returned:[self.handler updateObject:self.object values:values request:self.request reply:reply]];
}

// An update's values from its body: the key as it is, for PUT the rest
// back to its default, and the version one more. changes: whether the body
// changes anything.
- (NSMutableDictionary *)updateValuesFromBody:(NSDictionary *)body object:(NSManagedObject *)object replace:(BOOL)replace changes:(BOOL *)changes
{
  NSMutableDictionary *values = [self valuesFromBody:body entity:object.entity forObject:object];
  if (!values) return nil;
  for (NSAttributeDescription *attribute in [self.mapper keyAttributesForEntity:OISRootEntity(object.entity)]) {
    id value = values[attribute.name];
    if (value && ![value isEqual:[object valueForKey:attribute.name]]) {
      [self fail:400 message:[NSString stringWithFormat:@"%@ is the key, and cannot change", [self.mapper propertyForAttribute:attribute]]];
      return nil;
    }
    [values removeObjectForKey:attribute.name];
  }
  NSAttributeDescription *version = [self.service versionAttributeOfEntity:object.entity];
  if (replace) {
    // PUT: what the body leaves out goes back to its default.
    NSArray *key = [self.mapper keyAttributesForEntity:OISRootEntity(object.entity)];
    for (NSAttributeDescription *attribute in [self servedAttributesOf:object.entity]) {
      if ([key containsObject:attribute] || attribute == version || values[attribute.name]) continue;
      values[attribute.name] = attribute.defaultValue ?: [NSNull null];
    }
  }
  if (changes) *changes = values.count > 0;
  if (version) values[version.name] = @([[object valueForKey:version.name] longLongValue] + 1);
  return values;
}

- (void)didUpdate:(ODataReply *)reply
{
  NSManagedObject *object = reply.result;
  if (reply.error || !object) {
    [self.request.context rollback];
    [self respondError:reply.error ?: ODataServiceError(500, @"The entity was not updated")];
    return;
  }
  if (![self save]) return;
  NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithDictionary:@{ @"ETag": [self etagOf:object] }];
  if ([self.request.preferences[@"return"] isEqualToString:@"representation"]) {
    headers[@"Preference-Applied"] = @"return=representation";
    NSError *error = nil;
    NSDictionary *json = [self entityBodyFor:object error:&error];
    if (!json) {
      [self respondError:error];
      return;
    }
    [self respondJSON:json status:200 headers:headers];
    return;
  }
  [self respondStatus:204 headers:headers body:nil];
}

- (void)remove
{
  if (!self.handler.allowsDelete) {
    [self methodNotAllowed:@[ @"GET" ]];
    return;
  }
  if (![self ifMatchAllows:self.object]) {
    [self fail:412 message:@"The entity has changed since that ETag"];
    return;
  }
  ODataReply *reply = [self replyWithAction:@selector(didDelete:)];
  [self.handler deleteObject:self.object request:self.request reply:reply];
  [reply returned:nil];
}

- (void)didDelete:(ODataReply *)reply
{
  if (reply.error) {
    [self.request.context rollback];
    [self respondError:reply.error];
    return;
  }
  if (![self save]) return;
  [self respondStatus:204 headers:@{} body:nil];
}

- (BOOL)save
{
  if (!self.saves) return YES;
  NSError *error = nil;
  if ([self.request.context save:&error]) return YES;
  [self.request.context rollback];
  [self respondError:error];
  return NO;
}

@end

#pragma mark - The service

@implementation ODataService

- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator serviceRoot:(NSURL *)serviceRoot
{
  self = [super init];
  if (!self) return nil;
  _coordinator = coordinator;
  _model = coordinator.managedObjectModel;
  _serviceRoot = [serviceRoot copy];
  _mapper = [[ODataPropertyMapper alloc] init];
  _namespaceName = @"Default";
  _containerName = @"Container";
  _maxVersion = @"4.01";
  _replyTimeout = 60;
  _handlers = [NSMutableDictionary dictionary];
  _metadataByVersion = [NSMutableDictionary dictionary];
  return self;
}

// $metadata from the model, read back as the schema the mapper answers
// from; and a handler for every set that has none.
- (void)prepare
{
  @synchronized (self) {
    if (self.prepared) return;
    ODataMetadataWriter *writer = [[ODataMetadataWriter alloc] initWithModel:self.model mapper:self.mapper];
    writer.namespaceName = self.namespaceName;
    writer.containerName = self.containerName;
    NSMutableDictionary *concurrency = [NSMutableDictionary dictionary];
    for (NSEntityDescription *entity in writer.entities) {
      NSAttributeDescription *version = [self versionAttributeOfEntity:entity];
      if (version && !entity.superentity) concurrency[entity.name] = version;
    }
    writer.concurrencyAttributes = concurrency;
    OISOperationCatalog *catalog = [[OISOperationCatalog alloc] initWithModel:self.model
                                                                       mapper:self.mapper
                                                                       writer:writer
                                                            serviceOperations:self.serviceOperations];
    writer.additionalSchemaXML = catalog.schemaXML;
    writer.additionalContainerXML = catalog.containerXML;
    self.catalog = catalog;
    NSString *xml = [writer XMLStringForVersion:@"4.01"];
    ODataSchema *schema = [ODataSchema schemaWithData:[xml dataUsingEncoding:NSUTF8StringEncoding] error:NULL];
    if (schema) self.mapper.schema = schema;
    self.writer = writer;
    self.predicates = [[ODataPredicateBuilder alloc] initWithMapper:self.mapper];
    NSMutableDictionary *types = [NSMutableDictionary dictionary];
    for (NSEntityDescription *entity in writer.entities) types[[writer typeNameForEntity:entity]] = entity;
    self.predicates.entitiesByTypeName = types;
    for (NSEntityDescription *entity in writer.entities) {
      if (entity.superentity) continue;
      NSString *set = [self.mapper entitySetForEntity:entity];
      ODataEntitySetHandler *handler = self.handlers[set];
      if (!handler) {
        handler = [[ODataEntitySetHandler alloc] initWithEntity:entity];
        self.handlers[set] = handler;
      }
      handler.service = self;
    }
    self.prepared = YES;
  }
}

- (void)setHandler:(ODataEntitySetHandler *)handler forEntitySet:(NSString *)entitySet
{
  @synchronized (self) {
    self.handlers[entitySet] = handler;
    handler.service = self;
  }
}

- (ODataEntitySetHandler *)handlerForEntitySet:(NSString *)entitySet
{
  [self prepare];
  @synchronized (self) {
    return self.handlers[entitySet];
  }
}

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity
{
  return [self.mapper entitySetForEntity:OISRootEntity(entity)];
}

- (ODataEntitySetHandler *)handlerForEntity:(NSEntityDescription *)entity
{
  return entity ? [self handlerForEntitySet:[self entitySetForEntity:entity]] : nil;
}

- (NSArray *)entitySets
{
  [self prepare];
  @synchronized (self) {
    return [self.handlers.allKeys sortedArrayUsingSelector:@selector(compare:)];
  }
}

- (NSAttributeDescription *)versionAttributeOfEntity:(NSEntityDescription *)entity
{
  for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
    id flag = attribute.userInfo[ODataUserInfoETag];
    if ([flag isEqual:@"YES"] || [flag isEqual:@YES]) return attribute;
  }
  return nil;
}

- (NSString *)metadataXMLForVersion:(NSString *)version
{
  [self prepare];
  @synchronized (self) {
    // What the handlers allow, as they are now: a handler may be replaced,
    // or change its mind, after the first request.
    NSMutableDictionary *restrictions = [NSMutableDictionary dictionary];
    NSMutableString *signature = [NSMutableString stringWithString:version];
    for (NSString *set in [self.handlers.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      ODataEntitySetHandler *handler = self.handlers[set];
      NSMutableSet *refused = [NSMutableSet set];
      if (!handler.allowsInsert) [refused addObject:@"Insert"];
      if (!handler.allowsUpdate) [refused addObject:@"Update"];
      if (!handler.allowsDelete) [refused addObject:@"Delete"];
      if (refused.count) {
        restrictions[set] = refused;
        [signature appendFormat:@";%@:%@", set, [[refused.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
      }
    }
    NSString *xml = self.metadataByVersion[signature];
    if (!xml) {
      self.writer.restrictions = restrictions;
      xml = [self.writer XMLStringForVersion:version];
      self.metadataByVersion[signature] = xml;
    }
    return xml;
  }
}

- (NSArray *)operationProblems
{
  [self prepare];
  return self.catalog.problems;
}

- (NSArray *)metadataProblems
{
  [self prepare];
  return self.writer.problems;
}

- (void)startExchange:(ODataExchange *)exchange
{
  [self startExchange:exchange inContext:nil saves:YES authenticated:NO principal:nil];
}

- (void)startExchange:(ODataExchange *)exchange inContext:(NSManagedObjectContext *)shared saves:(BOOL)saves
        authenticated:(BOOL)authenticated principal:(ODataPrincipal *)principal
{
  [self prepare];
  OISServiceCall *call = [[OISServiceCall alloc] init];
  call.service = self;
  call.exchange = exchange;
  call.request = [[ODataRequest alloc] initWithURLRequest:exchange.request];
  call.request.service = self;
  call.headOnly = [call.request.method isEqualToString:@"HEAD"];
  ODataValueCoder *coder = [[ODataValueCoder alloc] init];
  coder.schema = self.mapper.schema;
  coder.declaredTypeForAttribute = self.mapper.values.declaredTypeForAttribute;
  call.coder = coder;

  call.saves = saves;
  call.authenticated = authenticated;
  call.request.principal = principal;
  NSManagedObjectContext *context = shared;
  if (!context) {
    context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = self.coordinator;
  }
  call.request.context = context;
  [context performBlockAndWait:^{
    @try {
      [call run];
    } @catch (NSException *exception) {
      NSLog(@"ODataService: %@ %@ raised %@: %@", call.request.method, exchange.request.URL, exception.name, exception.reason);
      [context rollback];
      [call respondError:ODataServiceError(500, @"The request failed inside the service")];
    }
  }];
}

@end
