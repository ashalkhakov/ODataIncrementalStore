// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

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

- (NSURL *)URLForFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSString *set = [self.mapper entitySetForEntity:entity];
  NSMutableArray *items = [NSMutableArray array];

  if (fetch.predicate) {
    ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
    NSString *filter = [t translatePredicate:fetch.predicate error:error];
    if (!filter) return nil;
    [items addObject:@[ @"$filter", filter ]];
  }

  if (fetch.sortDescriptors.count) {
    NSMutableArray *bits = [NSMutableArray array];
    for (NSSortDescriptor *desc in fetch.sortDescriptors) {
      NSString *key = desc.key ?: @"";
      NSAttributeDescription *attr = entity.attributesByName[key];
      NSString *name = attr ? [self.mapper propertyForAttribute:attr] : [self.mapper wireName:key];
      [bits addObject:desc.ascending ? name : [name stringByAppendingString:@" desc"]];
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

  if (fetch.relationshipKeyPathsForPrefetching.count) {
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *path in fetch.relationshipKeyPathsForPrefetching) {
      NSMutableArray *segs = [NSMutableArray array];
      for (NSString *segment in [path componentsSeparatedByString:@"."]) {
        NSRelationshipDescription *rel = entity.relationshipsByName[segment];
        [segs addObject:rel ? [self.mapper propertyForRelationship:rel] : [self.mapper wireName:segment]];
      }
      [names addObject:[segs componentsJoinedByString:@"/"]];
    }
    [items addObject:@[ @"$expand", [names componentsJoinedByString:@","] ]];
  }

  return [self composePath:set query:items error:error];
}

- (NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier error:(NSError **)error
{
  return [self composePath:identifier.path query:@[] error:error];
}

- (NSURL *)URLForIdentifier:(ODataResourceIdentifier *)identifier
               relationship:(NSRelationshipDescription *)relationship
                      error:(NSError **)error
{
  NSString *path = [NSString stringWithFormat:@"%@/%@", identifier.path, [self.mapper propertyForRelationship:relationship]];
  return [self composePath:path query:@[] error:error];
}

@end
