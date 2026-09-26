// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "ODataPredicateTranslator.h"
#import "ODataError.h"

@interface ODataPredicateTranslator ()
- (nullable NSString *)translateExpression:(NSExpression *)expression error:(NSError **)error;
@end

@implementation ODataPredicateTranslator

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper entity:(NSEntityDescription *)entity
{
  self = [super init];
  if (!self) return nil;
  _mapper = mapper;
  _entity = entity;
  return self;
}

- (NSString *)translatePredicate:(NSPredicate *)predicate error:(NSError **)error
{
  if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
    return [self translateCompound:(NSCompoundPredicate *)predicate error:error];
  }
  if ([predicate isKindOfClass:[NSComparisonPredicate class]]) {
    return [self translateComparison:(NSComparisonPredicate *)predicate error:error];
  }
  if ([predicate.predicateFormat isEqualToString:@"TRUEPREDICATE"]) return @"true";
  if ([predicate.predicateFormat isEqualToString:@"FALSEPREDICATE"]) return @"false";
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, predicate.description);
  return nil;
}

- (NSString *)translateCompound:(NSCompoundPredicate *)compound error:(NSError **)error
{
  NSMutableArray *parts = [NSMutableArray array];
  for (NSPredicate *sub in compound.subpredicates) {
    NSString *t = [self translatePredicate:sub error:error];
    if (!t) return nil;
    [parts addObject:[NSString stringWithFormat:@"(%@)", t]];
  }
  switch (compound.compoundPredicateType) {
    case NSAndPredicateType: return [parts componentsJoinedByString:@" and "];
    case NSOrPredicateType: return [parts componentsJoinedByString:@" or "];
    case NSNotPredicateType:
      return parts.count ? [NSString stringWithFormat:@"not %@", parts.firstObject] : @"false";
    default:
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, compound.description);
      return nil;
  }
}

- (NSString *)function:(NSString *)name left:(NSString *)lhs right:(NSString *)rhs caseInsensitive:(BOOL)ci
{
  if (ci) return [NSString stringWithFormat:@"%@(tolower(%@), tolower(%@))", name, lhs, rhs];
  return [NSString stringWithFormat:@"%@(%@, %@)", name, lhs, rhs];
}

- (NSString *)translateComparison:(NSComparisonPredicate *)cmp error:(NSError **)error
{
  NSString *lhs = [self translateExpression:cmp.leftExpression error:error];
  if (!lhs) return nil;
  NSString *rhs = [self translateExpression:cmp.rightExpression error:error];
  if (!rhs) return nil;
  BOOL ci = (cmp.options & NSCaseInsensitivePredicateOption) != 0;
  switch (cmp.predicateOperatorType) {
    case NSEqualToPredicateOperatorType:
      return [NSString stringWithFormat:@"%@ eq %@", lhs, rhs];
    case NSNotEqualToPredicateOperatorType:
      return [NSString stringWithFormat:@"%@ ne %@", lhs, rhs];
    case NSLessThanPredicateOperatorType:
      return [NSString stringWithFormat:@"%@ lt %@", lhs, rhs];
    case NSLessThanOrEqualToPredicateOperatorType:
      return [NSString stringWithFormat:@"%@ le %@", lhs, rhs];
    case NSGreaterThanPredicateOperatorType:
      return [NSString stringWithFormat:@"%@ gt %@", lhs, rhs];
    case NSGreaterThanOrEqualToPredicateOperatorType:
      return [NSString stringWithFormat:@"%@ ge %@", lhs, rhs];
    case NSBeginsWithPredicateOperatorType:
      return [self function:@"startswith" left:lhs right:rhs caseInsensitive:ci];
    case NSEndsWithPredicateOperatorType:
      return [self function:@"endswith" left:lhs right:rhs caseInsensitive:ci];
    case NSContainsPredicateOperatorType:
      return [self function:@"contains" left:lhs right:rhs caseInsensitive:ci];
    case NSInPredicateOperatorType: {
      NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@"()"];
      return [NSString stringWithFormat:@"%@ in (%@)", lhs, [rhs stringByTrimmingCharactersInSet:trim]];
    }
    case NSBetweenPredicateOperatorType:
      if (cmp.rightExpression.expressionType == NSAggregateExpressionType) {
        NSArray *col = cmp.rightExpression.collection;
        if ([col isKindOfClass:[NSArray class]] && col.count == 2) {
          NSString *low = [self translateExpression:col[0] error:error];
          NSString *high = [self translateExpression:col[1] error:error];
          if (!low || !high) return nil;
          return [NSString stringWithFormat:@"(%@ ge %@ and %@ le %@)", lhs, low, lhs, high];
        }
      }
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, cmp.description);
      return nil;
    default:
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, cmp.description);
      return nil;
  }
}

- (NSString *)translateExpression:(NSExpression *)expression error:(NSError **)error
{
  switch (expression.expressionType) {
    case NSConstantValueExpressionType:
      return [self literal:expression.constantValue];
    case NSKeyPathExpressionType:
      return [self mapKeyPath:expression.keyPath];
    case NSEvaluatedObjectExpressionType:
      return @"$it";
    case NSFunctionExpressionType:
      return [self translateFunction:expression error:error];
    case NSAggregateExpressionType: {
      NSArray *col = expression.collection;
      if (![col isKindOfClass:[NSArray class]]) {
        if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, expression.description);
        return nil;
      }
      NSMutableArray *inner = [NSMutableArray array];
      for (NSExpression *e in col) {
        NSString *t = [self translateExpression:e error:error];
        if (!t) return nil;
        [inner addObject:t];
      }
      return [NSString stringWithFormat:@"(%@)", [inner componentsJoinedByString:@", "]];
    }
    default:
      if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, expression.description);
      return nil;
  }
}

- (NSString *)translateFunction:(NSExpression *)expression error:(NSError **)error
{
  NSString *name = expression.function;
  NSArray *args = expression.arguments ?: @[];
  if ([name isEqualToString:@"lowercase:"] || [name isEqualToString:@"uppercase:"]) {
    NSString *inner = [self translateExpression:args.firstObject error:error];
    if (!inner) return nil;
    return [name hasPrefix:@"lower"]
      ? [NSString stringWithFormat:@"tolower(%@)", inner]
      : [NSString stringWithFormat:@"toupper(%@)", inner];
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, expression.description);
  return nil;
}

- (NSString *)mapKeyPath:(NSString *)path
{
  NSArray *parts = [path componentsSeparatedByString:@"."];
  NSEntityDescription *current = self.entity;
  NSMutableArray *mapped = [NSMutableArray array];
  for (NSString *part in parts) {
    if (!current) {
      [mapped addObject:[self.mapper wireName:part]];
      continue;
    }
    NSAttributeDescription *attr = current.attributesByName[part];
    if (attr) {
      [mapped addObject:[self.mapper propertyForAttribute:attr]];
      current = nil;
      continue;
    }
    NSRelationshipDescription *rel = current.relationshipsByName[part];
    if (rel) {
      [mapped addObject:[self.mapper propertyForRelationship:rel]];
      current = rel.destinationEntity;
      continue;
    }
    [mapped addObject:[self.mapper wireName:part]];
  }
  return [mapped componentsJoinedByString:@"/"];
}

- (NSString *)literal:(id)value
{
  if (!value || value == [NSNull null]) return @"null";
  if ([value isKindOfClass:[NSNumber class]]) {
    const char *t = [value objCType];
    if (t && (t[0] == 'c' || t[0] == 'B')) return [value boolValue] ? @"true" : @"false";
    return [value stringValue];
  }
  if ([value isKindOfClass:[NSString class]]) {
    NSString *s = [value stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
    return [NSString stringWithFormat:@"'%@'", s];
  }
  if ([value isKindOfClass:[NSDate class]]) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
    return [f stringFromDate:value];
  }
  if ([value isKindOfClass:[NSUUID class]]) return [value UUIDString];
  if ([value isKindOfClass:[NSArray class]]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id v in value) [parts addObject:[self literal:v]];
    return [parts componentsJoinedByString:@", "];
  }
  NSString *s = [[value description] stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
  return [NSString stringWithFormat:@"'%@'", s];
}

@end
