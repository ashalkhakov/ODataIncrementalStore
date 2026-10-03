// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODSInternal.h"

// An entity tag no remote gives.
static NSString * const ODSUnknownVersion = @"\"ODataSync.unknown\"";

@implementation ODSRequests {
  __weak ODataSyncEngine *_engine;
  ODSModel *_model;
  ODSCodec *_codec;
}

- (instancetype)initWithEngine:(ODataSyncEngine *)engine remote:(ODataSyncRemote *)remote
{
  self = [super init];
  if (!self) return nil;
  _engine = engine;
  _remote = remote;
  _model = engine.model;
  _codec = engine.codec;
  return self;
}

#pragma mark URLs

- (NSURL *)URLOf:(NSString *)relative
{
  NSString *root = _remote.serviceRoot.absoluteString;
  if (![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSMutableCharacterSet *allowed = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
  [allowed removeCharactersInString:@"+"];
  NSString *encoded = [relative stringByAddingPercentEncodingWithAllowedCharacters:allowed];
  return [self versioned:[NSURL URLWithString:[root stringByAppendingString:encoded]]];
}

- (NSURL *)URLOfLink:(NSString *)link relativeTo:(NSURL *)base
{
  return [self versioned:base ? [NSURL URLWithString:link relativeToURL:base].absoluteURL : [NSURL URLWithString:link]];
}

// The version of the schema this side speaks, on every request (OData
// 4.01's $schemaversion; a $batch's requests have the batch's): a service
// on a newer one can read what it sends.
- (NSURL *)versioned:(NSURL *)url
{
  NSString *version = _engine.modelVersion;
  NSString *query = url.query;
  if (!version.length || !url || [query ?: @"" rangeOfString:@"schemaversion="].location != NSNotFound) return url;
  NSString *value = [version stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet alphanumericCharacterSet]];
  return [NSURL URLWithString:[url.absoluteString stringByAppendingFormat:@"%@$schemaversion=%@", query ? @"&" : @"?", value]] ?: url;
}

- (NSDictionary<NSString *, NSString *> *)headers
{
  ODataSyncEngine *engine = _engine;
  NSMutableDictionary *headers = [NSMutableDictionary dictionary];
  if (_remote.peer) headers[ODataSyncReplicaHeader] = engine.replicaID;
  return headers;
}

#pragma mark Reads

// $expand of the to-ones' keys, for reading an entity's rows: nil for none.
- (NSString *)expandOfEntity:(NSEntityDescription *)entity
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSRelationshipDescription *toOne in [_model toOnesOf:entity]) {
    [items addObject:[NSString stringWithFormat:@"%@($select=%@)", [_model.mapper propertyForRelationship:toOne],
                                                [self selectOfKeyOfEntity:toOne.destinationEntity]]];
  }
  return items.count ? [items componentsJoinedByString:@","] : nil;
}

// $select of the key, for reading only keys.
- (NSString *)selectOfKeyOfEntity:(NSEntityDescription *)entity
{
  NSMutableArray *names = [NSMutableArray array];
  for (NSAttributeDescription *attribute in [_model keyAttributesOf:entity]) [names addObject:[_model.mapper propertyForAttribute:attribute]];
  return [names componentsJoinedByString:@","];
}

// $filter text naming these keys (k eq 1 or k eq 2; (a eq 1 and b eq 2) or ...).
- (NSString *)filterOfKeys:(NSArray<NSDictionary *> *)keys entity:(NSEntityDescription *)entity
{
  NSArray<NSAttributeDescription *> *attributes = [_model keyAttributesOf:entity];
  NSMutableArray *alternatives = [NSMutableArray array];
  for (NSDictionary *key in keys) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSAttributeDescription *attribute in attributes) {
      [parts addObject:[NSString stringWithFormat:@"%@ eq %@", [_model.mapper propertyForAttribute:attribute],
                                                  [_model.mapper.values literalForValue:key[attribute.name] attribute:attribute]]];
    }
    NSString *all = [parts componentsJoinedByString:@" and "];
    [alternatives addObject:parts.count > 1 ? [NSString stringWithFormat:@"(%@)", all] : all];
  }
  return [alternatives componentsJoinedByString:@" or "];
}

// Set?$filter=...&$select=...&$expand=to-one keys.
- (NSURL *)URLOfSet:(NSEntityDescription *)entity filter:(NSString *)filter select:(NSString *)select expand:(BOOL)expand
{
  NSMutableArray *options = [NSMutableArray array];
  if (filter.length) [options addObject:[@"$filter=" stringByAppendingString:filter]];
  if (select.length) [options addObject:[@"$select=" stringByAppendingString:select]];
  NSString *expansion = expand ? [self expandOfEntity:entity] : nil;
  if (expansion) [options addObject:[@"$expand=" stringByAppendingString:expansion]];
  NSString *path = [_model.mapper entitySetForEntity:entity];
  if (options.count) path = [path stringByAppendingFormat:@"?%@", [options componentsJoinedByString:@"&"]];
  return [self URLOf:path];
}

- (NSURL *)URLOfSet:(NSEntityDescription *)entity keysOnly:(BOOL)keysOnly
{
  return [self URLOfSet:entity filter:_remote.filters[entity.name] select:keysOnly ? [self selectOfKeyOfEntity:entity] : nil expand:!keysOnly];
}

- (NSURL *)URLOfSet:(NSEntityDescription *)entity keys:(NSArray<NSDictionary *> *)keys
{
  NSString *filter = _remote.filters[entity.name];
  NSString *named = [self filterOfKeys:keys entity:entity];
  NSString *both = filter.length ? [NSString stringWithFormat:@"(%@) and (%@)", filter, named] : named;
  return [self URLOfSet:entity filter:both select:nil expand:YES];
}

- (NSURL *)URLOfObject:(NSEntityDescription *)entity key:(NSDictionary *)key
{
  NSString *path = [_codec pathOfEntity:entity key:key];
  NSString *expansion = [self expandOfEntity:[_model rootOf:entity]];
  if (expansion) path = [path stringByAppendingFormat:@"?$expand=%@", expansion];
  return [self URLOf:path];
}

- (NSMutableURLRequest *)GET:(NSURL *)url prefer:(NSString *)prefer
{
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  if (prefer) [request setValue:prefer forHTTPHeaderField:@"Prefer"];
  NSDictionary *headers = [self headers];
  for (NSString *name in headers) [request setValue:headers[name] forHTTPHeaderField:name];
  return request;
}

#pragma mark Changes

- (NSDictionary *)upsertOf:(NSManagedObject *)object entity:(NSEntityDescription *)root key:(NSDictionary *)key
                properties:(NSSet<NSString *> *)properties insert:(BOOL)insert checked:(BOOL)checked etag:(NSString *)etag
{
  NSMutableDictionary *headers = [[self headers] mutableCopy];
  headers[@"Content-Type"] = @"application/json";
  headers[@"Prefer"] = @"return=minimal";
  // A change of a version never agreed on with this remote (one that came
  // from elsewhere): matching nothing, it meets the remote's version (a
  // 412, and the resolver), and so never overwrites it unseen.
  if (checked && insert && !etag) headers[@"If-None-Match"] = @"*";
  else if (checked) headers[@"If-Match"] = etag ?: ODSUnknownVersion;
  return @{ @"method": @"PATCH", @"url": [_codec pathOfEntity:root key:key], @"headers": headers,
            @"body": [_codec JSONOfObject:object properties:insert ? nil : properties] };
}

- (NSDictionary *)deletionOf:(NSEntityDescription *)root key:(NSDictionary *)key checked:(BOOL)checked etag:(NSString *)etag
                    versions:(NSDictionary<NSString *, NSNumber *> *)versions
{
  NSMutableDictionary *headers = [[self headers] mutableCopy];
  if (checked) headers[@"If-Match"] = etag ?: @"*";
  // The deletion's history, for the remote's tombstone.
  if (versions.count) headers[ODataSyncVersionsHeader] = ODSTextOfVersions(versions);
  return @{ @"method": @"DELETE", @"url": [_codec pathOfEntity:root key:key], @"headers": headers };
}

- (NSMutableURLRequest *)HTTPRequestOf:(NSDictionary *)request
{
  NSMutableURLRequest *http = [NSMutableURLRequest requestWithURL:[self URLOf:request[@"url"]]];
  http.HTTPMethod = request[@"method"];
  [http setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSDictionary *given = request[@"headers"];
  for (NSString *name in given) [http setValue:given[name] forHTTPHeaderField:name];
  if (request[@"body"]) http.HTTPBody = [NSJSONSerialization dataWithJSONObject:request[@"body"] options:0 error:NULL];
  return http;
}

- (NSMutableURLRequest *)batchOf:(NSArray<NSDictionary *> *)requests
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSUInteger i = 0; i < requests.count; i++) {
    NSMutableDictionary *item = [requests[i] mutableCopy];
    item[@"id"] = [NSString stringWithFormat:@"%lu", (unsigned long)i + 1];
    [items addObject:item];
  }
  NSMutableURLRequest *http = [NSMutableURLRequest requestWithURL:[self URLOf:@"$batch"]];
  http.HTTPMethod = @"POST";
  [http setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [http setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  [http setValue:@"odata.continue-on-error" forHTTPHeaderField:@"Prefer"];
  NSDictionary *headers = [self headers];
  for (NSString *name in headers) [http setValue:headers[name] forHTTPHeaderField:name];
  http.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"requests": items } options:0 error:NULL];
  return http;
}

@end
