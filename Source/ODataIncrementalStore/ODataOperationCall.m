// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataOperationCall.h"
#import "ODataIncrementalStore+Private.h"
#include <string.h>

// A parameter or an alias value in a URL: percent-encoded, but for what
// RFC 3986 lets stand and OData literals use.
static NSString *OISEncode(NSString *value, const char *allowed)
{
  static const char hex[] = "0123456789ABCDEF";
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *bytes = data.bytes;
  NSMutableString *out = [NSMutableString stringWithCapacity:data.length];
  for (NSUInteger i = 0; i < data.length; i++) {
    unsigned char c = bytes[i];
    BOOL keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                (c != 0 && strchr("-._~", c) != NULL) || (c != 0 && strchr(allowed, c) != NULL);
    if (keep) [out appendFormat:@"%c", c];
    else [out appendFormat:@"%%%c%c", hex[c >> 4], hex[c & 15]];
  }
  return out;
}

// One JSON value as text, a string or a number included.
static NSString *OISJSONText(id value, NSError **error)
{
  NSData *data = [NSJSONSerialization dataWithJSONObject:@[ value ] options:0 error:error];
  if (!data) return nil;
  NSString *array = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return [array substringWithRange:NSMakeRange(1, array.length - 2)];
}

static NSString *OISElementType(NSString *type, BOOL *collection)
{
  BOOL isCollection = [type hasPrefix:@"Collection("] && [type hasSuffix:@")"];
  if (collection) *collection = isCollection;
  return isCollection ? [type substringWithRange:NSMakeRange(11, type.length - 12)] : type;
}

@implementation ODataOperationCall {
  ODataIncrementalStore *_store;
  NSManagedObjectID *_objectID;
  NSURLRequest *_request;
  NSEntityDescription *_resultEntity;  // for entities returned
  BOOL _returnsCollection;
  NSArray *_resultIDs;                 // the entities returned, before they are objects
}

- (instancetype)initWithName:(NSString *)name object:(NSManagedObject *)object entityName:(NSString *)entityName context:(NSManagedObjectContext *)context
{
  self = [super init];
  if (!self) return nil;
  _name = [name copy];
  _object = object;
  _entityName = [entityName copy];
  _context = context;
  return self;
}

+ (instancetype)callOfOperation:(NSString *)name onObject:(NSManagedObject *)object
{
  return [[self alloc] initWithName:name object:object entityName:nil context:object.managedObjectContext];
}

+ (instancetype)callOfOperation:(NSString *)name onEntity:(NSString *)entityName inContext:(NSManagedObjectContext *)context
{
  return [[self alloc] initWithName:name object:nil entityName:entityName context:context];
}

+ (instancetype)callOfOperation:(NSString *)name inContext:(NSManagedObjectContext *)context
{
  return [[self alloc] initWithName:name object:nil entityName:nil context:context];
}

#pragma mark - Invoking

- (id)invoke:(NSError **)error
{
  if ([self prepare] && [self perform]) [self finish];
  // The ivars, not the getters: libobjc2's objc_retainAutoreleasedReturnValue
  // takes the object on top of the autorelease pool for the one a getter
  // returns, and a synthesized getter returns its ivar unretained, so
  // reading self.error again after *error = self.error took back the
  // autorelease that keeps the caller's error alive.
  if (error) *error = _error;
  return _error ? nil : _result;
}

- (void)invokeWithTarget:(id)target action:(SEL)action
{
  // What needs the context is done here and at the end, on its queue; the
  // requests in between wait on another thread.
  BOOL prepared = [self prepare];
  NSManagedObjectContext *context = self.context;
  void (^deliver)(void) = ^{
    if (!self.error) [self finish];
    void (*send)(id, SEL, id) = (void (*)(id, SEL, id))[target methodForSelector:action];
    if (send) send(target, action, self);
  };
  void (^onContext)(void) = ^{
    if (context.concurrencyType == NSPrivateQueueConcurrencyType || context.concurrencyType == NSMainQueueConcurrencyType) {
      [context performBlock:deliver];
    } else {
      [self performSelectorOnMainThread:@selector(run:) withObject:[deliver copy] waitUntilDone:NO];
    }
  };
  if (!prepared) {
    onContext();
    return;
  }
  [NSThread detachNewThreadSelector:@selector(performThen:) toTarget:self withObject:[onContext copy]];
}

- (void)run:(void (^)(void))block
{
  block();
}

- (void)performThen:(void (^)(void))then
{
  @autoreleasepool {
    [self perform];
    then();
  }
}

- (void)fail:(NSError *)error
{
  _error = error;
}

- (void)failWith:(ODataIncrementalStoreErrorCode)code message:(NSString *)message
{
  _error = OISError(code, message);
}

#pragma mark - Before: the operation and its request

- (ODataIncrementalStore *)storeInCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
  for (NSPersistentStore *store in coordinator.persistentStores) {
    if ([store isKindOfClass:[ODataIncrementalStore class]]) return (ODataIncrementalStore *)store;
  }
  return nil;
}

- (BOOL)prepare
{
  NSManagedObjectContext *context = self.context;
  NSEntityDescription *boundEntity = nil;
  if (self.object) {
    _objectID = self.object.objectID;
    if (_objectID.isTemporaryID) {
      [self failWith:ODataIncrementalStoreErrorUnsupportedRequest
             message:[NSString stringWithFormat:@"%@ is called on a saved object; this %@ is not saved", self.name, self.object.entity.name]];
      return NO;
    }
    NSPersistentStore *store = _objectID.persistentStore;
    _store = [store isKindOfClass:[ODataIncrementalStore class]] ? (ODataIncrementalStore *)store : nil;
    boundEntity = self.object.entity;
  } else {
    _store = [self storeInCoordinator:context.persistentStoreCoordinator];
    if (self.entityName) {
      boundEntity = context.persistentStoreCoordinator.managedObjectModel.entitiesByName[self.entityName];
      if (!boundEntity) {
        [self failWith:ODataIncrementalStoreErrorMissingEntitySet message:[NSString stringWithFormat:@"No entity %@ in the model", self.entityName]];
        return NO;
      }
    }
  }
  if (!_store) {
    [self failWith:ODataIncrementalStoreErrorUnsupportedRequest message:@"No OData store to call the operation on"];
    return NO;
  }
  ODataSchema *schema = _store.schema;
  ODataPropertyMapper *mapper = _store.mapper;
  if (!schema) {
    [self failWith:ODataIncrementalStoreErrorUnsupportedRequest message:@"Operations are found in $metadata, which the store could not read"];
    return NO;
  }

  ODataSchemaEntityType *boundType = boundEntity ? [mapper entityTypeForEntity:boundEntity] : nil;
  if (boundEntity && !boundType) {
    [self failWith:ODataIncrementalStoreErrorUnsupportedRequest message:[NSString stringWithFormat:@"No entity type for %@ in $metadata", boundEntity.name]];
    return NO;
  }
  NSSet *names = self.parameters ? [NSSet setWithArray:self.parameters.allKeys] : nil;
  ODataSchemaOperation *operation = [schema operationNamed:self.name boundToEntityType:boundType collection:boundEntity && !self.object
                                            parameterNames:names];
  if (!operation) {
    NSString *where = self.object ? [NSString stringWithFormat:@"bound to %@", boundType.qualifiedName]
                    : boundEntity ? [NSString stringWithFormat:@"bound to a collection of %@", boundType.qualifiedName]
                                  : @"imported by the service";
    [self failWith:ODataIncrementalStoreErrorUnsupportedRequest message:[NSString stringWithFormat:@"No operation %@ %@", self.name, where]];
    return NO;
  }
  _operation = operation;

  // The return type: an entity (or a collection of them) needs an entity
  // in the model to become objects of.
  if (operation.returnType) {
    BOOL collection = NO;
    NSString *element = OISElementType(operation.returnType, &collection);
    _returnsCollection = collection;
    if ([schema entityTypeNamed:element]) {
      for (NSEntityDescription *entity in context.persistentStoreCoordinator.managedObjectModel.entities) {
        if (![[mapper qualifiedTypeForEntity:entity] isEqualToString:element]) continue;
        _resultEntity = entity;
        break;
      }
      if (!_resultEntity) {
        [self failWith:ODataIncrementalStoreErrorUnsupportedRequest
               message:[NSString stringWithFormat:@"%@ returns %@, which no entity in the model stands for", operation.name, element]];
        return NO;
      }
    }
  }

  // Where it is called: after the object or the collection it is bound
  // to, or at the service root by its import's name.
  NSURL *root = _store.client.configuration.serviceRoot;
  NSString *base;
  if (self.object) {
    NSError *error = nil;
    NSURL *url = [_store editURLForObjectID:_objectID error:&error];
    if (!url) {
      [self fail:error];
      return NO;
    }
    base = [NSString stringWithFormat:@"%@/%@", url.absoluteString, operation.qualifiedName];
  } else if (boundEntity) {
    base = [NSString stringWithFormat:@"%@%@/%@", root.absoluteString, [mapper collectionPathForEntity:boundEntity], operation.qualifiedName];
  } else {
    NSString *imported = nil;
    for (ODataSchemaOperationImport *import in schema.operationImports.allValues) {
      if ([import.operation isEqualToString:operation.qualifiedName] && ([import.name isEqualToString:self.name] || !imported)) imported = import.name;
    }
    if (!imported) {
      [self failWith:ODataIncrementalStoreErrorUnsupportedRequest message:[NSString stringWithFormat:@"%@ is not imported by the service's container", operation.qualifiedName]];
      return NO;
    }
    base = [root.absoluteString stringByAppendingString:OISEncode(imported, "")];
  }

  NSDictionary *given = [self parametersByDeclaredName];
  if (!given) return NO;
  NSError *error = nil;
  NSMutableURLRequest *request = nil;
  if (operation.isAction) {
    // The parameters in the order they are declared: JSON objects have
    // none, but TripPin answers 500 to ShareTrip's in another.
    NSMutableArray *members = [NSMutableArray array];
    for (ODataSchemaParameter *parameter in operation.callerParameters) {
      if (!given[parameter.name]) continue;
      id json = [self JSONForValue:given[parameter.name] parameter:parameter];
      NSString *name = json ? OISJSONText(parameter.name, &error) : nil;
      NSString *value = name ? OISJSONText(json, &error) : nil;
      if (!value) {
        if (error) [self fail:error];
        return NO;
      }
      [members addObject:[NSString stringWithFormat:@"%@:%@", name, value]];
    }
    // An empty placeholder, so the request gets its JSON Content-Type.
    request = [_store.client requestWithMethod:@"POST" URL:[NSURL URLWithString:base] body:members.count ? @{} : nil etag:nil error:&error];
    if (members.count) {
      request.HTTPBody = [[NSString stringWithFormat:@"{%@}", [members componentsJoinedByString:@","]] dataUsingEncoding:NSUTF8StringEncoding];
    }
  } else {
    // name(p=literal,...), complex values, collections and objects by
    // alias: name(p=@p)?@p=<JSON> (Part 2 section 5.1.1.13.1).
    NSMutableArray *arguments = [NSMutableArray array];
    NSMutableArray *aliases = [NSMutableArray array];
    for (ODataSchemaParameter *parameter in operation.callerParameters) {
      id value = given[parameter.name];
      if (!value) continue;
      ODataEdmType edm = [mapper.values edmTypeNamed:parameter.type];
      BOOL inline_ = edm != ODataEdmComplex && edm != ODataEdmCollection && edm != ODataEdmUnknown &&
                     ![value isKindOfClass:[NSManagedObject class]] && ![value isKindOfClass:[NSManagedObjectID class]];
      if (inline_ || value == [NSNull null]) {
        NSString *literal = [mapper.values literalForValue:value typeName:parameter.type];
        [arguments addObject:[NSString stringWithFormat:@"%@=%@", parameter.name, OISEncode(literal, "'(),:@!$*;+=")]];
        continue;
      }
      id json = [self JSONForValue:value parameter:parameter];
      if (!json) return NO;
      NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
      if (!data) {
        [self fail:error];
        return NO;
      }
      NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
      [arguments addObject:[NSString stringWithFormat:@"%@=@%@", parameter.name, parameter.name]];
      [aliases addObject:[NSString stringWithFormat:@"@%@=%@", parameter.name, OISEncode(text, "")]];
    }
    NSMutableString *url = [NSMutableString stringWithFormat:@"%@(%@)", base, [arguments componentsJoinedByString:@","]];
    if (aliases.count) [url appendFormat:@"?%@", [aliases componentsJoinedByString:@"&"]];
    request = [_store.client requestWithMethod:@"GET" URL:[NSURL URLWithString:url] body:nil etag:nil error:&error];
  }
  if (!request) {
    [self fail:error ?: OISError(ODataIncrementalStoreErrorUnsupportedRequest, [NSString stringWithFormat:@"Cannot call %@ at %@", operation.name, base])];
    return NO;
  }
  _request = request;
  return YES;
}

// The parameters given, under the names the operation declares them by.
- (NSDictionary *)parametersByDeclaredName
{
  NSMutableDictionary *out = [NSMutableDictionary dictionary];
  for (NSString *name in self.parameters) {
    ODataSchemaParameter *found = nil;
    for (ODataSchemaParameter *parameter in self.operation.callerParameters) {
      if ([parameter.name isEqualToString:name]) found = parameter;
    }
    for (ODataSchemaParameter *parameter in self.operation.callerParameters) {
      if (!found && [parameter.name caseInsensitiveCompare:name] == NSOrderedSame) found = parameter;
    }
    if (!found) {
      [self failWith:ODataIncrementalStoreErrorUnsupportedRequest
             message:[NSString stringWithFormat:@"%@ has no parameter %@", self.operation.name, name]];
      return nil;
    }
    out[found.name] = self.parameters[name];
  }
  return out;
}

// A parameter's JSON: an object as a reference to it, anything else as
// its declared type says.
- (id)JSONForValue:(id)value parameter:(ODataSchemaParameter *)parameter
{
  if ([value isKindOfClass:[NSArray class]] && [[value firstObject] isKindOfClass:[NSManagedObject class]]) {
    NSMutableArray *references = [NSMutableArray array];
    for (id item in value) {
      id reference = [self referenceTo:item];
      if (!reference) return nil;
      [references addObject:reference];
    }
    return references;
  }
  if ([value isKindOfClass:[NSManagedObject class]] || [value isKindOfClass:[NSManagedObjectID class]]) return [self referenceTo:value];
  return [_store.mapper.values JSONForValue:value typeName:parameter.type];
}

- (NSDictionary *)referenceTo:(id)object
{
  NSManagedObjectID *oid = [object isKindOfClass:[NSManagedObject class]] ? [object objectID] : object;
  if (oid.isTemporaryID || ![oid.persistentStore isKindOfClass:[ODataIncrementalStore class]]) {
    [self failWith:ODataIncrementalStoreErrorUnsupportedRequest message:[NSString stringWithFormat:@"%@: an object passed must be saved in the service", self.name]];
    return nil;
  }
  NSError *error = nil;
  NSURL *url = [(ODataIncrementalStore *)oid.persistentStore canonicalURLForObjectID:oid error:&error];
  if (!url) {
    [self fail:error];
    return nil;
  }
  return @{ @"@odata.id": url.absoluteString };
}

#pragma mark - Between: the request, on any thread

- (BOOL)perform
{
  NSError *error = nil;
  ODataHTTPResponse *response = [_store.client sendRequest:_request error:&error];
  if (!response) {
    [self fail:error];
    return NO;
  }
  // An action bound to the object may have changed it.
  if (self.operation.isAction && _objectID) [_store discardCachedRowsForObjectIDs:@[ _objectID ]];

  id json = response.status == 204 || !response.data.length ? [NSNull null] : [response JSONWithError:&error];
  if (!json) {
    [self fail:error];
    return NO;
  }
  if (!self.operation.returnType || json == [NSNull null]) {
    _result = [NSNull null];
    return YES;
  }
  if (![json isKindOfClass:[NSDictionary class]]) {
    [self failWith:ODataIncrementalStoreErrorDecoding message:[NSString stringWithFormat:@"%@ answered with no JSON object", self.operation.name]];
    return NO;
  }

  if (_resultEntity) {
    NSMutableArray *rows = [NSMutableArray array];
    if (_returnsCollection) {
      for (id row in [json[@"value"] isKindOfClass:[NSArray class]] ? json[@"value"] : @[]) {
        if ([row isKindOfClass:[NSDictionary class]]) [rows addObject:row];
      }
      NSString *next = json[@"@odata.nextLink"];
      if ([next isKindOfClass:[NSString class]]) {
        NSURL *nextURL = [NSURL URLWithString:next relativeToURL:_request.URL].absoluteURL;
        NSArray *more = nextURL ? [_store rowsAtURL:nextURL limit:0 pageSize:0 error:&error] : nil;
        if (!more) {
          [self fail:error ?: OISError(ODataIncrementalStoreErrorDecoding, @"Bad next link")];
          return NO;
        }
        [rows addObjectsFromArray:more];
      }
    } else {
      [rows addObject:json];
    }
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *row in rows) {
      NSManagedObjectID *oid = [_store objectIDFromPayload:row entity:_resultEntity error:&error];
      if (!oid) {
        [self fail:error];
        return NO;
      }
      [_store cacheNodeForObjectID:oid entity:oid.entity payload:row error:NULL];
      [ids addObject:oid];
    }
    _resultIDs = ids;
    return YES;
  }

  // A complex value is the object itself; anything else is its "value".
  ODataValueCoder *values = _store.mapper.values;
  ODataEdmType edm = [values edmTypeNamed:self.operation.returnType];
  id value = edm == ODataEdmComplex ? json : json[@"value"];
  _result = value ? [values valueForJSON:value typeName:self.operation.returnType] : [NSNull null];
  if (!_result) {
    [self failWith:ODataIncrementalStoreErrorDecoding
           message:[NSString stringWithFormat:@"%@ returned what is not a %@", self.operation.name, self.operation.returnType]];
    return NO;
  }
  return YES;
}

#pragma mark - After: objects, in the context

- (void)finish
{
  if (!_resultIDs) return;
  NSMutableArray *objects = [NSMutableArray array];
  for (NSManagedObjectID *oid in _resultIDs) [objects addObject:[self.context objectWithID:oid]];
  _result = _returnsCollection ? objects : (objects.firstObject ?: [NSNull null]);
  _resultIDs = nil;
}

@end

@implementation NSManagedObject (ODataOperations)

- (id)invokeODataOperation:(NSString *)name parameters:(NSDictionary *)parameters error:(NSError **)error
{
  ODataOperationCall *call = [ODataOperationCall callOfOperation:name onObject:self];
  call.parameters = parameters;
  return [call invoke:error];
}

@end
