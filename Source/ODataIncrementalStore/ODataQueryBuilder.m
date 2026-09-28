// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataQueryBuilder.h"
#import "ODataFunctionExpression.h"
#import "ODataPredicateTranslator.h"
#import "ODataError.h"
#import "ODataSearchPredicate.h"
#import "ODataTemporalPredicate.h"
#import <ODataKit/ODataApply.h>
#import <objc/runtime.h>
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

// Whether the entity's set can be searched (Capabilities.SearchRestrictions).
- (BOOL)searches:(NSEntityDescription *)entity
{
  ODataSchema *schema = self.mapper.schema;
  if (!schema) return YES;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  id restrictions = [schema capability:@"Capabilities.SearchRestrictions" forEntitySet:[self.mapper entitySetForEntity:root]];
  return !([restrictions isKindOfClass:[NSDictionary class]] && [restrictions[@"Searchable"] isEqual:@NO]);
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
  // Stream properties too: not in the model, but their media ETags and
  // links come only with them.
  ODataSchemaEntityType *base = cast && entity.superentity ? [self.mapper entityTypeForEntity:entity.superentity] : nil;
  NSArray *inherited = base ? [self.mapper.schema streamPropertiesOfEntityType:base] : @[];
  for (NSString *stream in [self.mapper.schema streamPropertiesOfEntityType:type]) {
    if ([inherited containsObject:stream]) continue;
    [own addObject:cast ? [NSString stringWithFormat:@"%@/%@", cast, stream] : stream];
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

// The predicate without the searches ANDed at its top, which go into
// searches; nil when nothing else is left.
// The predicate without those of a class ANDed at its top (searches,
// application time), which go into found: a search as its expression.
static NSPredicate *OISWithout(NSPredicate *predicate, Class cls, NSMutableArray *found)
{
  if ([predicate isKindOfClass:cls]) {
    [found addObject:[predicate isKindOfClass:[ODataSearchPredicate class]] ? ((ODataSearchPredicate *)predicate).search : predicate];
    return nil;
  }
  if ([predicate isKindOfClass:[NSCompoundPredicate class]] &&
      ((NSCompoundPredicate *)predicate).compoundPredicateType == NSAndPredicateType) {
    NSMutableArray *rest = [NSMutableArray array];
    for (NSPredicate *sub in ((NSCompoundPredicate *)predicate).subpredicates) {
      NSPredicate *left = OISWithout(sub, cls, found);
      if (left) [rest addObject:left];
    }
    if (!rest.count) return nil;
    return rest.count == 1 ? rest.firstObject : [NSCompoundPredicate andPredicateWithSubpredicates:rest];
  }
  return predicate;
}

static NSPredicate *OISWithoutSearches(NSPredicate *predicate, NSMutableArray<ODataSearchExpression *> *searches)
{
  return OISWithout(predicate, [ODataSearchPredicate class], searches);
}

// Application time as its query options: $at, or $from with $to or
// $toInclusive, literals typed by the entity's period.
- (BOOL)addApplicationTime:(NSArray<ODataTemporalPredicate *> *)temporal entity:(NSEntityDescription *)entity
                        to:(NSMutableArray *)items error:(NSError **)error
{
  if (!temporal.count) return YES;
  NSEntityDescription *root = entity;
  while (root.superentity) root = root.superentity;
  NSAttributeDescription *start = root.attributesByName[root.userInfo[ODataUserInfoPeriodStart]];
  if (!start || temporal.count > 1) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 start ? @"One application-time predicate a fetch"
                                       : [NSString stringWithFormat:@"%@ has no application time (OData.periodStart)", entity.name]);
    return NO;
  }
  ODataTemporalPredicate *p = temporal.firstObject;
  NSString *(^literal)(NSDate *) = ^NSString *(NSDate *date) { return [self.mapper.values literalForValue:date attribute:start]; };
  if (p.at) {
    [items addObject:@[ @"$at", literal(p.at) ]];
  } else {
    [items addObject:@[ @"$from", literal(p.from) ]];
    if (p.to) [items addObject:@[ p.toInclusive ? @"$toInclusive" : @"$to", literal(p.to) ]];
  }
  return YES;
}

- (NSURL *)URLForFetch:(NSFetchRequest *)fetch entity:(NSEntityDescription *)entity error:(NSError **)error
{
  // The entity set, with a type cast for a derived type (Animals/Zoo.Lion).
  NSString *set = [self.mapper collectionPathForEntity:entity];
  NSMutableArray *items = [NSMutableArray array];

  NSMutableArray *temporal = [NSMutableArray array];
  NSPredicate *timeless = OISWithout(fetch.predicate, [ODataTemporalPredicate class], temporal);
  if (![self addApplicationTime:temporal entity:entity to:items error:error]) return nil;
  NSMutableArray<ODataSearchExpression *> *searches = [NSMutableArray array];
  NSPredicate *predicate = OISWithoutSearches(timeless, searches);
  if (predicate) {
    ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
    t.keysForObjectID = self.keysForObjectID;
    if (self.version) t.version = self.version;
    NSString *filter = [t translatePredicate:predicate error:error];
    if (!filter) return nil;
    NSString *refused = [self refusedFunctionIn:filter entity:entity];
    if (refused) {
      if (error) *error = OISError(ODataIncrementalStoreErrorNotAllowedByService,
                                   [NSString stringWithFormat:@"%@: the service does not filter with %@ (Capabilities.FilterFunctions)", entity.name, refused]);
      return nil;
    }
    [items addObject:@[ @"$filter", filter ]];
  }
  if (searches.count) {
    if (![self searches:entity]) {
      if (error) *error = OISError(ODataIncrementalStoreErrorNotAllowedByService,
                                   [NSString stringWithFormat:@"%@: the service does not search (Capabilities.SearchRestrictions)", entity.name]);
      return nil;
    }
    ODataSearchExpression *search = searches.firstObject;
    for (NSUInteger i = 1; i < searches.count; i++) {
      search = [ODataSearchExpression searchWithKind:ODataSearchAnd text:nil left:search right:searches[i]];
    }
    [items addObject:@[ @"$search", search.description ]];
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

  // A dictionary's key paths through to-one relationships: $select cannot
  // follow a navigation property (services answer 400), so each is an
  // $expand with its own $select, nested: Category($select=CategoryName).
  NSMutableDictionary *through = [NSMutableDictionary dictionary];
  if (fetch.resultType == NSDictionaryResultType && fetch.propertiesToFetch.count) {
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *computed = [NSMutableArray array];
    for (id prop in fetch.propertiesToFetch) {
      NSString *path = [prop isKindOfClass:[NSString class]] ? prop
                     : [prop isKindOfClass:[NSExpressionDescription class]] && [(NSExpressionDescription *)prop expression].expressionType == NSKeyPathExpressionType
                       ? [(NSExpressionDescription *)prop expression].keyPath : nil;
      if (path && [path rangeOfString:@"."].location != NSNotFound) {
        if (![self addPath:path entity:entity to:through error:error]) return nil;
        continue;
      }
      if ([prop isKindOfClass:[NSExpressionDescription class]]) {
        NSExpression *expression = [(NSExpressionDescription *)prop expression];
        if (expression.expressionType == NSKeyPathExpressionType) {
          [names addObject:[self.mapper propertyPathForKeyPath:expression.keyPath entity:entity]];
          continue;
        }
        // Computed by the service: $compute=<expression> as <name>.
        ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
        if (self.version) t.version = self.version;
        NSString *text = [t translateExpression:expression error:error];
        if (!text) return nil;
        [computed addObject:[NSString stringWithFormat:@"%@ as %@", text, [prop name]]];
        [names addObject:[prop name]];
      } else if ([prop isKindOfClass:[NSAttributeDescription class]]) {
        [names addObject:[self.mapper propertyForAttribute:prop]];
      } else if ([prop isKindOfClass:[NSString class]]) {
        NSAttributeDescription *attr = entity.attributesByName[prop];
        [names addObject:attr ? [self.mapper propertyForAttribute:attr] : [self.mapper wireName:prop]];
      }
    }
    if (computed.count) [items addObject:@[ @"$compute", [computed componentsJoinedByString:@","] ]];
    // Only related values asked for: the key, not every property.
    if (!names.count && through.count) {
      for (NSAttributeDescription *key in [self.mapper keyAttributesForEntity:entity]) [names addObject:[self.mapper propertyForAttribute:key]];
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
  if (through.count) {
    // A relationship expanded for a value is not expanded again to prefetch it.
    [expansions filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString *expansion, NSDictionary *bindings) {
      return !through[[expansion componentsSeparatedByString:@"("].firstObject];
    }]];
    for (NSString *navigation in [through.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      [expansions addObject:[self expansion:navigation node:through[navigation]]];
    }
  }
  if (expansions.count) {
    [items addObject:@[ @"$expand", [expansions componentsJoinedByString:@","] ]];
  }

  return [self composePath:set query:items error:error];
}

// A key path through to-one relationships, into a tree of expansions:
// navigation (wire name) -> { select: properties, expand: the same again }.
- (BOOL)addPath:(NSString *)keyPath entity:(NSEntityDescription *)entity to:(NSMutableDictionary *)tree error:(NSError **)error
{
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  NSMutableDictionary *level = tree;
  NSEntityDescription *at = entity;
  for (NSUInteger i = 0; i + 1 < parts.count; i++) {
    NSRelationshipDescription *relationship = at.relationshipsByName[parts[i]];
    if (!relationship || relationship.isToMany) {
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest,
                                   [NSString stringWithFormat:@"%@: a dictionary's key path goes through to-one relationships only", keyPath]);
      return NO;
    }
    NSString *navigation = [self.mapper propertyForRelationship:relationship];
    NSMutableDictionary *node = level[navigation];
    if (!node) level[navigation] = node = [@{ @"select": [NSMutableOrderedSet orderedSet], @"expand": [NSMutableDictionary dictionary] } mutableCopy];
    at = relationship.destinationEntity;
    if (i + 2 == parts.count) {
      NSAttributeDescription *attribute = at.attributesByName[parts.lastObject];
      if (!attribute) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedRequest, [NSString stringWithFormat:@"%@: not an attribute", keyPath]);
        return NO;
      }
      [node[@"select"] addObject:[self.mapper propertyForAttribute:attribute]];
    }
    level = node[@"expand"];
  }
  return YES;
}

- (NSString *)expansion:(NSString *)navigation node:(NSDictionary *)node
{
  NSMutableArray *options = [NSMutableArray array];
  NSOrderedSet *select = node[@"select"];
  if (select.count) [options addObject:[@"$select=" stringByAppendingString:[select.array componentsJoinedByString:@","]]];
  NSDictionary *expand = node[@"expand"];
  if (expand.count) {
    NSMutableArray *nested = [NSMutableArray array];
    for (NSString *name in [expand.allKeys sortedArrayUsingSelector:@selector(compare:)]) [nested addObject:[self expansion:name node:expand[name]]];
    [options addObject:[@"$expand=" stringByAppendingString:[nested componentsJoinedByString:@","]]];
  }
  return options.count ? [NSString stringWithFormat:@"%@(%@)", navigation, [options componentsJoinedByString:@";"]] : navigation;
}

- (NSURL *)URLForAggregateFetch:(NSFetchRequest *)fetch
                          entity:(NSEntityDescription *)entity
                      groupPaths:(NSArray *)paths
                      aggregates:(NSArray *)aggregates
                           after:(NSArray *)after
                           error:(NSError **)error
{
  NSMutableArray<ODataSearchExpression *> *searches = [NSMutableArray array];
  NSPredicate *predicate = OISWithoutSearches(fetch.predicate, searches);
  NSMutableArray *steps = [NSMutableArray array];
  if (predicate) {
    ODataPredicateTranslator *t = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:entity];
    t.keysForObjectID = self.keysForObjectID;
    if (self.version) t.version = self.version;
    NSString *filter = [t translatePredicate:predicate error:error];
    if (!filter) return nil;
    [steps addObject:[NSString stringWithFormat:@"filter(%@)", filter]];
  }
  ODataApplyTransformation *grouping = paths.count ? [ODataApplyTransformation groupByPaths:paths aggregates:aggregates]
                                                   : [ODataApplyTransformation aggregateWith:aggregates];
  [steps addObject:grouping.description];
  if (after.count) [steps addObjectsFromArray:after];
  NSMutableArray *items = [NSMutableArray arrayWithObject:@[ @"$apply", [steps componentsJoinedByString:@"/"] ]];
  if (searches.count) {
    ODataSearchExpression *search = searches.firstObject;
    for (NSUInteger i = 1; i < searches.count; i++) search = [ODataSearchExpression searchWithKind:ODataSearchAnd text:nil left:search right:searches[i]];
    [items addObject:@[ @"$search", search.description ]];
  }
  return [self composePath:[self.mapper collectionPathForEntity:entity] query:items error:error];
}

// A literal a grouped row's value is compared with: a number, a string, a
// boolean or null; nil for anything else.
static NSString *OISGroupedLiteral(id value)
{
  if (!value || value == [NSNull null]) return @"null";
  if ([value isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
  if (![value isKindOfClass:[NSNumber class]]) return nil;
  const char *type = [value objCType];
  // A boolean, as @YES and predicateWithFormat:'s YES are.
  if (type && (!strcmp(type, "c") || !strcmp(type, "B")) && ![value isKindOfClass:[NSDecimalNumber class]]) {
    return [value boolValue] ? @"true" : @"false";
  }
  if ([value isKindOfClass:[NSDecimalNumber class]]) return [value description];
  double d = [value doubleValue];
  if (isnan(d) || isinf(d)) return nil;
  return [value stringValue];
}

- (NSString *)groupedFilterForPredicate:(NSPredicate *)predicate names:(NSDictionary *)names
{
  if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
    NSCompoundPredicate *compound = (NSCompoundPredicate *)predicate;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSPredicate *sub in compound.subpredicates) {
      NSString *part = [self groupedFilterForPredicate:sub names:names];
      if (!part) return nil;
      [parts addObject:[NSString stringWithFormat:@"(%@)", part]];
    }
    switch (compound.compoundPredicateType) {
      case NSNotPredicateType: return parts.count == 1 ? [NSString stringWithFormat:@"not %@", parts[0]] : nil;
      case NSAndPredicateType: return parts.count ? [parts componentsJoinedByString:@" and "] : nil;
      case NSOrPredicateType: return parts.count ? [parts componentsJoinedByString:@" or "] : nil;
      default: return nil;
    }
  }
  if (![predicate isKindOfClass:[NSComparisonPredicate class]]) return nil;
  NSComparisonPredicate *cmp = (NSComparisonPredicate *)predicate;
  if (cmp.comparisonPredicateModifier != NSDirectPredicateModifier || cmp.options) return nil;
  NSExpression *left = cmp.leftExpression, *right = cmp.rightExpression;
  NSPredicateOperatorType type = cmp.predicateOperatorType;
  if (left.expressionType == NSConstantValueExpressionType && right.expressionType == NSKeyPathExpressionType) {
    NSExpression *swap = left; left = right; right = swap;
    NSDictionary *mirrored = @{ @(NSLessThanPredicateOperatorType): @(NSGreaterThanPredicateOperatorType),
                                @(NSGreaterThanPredicateOperatorType): @(NSLessThanPredicateOperatorType),
                                @(NSLessThanOrEqualToPredicateOperatorType): @(NSGreaterThanOrEqualToPredicateOperatorType),
                                @(NSGreaterThanOrEqualToPredicateOperatorType): @(NSLessThanOrEqualToPredicateOperatorType) };
    if (mirrored[@(type)]) type = [mirrored[@(type)] unsignedIntegerValue];
  }
  if (left.expressionType != NSKeyPathExpressionType || right.expressionType != NSConstantValueExpressionType) return nil;
  NSString *path = names[left.keyPath];
  NSString *literal = OISGroupedLiteral(right.constantValue);
  NSDictionary *operators = @{ @(NSEqualToPredicateOperatorType): @"eq", @(NSNotEqualToPredicateOperatorType): @"ne",
                               @(NSLessThanPredicateOperatorType): @"lt", @(NSLessThanOrEqualToPredicateOperatorType): @"le",
                               @(NSGreaterThanPredicateOperatorType): @"gt", @(NSGreaterThanOrEqualToPredicateOperatorType): @"ge" };
  NSString *op = operators[@(type)];
  if (!path || !literal || !op) return nil;
  return [NSString stringWithFormat:@"%@ %@ %@", path, op, literal];
}

- (NSString *)groupedOrderForSortDescriptors:(NSArray *)descriptors names:(NSDictionary *)names
{
  NSMutableArray *items = [NSMutableArray array];
  for (NSSortDescriptor *descriptor in descriptors) {
    NSString *path = descriptor.key ? names[descriptor.key] : nil;
    // (sel_isEqual: libobjc2's selectors carry types, so == may not match.)
    if (!path || !descriptor.selector || !sel_isEqual(descriptor.selector, @selector(compare:))) return nil;
#if defined(__APPLE__)
    // (gnustep-base has no comparator: a descriptor made with one has no
    // compare: there either.)
    if (descriptor.comparator) return nil;
#endif
    [items addObject:descriptor.ascending ? path : [path stringByAppendingString:@" desc"]];
  }
  return items.count ? [items componentsJoinedByString:@","] : nil;
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
