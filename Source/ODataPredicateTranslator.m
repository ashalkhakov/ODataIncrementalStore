// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataPredicateTranslator.h"
#import "ODataError.h"

@interface ODataPredicateTranslator ()
// Inside a lambda (any/all), paths start from this variable, not the
// entity being fetched; nested lambdas number theirs by depth.
@property (nonatomic, copy, nullable) NSString *lambdaVariable;
@property (nonatomic) NSUInteger lambdaDepth;
// The attribute a comparison's constant is compared with: it decides how
// the constant is written (a Date as an Edm.Date, a Decimal without an
// exponent, a Boolean from @0).
@property (nonatomic, strong, nullable) NSAttributeDescription *comparedAttribute;
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
  if (cmp.comparisonPredicateModifier != NSDirectPredicateModifier) {
    return [self translateLambda:cmp error:error];
  }
  if ([self comparesObjects:cmp.rightExpression]) {
    return [self translateObjectComparison:cmp error:error];
  }
  self.comparedAttribute = [self attributeAtExpression:cmp.leftExpression] ?: [self attributeAtExpression:cmp.rightExpression];
  NSString *lhs = [self translateExpression:cmp.leftExpression error:error];
  NSString *rhs = lhs ? [self translateExpression:cmp.rightExpression error:error] : nil;
  if (!rhs) {
    self.comparedAttribute = nil;
    return nil;
  }
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
      // gnustep-base rewrites BETWEEN into >= AND <= and wraps each bound,
      // already an NSExpression, in a second constant expression.
      if ([expression.constantValue isKindOfClass:[NSExpression class]]) {
        return [self translateExpression:expression.constantValue error:error];
      }
      return [self literal:expression.constantValue];
    case NSKeyPathExpressionType:
      return [self mapKeyPath:expression.keyPath];
    case NSEvaluatedObjectExpressionType:
      return self.lambdaVariable ?: @"$it";
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
  NSString *mapped = [self.mapper propertyPathForKeyPath:path entity:self.entity];
  return self.lambdaVariable ? [NSString stringWithFormat:@"%@/%@", self.lambdaVariable, mapped] : mapped;
}

#pragma mark - ANY / ALL

// ANY products.unitPrice > 100  ->  Products/any(x0:x0/UnitPrice gt 100)
// The key path splits at its first to-many relationship: what comes before
// is the collection, what comes after is compared inside the lambda. A
// further to-many step nests another lambda.
- (NSString *)translateLambda:(NSComparisonPredicate *)cmp error:(NSError **)error
{
  NSString *function = nil;
  switch (cmp.comparisonPredicateModifier) {
    case NSAnyPredicateModifier: function = @"any"; break;
    case NSAllPredicateModifier: function = @"all"; break;
    default: break;
  }
  NSExpression *left = cmp.leftExpression;
  if (!function || left.expressionType != NSKeyPathExpressionType) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, cmp.description);
    return nil;
  }

  NSArray *parts = [left.keyPath componentsSeparatedByString:@"."];
  NSEntityDescription *current = self.entity;
  NSRelationshipDescription *toMany = nil;
  NSUInteger i = 0;
  for (; i < parts.count; i++) {
    NSRelationshipDescription *rel = current.relationshipsByName[parts[i]];
    if (!rel) break;
    if (rel.isToMany) {
      toMany = rel;
      break;
    }
    current = rel.destinationEntity;
  }
  NSComparisonPredicate *direct =
      [NSComparisonPredicate predicateWithLeftExpression:left
                                         rightExpression:cmp.rightExpression
                                                modifier:NSDirectPredicateModifier
                                                    type:cmp.predicateOperatorType
                                                 options:cmp.options];
  // No collection on the path: ANY and ALL of one value is the value.
  if (!toMany) return [self translateComparison:direct error:error];

  NSString *collection = [self mapKeyPath:[[parts subarrayWithRange:NSMakeRange(0, i + 1)] componentsJoinedByString:@"."]];
  NSArray *rest = [parts subarrayWithRange:NSMakeRange(i + 1, parts.count - i - 1)];
  NSString *variable = [NSString stringWithFormat:@"x%lu", (unsigned long)self.lambdaDepth];

  ODataPredicateTranslator *inner = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:toMany.destinationEntity];
  inner.lambdaVariable = variable;
  inner.lambdaDepth = self.lambdaDepth + 1;
  inner.keysForObjectID = self.keysForObjectID;
  NSExpression *innerLeft = rest.count
      ? [NSExpression expressionForKeyPath:[rest componentsJoinedByString:@"."]]
      : [NSExpression expressionForEvaluatedObject];
  // The same modifier again: it takes effect only if the rest of the path
  // crosses another to-many relationship.
  NSComparisonPredicate *innerPredicate =
      [NSComparisonPredicate predicateWithLeftExpression:innerLeft
                                         rightExpression:cmp.rightExpression
                                                modifier:(rest.count ? cmp.comparisonPredicateModifier : NSDirectPredicateModifier)
                                                    type:cmp.predicateOperatorType
                                                 options:cmp.options];
  NSString *body = [inner translatePredicate:innerPredicate error:error];
  if (!body) return nil;
  return [NSString stringWithFormat:@"%@/%@(%@:%@)", collection, function, variable, body];
}

#pragma mark - Managed objects as constants

static BOOL OISIsObject(id value)
{
  return [value isKindOfClass:[NSManagedObject class]] || [value isKindOfClass:[NSManagedObjectID class]];
}

// The constant side's objects: one, or a collection of them for IN.
static NSArray *OISObjectsInExpression(NSExpression *expression)
{
  if (expression.expressionType == NSAggregateExpressionType) {
    NSMutableArray *out = [NSMutableArray array];
    for (NSExpression *e in expression.collection) {
      if (e.expressionType != NSConstantValueExpressionType || !OISIsObject(e.constantValue)) return nil;
      [out addObject:e.constantValue];
    }
    return out;
  }
  if (expression.expressionType != NSConstantValueExpressionType) return nil;
  id value = expression.constantValue;
  if (OISIsObject(value)) return @[ value ];
  if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
    NSArray *all = [value isKindOfClass:[NSSet class]] ? [value allObjects] : value;
    if (!all.count) return nil;
    for (id v in all) {
      if (!OISIsObject(v)) return nil;
    }
    return all;
  }
  return nil;
}

- (BOOL)comparesObjects:(NSExpression *)expression
{
  return OISObjectsInExpression(expression) != nil;
}

// An object's key, by wire name: from the store for an object ID, or from
// a managed object's own key attributes.
- (NSDictionary *)keysForObject:(id)object entity:(NSEntityDescription *)entity error:(NSError **)error
{
  NSManagedObjectID *oid = [object isKindOfClass:[NSManagedObject class]] ? [object objectID] : object;
  if (oid.isTemporaryID) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, @"An unsaved object has no key to compare");
    return nil;
  }
  NSDictionary *keys = self.keysForObjectID ? self.keysForObjectID(oid) : nil;
  if (!keys && [object isKindOfClass:[NSManagedObject class]]) {
    NSMutableDictionary *read = [NSMutableDictionary dictionary];
    for (NSAttributeDescription *attr in [self.mapper keyAttributesForEntity:entity]) {
      id value = [object valueForKey:attr.name];
      if (!value) break;
      read[[self.mapper propertyForAttribute:attr]] = value;
    }
    if (read.count) keys = read;
  }
  if (!keys.count) {
    if (error) *error = OISError(ODataIncrementalStoreErrorMissingKey, [NSString stringWithFormat:@"No key for %@", oid]);
    return nil;
  }
  return keys;
}

// A key written as its attribute's type: a Guid key, kept as a string,
// is still an unquoted Guid literal.
- (NSString *)keyLiteral:(id)value property:(NSString *)wire entity:(NSEntityDescription *)entity
{
  for (NSAttributeDescription *attr in [self.mapper keyAttributesForEntity:entity]) {
    if ([[self.mapper propertyForAttribute:attr] isEqualToString:wire]) {
      return [self.mapper.values literalForValue:value attribute:attr];
    }
  }
  return [self.mapper.values literalForValue:value attribute:nil];
}

// category == %@  ->  Category/CategoryID eq 2
// self IN %@      ->  ProductID in (1, 2)
// Objects compare by key, over the path to them; a compound key compares
// each part.
- (NSString *)translateObjectComparison:(NSComparisonPredicate *)cmp error:(NSError **)error
{
  NSExpression *left = cmp.leftExpression;
  NSEntityDescription *target = nil;
  NSString *path = nil;
  if (left.expressionType == NSEvaluatedObjectExpressionType) {
    target = self.entity;
    path = self.lambdaVariable;
  } else if (left.expressionType == NSKeyPathExpressionType) {
    NSEntityDescription *current = self.entity;
    for (NSString *part in [left.keyPath componentsSeparatedByString:@"."]) {
      NSRelationshipDescription *rel = current.relationshipsByName[part];
      if (!rel || rel.isToMany) {
        current = nil;
        break;
      }
      current = rel.destinationEntity;
    }
    target = current;
    path = [self mapKeyPath:left.keyPath];
  }
  if (!target) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"Objects compare only with self or a to-one relationship: %@", cmp]);
    return nil;
  }

  NSMutableArray *clauses = [NSMutableArray array];
  NSMutableArray *singles = [NSMutableArray array];
  BOOL singleKey = YES;
  for (id object in OISObjectsInExpression(cmp.rightExpression)) {
    NSDictionary *keys = [self keysForObject:object entity:target error:error];
    if (!keys) return nil;
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *wire in [keys.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      NSString *property = path.length ? [NSString stringWithFormat:@"%@/%@", path, wire] : wire;
      NSString *literal = [self keyLiteral:keys[wire] property:wire entity:target];
      [parts addObject:[NSString stringWithFormat:@"%@ eq %@", property, literal]];
      if (keys.count == 1) [singles addObject:@[ property, literal ]];
    }
    singleKey = singleKey && keys.count == 1;
    [clauses addObject:parts.count == 1 ? parts[0] : [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@" and "]]];
  }

  switch (cmp.predicateOperatorType) {
    case NSEqualToPredicateOperatorType:
      if (clauses.count == 1) return clauses[0];
      break;
    case NSNotEqualToPredicateOperatorType:
      if (clauses.count == 1) return [NSString stringWithFormat:@"not (%@)", clauses[0]];
      break;
    case NSInPredicateOperatorType: {
      if (singleKey) {
        NSMutableArray *literals = [NSMutableArray array];
        for (NSArray *pair in singles) [literals addObject:pair[1]];
        return [NSString stringWithFormat:@"%@ in (%@)", singles.firstObject[0], [literals componentsJoinedByString:@", "]];
      }
      return [NSString stringWithFormat:@"(%@)", [clauses componentsJoinedByString:@" or "]];
    }
    default:
      break;
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate, cmp.description);
  return nil;
}

#pragma mark - Literals

- (NSString *)literal:(id)value
{
  if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id v in value) [parts addObject:[self literal:v]];
    return [parts componentsJoinedByString:@", "];
  }
  return [self.mapper.values literalForValue:value attribute:self.comparedAttribute];
}

// The attribute at the end of a key path, through to-one relationships.
- (NSAttributeDescription *)attributeAtExpression:(NSExpression *)expression
{
  if (expression.expressionType != NSKeyPathExpressionType) return nil;
  NSEntityDescription *current = self.entity;
  NSAttributeDescription *found = nil;
  for (NSString *part in [expression.keyPath componentsSeparatedByString:@"."]) {
    if (found || !current) return nil;
    found = current.attributesByName[part];
    if (!found) {
      NSRelationshipDescription *rel = current.relationshipsByName[part];
      current = rel.destinationEntity;
    }
  }
  return found;
}

@end
