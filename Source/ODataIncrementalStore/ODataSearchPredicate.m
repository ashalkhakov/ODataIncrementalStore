// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataSearchPredicate.h"

@implementation ODataSearchPredicate

+ (instancetype)predicateWithSearch:(NSString *)search error:(NSError **)error
{
  ODataSearchExpression *expression = [ODataSearchExpression searchWithString:search error:error];
  if (!expression) return nil;
  ODataSearchPredicate *predicate = [[self alloc] init];
  predicate->_search = expression;
  return predicate;
}

+ (instancetype)predicateWithSearch:(NSString *)search
{
  NSError *error = nil;
  ODataSearchPredicate *predicate = [self predicateWithSearch:search error:&error];
  if (!predicate) [NSException raise:NSInvalidArgumentException format:@"%@", error.localizedDescription];
  return predicate;
}

+ (BOOL)supportsSecureCoding
{
  return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  self = [super init];
  if (!self) return nil;
  NSString *text = [coder decodeObjectOfClass:[NSString class] forKey:@"ODataSearch"] ?: @"";
  _search = [ODataSearchExpression searchWithString:text error:NULL];
  return _search ? self : nil;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
  [coder encodeObject:self.search.description forKey:@"ODataSearch"];
}

// Immutable, as predicates are.
- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

- (BOOL)isEqual:(id)other
{
  return [other isKindOfClass:[ODataSearchPredicate class]] &&
         [((ODataSearchPredicate *)other).search.description isEqualToString:self.search.description];
}

- (NSUInteger)hash
{
  return self.search.description.hash;
}

- (NSString *)predicateFormat
{
  return [NSString stringWithFormat:@"ODATA_SEARCH(%@)", self.search];
}

- (NSString *)description
{
  return self.predicateFormat;
}

- (BOOL)evaluateWithObject:(id)object
{
  return [self evaluateWithObject:object substitutionVariables:nil];
}

- (BOOL)evaluateWithObject:(id)object substitutionVariables:(NSDictionary *)variables
{
  NSMutableArray *texts = [NSMutableArray array];
  NSEntityDescription *entity = [object isKindOfClass:[NSManagedObject class]] ? [(NSManagedObject *)object entity] : nil;
  if (entity) {
    for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
      if (attribute.attributeType != NSStringAttributeType) continue;
      id value = [object valueForKey:attribute.name];
      if ([value isKindOfClass:[NSString class]]) [texts addObject:value];
    }
  } else if ([object isKindOfClass:[NSDictionary class]]) {
    for (id value in [object allValues]) {
      if ([value isKindOfClass:[NSString class]]) [texts addObject:value];
    }
  }
  return [self.search matchesTexts:texts];
}

@end
