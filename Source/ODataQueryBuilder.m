// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataQueryBuilder.h"
#import "ODataPredicateTranslator.h"
#import "ODataError.h"

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
    if ([expanded containsObject:wire]) continue;
    NSMutableArray *keys = [NSMutableArray array];
    for (NSAttributeDescription *key in [self.mapper keyAttributesForEntity:rel.destinationEntity]) {
      [keys addObject:[self.mapper propertyForAttribute:key]];
    }
    if (!keys.count) continue;
    [out addObject:[NSString stringWithFormat:@"%@($select=%@)", wire, [keys componentsJoinedByString:@","]]];
  }
  return out;
}

- (NSArray *)readingQueryForEntity:(NSEntityDescription *)entity
{
  NSArray *expansions = [self toOneKeyExpansionsForEntity:entity except:[NSSet set]];
  return expansions.count ? @[ @[ @"$expand", [expansions componentsJoinedByString:@","] ] ] : @[];
}

- (NSURL *)URLForFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity error:(NSError **)error
{
  // The entity set, with a type cast for a derived type (Animals/Zoo.Lion).
  NSString *set = [self.mapper collectionPathForEntity:entity];
  NSMutableArray *items = [NSMutableArray array];

  if (fetch.predicate) {
    ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
    t.keysForObjectID = self.keysForObjectID;
    NSString *filter = [t translatePredicate:fetch.predicate error:error];
    if (!filter) return nil;
    [items addObject:@[ @"$filter", filter ]];
  }

  if (fetch.sortDescriptors.count) {
    NSMutableArray *bits = [NSMutableArray array];
    for (NSSortDescriptor *desc in fetch.sortDescriptors) {
      // category.name is Category/CategoryName: a dot would be a type cast.
      NSString *name = [self.mapper propertyPathForKeyPath:desc.key ?: @"" entity:entity];
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

  if (fetch.resultType == NSCountResultType) {
    return [self composePath:[set stringByAppendingString:@"/$count"] query:items error:error];
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
  }

  NSMutableArray *expansions = [NSMutableArray array];
  NSMutableSet *expanded = [NSMutableSet set];
  for (NSString *path in fetch.relationshipKeyPathsForPrefetching) {
    NSString *mapped = [self.mapper propertyPathForKeyPath:path entity:entity];
    [expansions addObject:mapped];
    [expanded addObject:[[mapped componentsSeparatedByString:@"/"] firstObject]];
  }
  if (fetch.resultType == NSManagedObjectResultType || fetch.resultType == NSManagedObjectIDResultType) {
    [expansions addObjectsFromArray:[self toOneKeyExpansionsForEntity:entity except:expanded]];
  }
  if (expansions.count) {
    [items addObject:@[ @"$expand", [expansions componentsJoinedByString:@","] ]];
  }

  return [self composePath:set query:items error:error];
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
