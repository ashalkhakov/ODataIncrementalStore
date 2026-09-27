// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataQueryBuilder.h"
#import "ODataFunctionExpression.h"
#import "ODataPredicateTranslator.h"
#import "ODataError.h"
#import <ODataKit/ODataExpression.h>

static NSString *OISPercentEncode(NSString *value)
{
  if (!value.length) return @"";
  /* Portable RFC 3986 unreserved encoder. Avoids URLQueryAllowedCharacterSet,
     which is missing on some gnustep-base versions. */
  static const char hex[] = "0123456789ABCDEF";
  NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
  const unsigned char *bytes = data.bytes;
  NSMutableString *out = [NSMutableString stringWithCapacity:data.length * 3];
  for (NSUInteger i = 0; i < data.length; i++) {
    unsigned char c = bytes[i];
    BOOL unreserved = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                      (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~';
    if (unreserved) {
      [out appendFormat:@"%c", c];
    } else {
      [out appendFormat:@"%%%c%c", hex[c >> 4], hex[c & 15]];
    }
  }
  return out;
}

@implementation ODataQueryBuilder

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper serviceRoot:(NSURL *)serviceRoot
{
  self = [super init];
  if (!self) return nil;
  _mapper = mapper;
  _serviceRoot = [serviceRoot copy];
  return self;
}

- (NSURL *)composePath:(NSString *)path query:(NSArray<NSArray *> *)items error:(NSError **)error
{
  NSString *root = self.serviceRoot.absoluteString ?: @"";
  if (root.length && ![root hasSuffix:@"/"]) root = [root stringByAppendingString:@"/"];
  NSMutableString *s = [NSMutableString stringWithFormat:@"%@%@", root, path];
  if (items.count) {
    [s appendString:@"?"];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSArray *pair in items) {
      NSString *name = pair[0];
      NSString *value = pair.count > 1 ? pair[1] : @"";
      [parts addObject:[NSString stringWithFormat:@"%@=%@", name, OISPercentEncode(value)]];
    }
    [s appendString:[parts componentsJoinedByString:@"&"]];
  }
  NSURL *url = [NSURL URLWithString:s];
  if (!url) {
    if (error) *error = OISError(ODataIncrementalStoreErrorTransport, [NSString stringWithFormat:@"Could not build URL for %@", path]);
    return nil;
  }
  return url;
}

// Whether the service expands this navigation property of the entity's
// set (Capabilities.ExpandRestrictions): an expansion only saves requests,
// so one it refuses is left out.
- (BOOL)expands:(NSString *)wire entity:(NSEntityDescription *)entity
{
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return YES;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id restrictions = [schema capability:@"Capabilities.ExpandRestrictions" forEntitySet:[self.mapper entitySetForEntity:root]];
  if (![restrictions isKindOfClass:[NSDictionary class]]) return YES;
  if ([restrictions[@"Expandable"] isEqual:@NO]) return NO;
  for (id path in [restrictions[@"NonExpandableProperties"] isKindOfClass:[NSArray class]] ? restrictions[@"NonExpandableProperties"] : @[]) {
    id name = [path isKindOfClass:[NSDictionary class]] ? path[@"$NavigationPropertyPath"] : path;
    if ([name isEqual:wire]) return NO;
  }
  return YES;
}

// Nav($select=Key) for each to-one relationship not already expanded.
// Core Data asks for every to-one relationship as soon as a fault fires,
// and a row does not name its related entities; without this, firing N
// faults costs N more requests. A service that ignores the nested $select
// sends the whole related entity, which is cached too.
- (NSArray *)toOneKeyExpansionsForEntity:(NSEntityDescription *)entity except:(NSSet *)expanded
{
  NSMutableArray *out = [NSMutableArray array];
  NSArray *names = [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSRelationshipDescription *rel = entity.relationshipsByName[name];
    if (rel.isToMany || !rel.destinationEntity) continue;
    NSString *wire = [self.mapper propertyForRelationship:rel];
    if ([expanded containsObject:wire] || ![self expands:wire entity:entity]) continue;
    NSMutableArray *keys = [NSMutableArray array];
    for (NSAttributeDescription *key in [self.mapper keyAttributesForEntity:rel.destinationEntity]) {
      [keys addObject:[self.mapper propertyForAttribute:key]];
    }
    if (!keys.count) continue;
    [out addObject:[NSString stringWithFormat:@"%@($select=%@)", wire, [keys componentsJoinedByString:@","]]];
  }
  return out;
}

// $select for rows read as objects: the attributes the model has that the
// service's type has too, and each subentity's own behind its type cast
// (Zoo.Lion/MaxRoar), so a service sends nothing the store would drop.
// nil, for every property, without $metadata, when a subentity names no
// type, or when the set's Capabilities.SelectSupport says it has none.
- (NSString *)selectForEntity:(NSEntityDescription *)entity
{
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return nil;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id support = [schema capability:@"Capabilities.SelectSupport" forEntitySet:[self.mapper entitySetForEntity:root]];
  if ([support isKindOfClass:[NSDictionary class]] && [support[@"Supported"] isEqual:@NO]) return nil;
  NSMutableArray *names = [NSMutableArray array];
  if (![self select:entity cast:nil into:names]) return nil;
  return names.count ? [names componentsJoinedByString:@","] : nil;
}

- (BOOL)select:(NSEntityDescription *)entity cast:(NSString *)cast into:(NSMutableArray *)names
{
  ODataSchemaEntityType *type = [self.mapper entityTypeForEntity:entity];
  if (!type) return NO;
  NSMutableArray *own = [NSMutableArray array];
  for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
    if (attribute.isTransient) continue;
    if (cast && entity.superentity.attributesByName[attribute.name]) continue;  // the base type's, selected already
    NSString *wire = [self.mapper propertyForAttribute:attribute];
    if (![self.mapper.schema property:wire ofEntityType:type]) continue;
    [own addObject:cast ? [NSString stringWithFormat:@"%@/%@", cast, wire] : wire];
  }
  [names addObjectsFromArray:[own sortedArrayUsingSelector:@selector(compare:)]];
  NSArray *subentities = [entity.subentities sortedArrayUsingDescriptors:@[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ]];
  for (NSEntityDescription *subentity in subentities) {
    NSString *qualified = [self.mapper qualifiedTypeForEntity:subentity];
    if (!qualified || ![self select:subentity cast:qualified into:names]) return NO;
  }
  return YES;
}

- (NSArray *)readingQueryForEntity:(NSEntityDescription *)entity
{
  NSMutableArray *items = [NSMutableArray array];
  NSString *select = [self selectForEntity:entity];
  if (select) [items addObject:@[ @"$select", select ]];
  NSArray *expansions = [self toOneKeyExpansionsForEntity:entity except:[NSSet set]];
  if (expansions.count) [items addObject:@[ @"$expand", [expansions componentsJoinedByString:@","] ]];
  return items;
}

static void OISCollectCalls(ODataExpression *e, NSMutableSet *into)
{
  if (!e) return;
  if (e.kind == ODataExpressionCall && [e.name rangeOfString:@"."].location == NSNotFound) [into addObject:e.name];
  OISCollectCalls(e.operand, into);
  OISCollectCalls(e.left, into);
  OISCollectCalls(e.right, into);
  OISCollectCalls(e.body, into);
  for (ODataExpression *a in e.arguments) OISCollectCalls(a, into);
  for (ODataExpression *a in e.namedArguments.allValues) OISCollectCalls(a, into);
}

// A canonical function the set's Capabilities.FilterFunctions leaves out
// (Part 1 section 13.3, item 20); nil when it lists none, which lets every
// function be tried.
- (NSString *)refusedFunctionIn:(NSString *)filter entity:(NSEntityDescription *)entity
{
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return nil;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id listed = [schema capability:@"Capabilities.FilterFunctions" forEntitySet:[self.mapper entitySetForEntity:root]];
  if (![listed isKindOfClass:[NSArray class]] || ![listed count]) return nil;
  NSMutableSet *used = [NSMutableSet set];
  OISCollectCalls([ODataExpression expressionWithString:filter error:NULL], used);
  for (NSString *name in [used.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
    if (![listed containsObject:name]) return name;
  }
  return nil;
}

- (NSURL *)URLForFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity error:(NSError **)error
{
  // The entity set, with a type cast for a derived type (Animals/Zoo.Lion).
  NSString *set = [self.mapper collectionPathForEntity:entity];
  NSMutableArray *items = [NSMutableArray array];

  if (fetch.predicate) {
    ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
    t.keysForObjectID = self.keysForObjectID;
    if (self.version) t.version = self.version;
    NSString *filter = [t translatePredicate:fetch.predicate error:error];
    if (!filter) return nil;
    NSString *refused = [self refusedFunctionIn:filter entity:entity];
    if (refused) {
      if (error) *error = OISError(ODataIncrementalStoreErrorNotAllowedByService,
                                   [NSString stringWithFormat:@"%@: the service does not filter with %@ (Capabilities.FilterFunctions)", entity.name, refused]);
      return nil;
    }
    [items addObject:@[ @"$filter", filter ]];
  }

  // /$count takes $filter alone (Part 2 section 4.8): TripPin answers
  // 400 to $orderby there.
  if (fetch.resultType == NSCountResultType) {
    return [self composePath:[set stringByAppendingString:@"/$count"] query:items error:error];
  }

  if (fetch.sortDescriptors.count) {
    NSMutableArray *bits = [NSMutableArray array];
    for (NSSortDescriptor *desc in fetch.sortDescriptors) {
      NSString *name;
      if ([desc isKindOfClass:[ODataSortDescriptor class]]) {
        // Any expression $filter could hold: a function's result, say.
        ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
        if (self.version) t.version = self.version;
        name = [t translateExpression:((ODataSortDescriptor *)desc).expression error:error];
        if (!name) return nil;
      } else {
        // category.name is Category/CategoryName: a dot would be a type cast.
        name = [self.mapper propertyPathForKeyPath:desc.key ?: @"" entity:entity];
      }
      [bits addObject:desc.ascending ? name : [name stringByAppendingString:@" desc"]];
    }
    // The key breaks ties. Paging resumes after the last row of a page by
    // its sort values, so with ties a service can skip rows: Northwind
    // returns 60 of 77 products sorted by category name alone.
    for (NSAttributeDescription *key in [self.mapper keyAttributesForEntity:entity]) {
      NSString *name = [self.mapper propertyForAttribute:key];
      if (![bits containsObject:name] && ![bits containsObject:[name stringByAppendingString:@" desc"]]) {
        [bits addObject:name];
      }
    }
    [items addObject:@[ @"$orderby", [bits componentsJoinedByString:@","] ]];
  }

  if (fetch.fetchLimit > 0) {
    [items addObject:@[ @"$top", [NSString stringWithFormat:@"%lu", (unsigned long)fetch.fetchLimit] ]];
  }
  if (fetch.fetchOffset > 0) {
    [items addObject:@[ @"$skip", [NSString stringWithFormat:@"%lu", (unsigned long)fetch.fetchOffset] ]];
  }

  if (fetch.resultType == NSDictionaryResultType && fetch.propertiesToFetch.count) {
    NSMutableArray *names = [NSMutableArray array];
    for (id prop in fetch.propertiesToFetch) {
      if ([prop isKindOfClass:[NSAttributeDescription class]]) {
        [names addObject:[self.mapper propertyForAttribute:prop]];
      } else if ([prop isKindOfClass:[NSString class]]) {
        NSAttributeDescription *attr = entity.attributesByName[prop];
        [names addObject:attr ? [self.mapper propertyForAttribute:attr] : [self.mapper wireName:prop]];
      }
    }
    if (names.count) [items addObject:@[ @"$select", [names componentsJoinedByString:@","] ]];
  } else if (fetch.resultType == NSManagedObjectResultType || fetch.resultType == NSManagedObjectIDResultType) {
    // Object IDs too: their rows are cached the same.
    NSString *select = [self selectForEntity:entity];
    if (select) [items addObject:@[ @"$select", select ]];
  }

  NSMutableArray *expansions = [[self expansionsForKeyPaths:fetch.relationshipKeyPathsForPrefetching entity:entity] mutableCopy];
  NSMutableSet *expanded = [NSMutableSet set];
  for (NSString *path in fetch.relationshipKeyPathsForPrefetching) {
    NSString *first = [path componentsSeparatedByString:@"."].firstObject;
    NSRelationshipDescription *rel = entity.relationshipsByName[first];
    [expanded addObject:rel ? [self.mapper propertyForRelationship:rel] : [self.mapper wireName:first]];
  }
  if (fetch.resultType == NSManagedObjectResultType || fetch.resultType == NSManagedObjectIDResultType) {
    [expansions addObjectsFromArray:[self toOneKeyExpansionsForEntity:entity except:expanded]];
  }
  if (expansions.count) {
    [items addObject:@[ @"$expand", [expansions componentsJoinedByString:@","] ]];
  }

  return [self composePath:set query:items error:error];
}

// Prefetch key paths as $expand items, a path through relationships
// nested (suppliers.products is Suppliers($expand=Products): 4.0 has no
// paths in $expand), and paths that share a start merged under it.
- (NSArray *)expansionsForKeyPaths:(NSArray *)paths entity:(NSEntityDescription *)entity
{
  NSMutableArray *order = [NSMutableArray array];          // wire names, first seen first
  NSMutableDictionary *children = [NSMutableDictionary dictionary];  // wire name -> key paths beneath
  NSMutableDictionary *destinations = [NSMutableDictionary dictionary];
  for (NSString *path in paths) {
    NSArray *parts = [path componentsSeparatedByString:@"."];
    NSRelationshipDescription *rel = entity.relationshipsByName[parts.firstObject];
    NSString *wire = rel ? [self.mapper propertyForRelationship:rel] : [self.mapper wireName:parts.firstObject];
    if (![self expands:wire entity:entity]) continue;
    if (!children[wire]) {
      [order addObject:wire];
      children[wire] = [NSMutableArray array];
      if (rel.destinationEntity) destinations[wire] = rel.destinationEntity;
    }
    if (parts.count > 1) [children[wire] addObject:[[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)] componentsJoinedByString:@"."]];
  }
  NSMutableArray *items = [NSMutableArray array];
  for (NSString *wire in order) {
    NSEntityDescription *destination = destinations[wire];
    NSMutableArray *nested = [[children[wire] count] && destination ? [self expansionsForKeyPaths:children[wire] entity:destination] : @[] mutableCopy];
    NSMutableArray *options = [NSMutableArray array];
    if (destination) {
      // Its rows as a fetch's are: trimmed, and naming their to-ones.
      NSString *select = [self selectForEntity:destination];
      if (select) [options addObject:[@"$select=" stringByAppendingString:select]];
      NSMutableSet *named = [NSMutableSet set];
      for (NSString *path in children[wire]) {
        NSRelationshipDescription *rel = destination.relationshipsByName[[path componentsSeparatedByString:@"."].firstObject];
        if (rel) [named addObject:[self.mapper propertyForRelationship:rel]];
      }
      [nested addObjectsFromArray:[self toOneKeyExpansionsForEntity:destination except:named]];
    }
    if (nested.count) [options addObject:[@"$expand=" stringByAppendingString:[nested componentsJoinedByString:@","]]];
    [items addObject:options.count ? [NSString stringWithFormat:@"%@(%@)", wire, [options componentsJoinedByString:@";"]] : wire];
  }
  return items;
}

- (NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier error:(NSError **)error
{
  return [self composePath:[identifier pathWithKeyAsSegment:self.keyAsSegment] query:@[] error:error];
}

- (NSURL *)URLForReferenceFromEntityURL:(NSURL *)entity
                            relationship:(NSRelationshipDescription *)relationship
                                  target:(NSURL *)target
{
  NSString *s = [NSString stringWithFormat:@"%@/%@/$ref?$id=%@", entity.absoluteString,
                 [self.mapper propertyForRelationship:relationship], OISPercentEncode(target.absoluteString ?: @"")];
  return [NSURL URLWithString:s];
}

- (NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier
               relationship:(NSRelationshipDescription *)relationship
                      error:(NSError **)error
{
  NSString *path = [NSString stringWithFormat:@"%@/%@", [identifier pathWithKeyAsSegment:self.keyAsSegment], [self.mapper propertyForRelationship:relationship]];
  NSArray *query = relationship.destinationEntity ? [self readingQueryForEntity:relationship.destinationEntity] : @[];
  return [self composePath:path query:query error:error];
}

- (NSURL *)URLForReadingIdentifier:(ODataResourceIdentifier *)identifier
                            entity:(NSEntityDescription *)entity
                             error:(NSError **)error
{
  return [self composePath:[identifier pathWithKeyAsSegment:self.keyAsSegment] query:[self readingQueryForEntity:entity] error:error];
}

@end
