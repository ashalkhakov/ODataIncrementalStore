// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataPredicateTranslator.h"
#import "ODataError.h"
#import "ODataFunctionExpression.h"
#include <string.h>

@interface ODataPredicateTranslator ()
// Inside a lambda (any/all), paths start from this variable, not the
// entity being fetched; nested lambdas number theirs by depth.
@property (nonatomic, copy, nullable) NSString *lambdaVariable;
@property (nonatomic) NSUInteger lambdaDepth;
// The attribute a comparison's constant is compared with: it decides how
// the constant is written (a Date as an Edm.Date, a Decimal without an
// exponent, a Boolean from @0).
@property (nonatomic, strong, nullable) NSAttributeDescription *comparedAttribute;
// Or the type it is compared with, where that is no attribute's: a member
// of a complex value, an element of a collection.
@property (nonatomic, copy, nullable) NSString *comparedType;
// Inside a lambda over a collection of values (not of entities): their
// type, which paths inside the lambda start from.
@property (nonatomic, copy, nullable) NSString *elementType;
@end

@implementation ODataPredicateTranslator

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper entity:(NSEntityDescription *)entity
{
  self = [super init];
  if (!self) return nil;
  _mapper = mapper;
  _entity = entity;
  _version = @"4.0";
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
  if (cmp.predicateOperatorType == NSLikePredicateOperatorType || cmp.predicateOperatorType == NSMatchesPredicateOperatorType) {
    return [self translatePattern:cmp error:error];
  }
  self.comparedAttribute = [self attributeAtExpression:cmp.leftExpression] ?: [self attributeAtExpression:cmp.rightExpression];
  self.comparedType = [self typeAtExpression:cmp.leftExpression] ?: [self typeAtExpression:cmp.rightExpression];
  NSString *lhs = [self translateExpression:cmp.leftExpression error:error];
  NSString *rhs = lhs ? [self translateExpression:cmp.rightExpression error:error] : nil;
  if (!rhs) {
    self.comparedAttribute = nil;
    self.comparedType = nil;
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
      NSArray *literals = [self literalsInExpression:cmp.rightExpression error:error];
      return literals ? [self membership:lhs literals:literals] : nil;
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

- (BOOL)speaks401
{
  return [self.version compare:@"4.01" options:NSNumericSearch] != NSOrderedAscending;
}

// x in (a, b) in 4.01 (Part 2 section 5.1.1.1.12); (x eq a or x eq b) in
// 4.0, which has no `in`. Nothing to be in is false.
- (NSString *)membership:(NSString *)lhs literals:(NSArray *)literals
{
  if (!literals.count) return @"false";
  if (literals.count == 1) return [NSString stringWithFormat:@"%@ eq %@", lhs, literals[0]];
  if (self.speaks401) return [NSString stringWithFormat:@"%@ in (%@)", lhs, [literals componentsJoinedByString:@", "]];
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *literal in literals) [parts addObject:[NSString stringWithFormat:@"%@ eq %@", lhs, literal]];
  return [NSString stringWithFormat:@"(%@)", [parts componentsJoinedByString:@" or "]];
}

// The members of IN's right side, each as a literal.
- (NSArray *)literalsInExpression:(NSExpression *)expression error:(NSError **)error
{
  NSMutableArray *literals = [NSMutableArray array];
  if (expression.expressionType == NSAggregateExpressionType && [expression.collection isKindOfClass:[NSArray class]]) {
    for (NSExpression *e in expression.collection) {
      NSString *t = [self translateExpression:e error:error];
      if (!t) return nil;
      [literals addObject:t];
    }
    return literals;
  }
  id value = expression.expressionType == NSConstantValueExpressionType ? expression.constantValue : nil;
  if ([value isKindOfClass:[NSSet class]] || [value isKindOfClass:[NSOrderedSet class]]) value = [value allObjects];
  if (![value isKindOfClass:[NSArray class]]) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"IN needs a collection: %@", expression]);
    return nil;
  }
  for (id v in value) [literals addObject:[self literal:v]];
  return literals;
}

// LIKE and MATCHES: matchesPattern with an ECMAScript regular expression,
// anchored, since both match the whole string (Part 2 section
// 5.1.1.5.4, 4.01 only).
- (NSString *)translatePattern:(NSComparisonPredicate *)cmp error:(NSError **)error
{
  BOOL like = cmp.predicateOperatorType == NSLikePredicateOperatorType;
  BOOL ci = (cmp.options & NSCaseInsensitivePredicateOption) != 0;
  id pattern = cmp.rightExpression.expressionType == NSConstantValueExpressionType ? cmp.rightExpression.constantValue : nil;
  NSString *why = nil;
  if (!self.speaks401) why = @"needs OData 4.01 (matchesPattern), and the service speaks 4.0";
  else if (![pattern isKindOfClass:[NSString class]]) why = @"needs a constant pattern";
  else if (ci && !like) why = @"cannot be case-insensitive: a regular expression cannot be lowercased safely";
  if (why) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedPredicate,
                                 [NSString stringWithFormat:@"%@ %@: %@", like ? @"LIKE" : @"MATCHES", why, cmp]);
    return nil;
  }
  NSString *lhs = [self translateExpression:cmp.leftExpression error:error];
  if (!lhs) return nil;
  NSString *regex;
  if (like) {
    // * is any run, ? any one character, \ escapes; the rest is itself.
    NSMutableString *out = [NSMutableString stringWithString:@"^"];
    NSString *source = ci ? [pattern lowercaseString] : pattern;
    for (NSUInteger i = 0; i < source.length; i++) {
      unichar c = [source characterAtIndex:i];
      if (c == '\\' && i + 1 < source.length) c = [source characterAtIndex:++i];
      else if (c == '*') { [out appendString:@".*"]; continue; }
      else if (c == '?') { [out appendString:@"."]; continue; }
      if (c < 128 && strchr("\\^$.|?*+()[]{}/", (int)c)) [out appendString:@"\\"];
      [out appendFormat:@"%C", c];
    }
    [out appendString:@"$"];
    regex = out;
  } else {
    regex = [NSString stringWithFormat:@"^(?:%@)$", pattern];
  }
  NSString *literal = [NSString stringWithFormat:@"'%@'", [regex stringByReplacingOccurrencesOfString:@"'" withString:@"''"]];
  return [NSString stringWithFormat:@"matchesPattern(%@, %@)", ci ? [NSString stringWithFormat:@"tolower(%@)", lhs] : lhs, literal];
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
  if ([expression isKindOfClass:[ODataFunctionExpression class]]) {
    return [self translateODataFunction:(ODataFunctionExpression *)expression type:NULL attribute:NULL error:error];
  }
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
  NSString *mapped = self.elementType
      ? [self.mapper memberPath:[path componentsSeparatedByString:@"."] ofType:self.elementType memberType:NULL]
      : [self.mapper propertyPathForKeyPath:path entity:self.entity];
  return self.lambdaVariable ? [NSString stringWithFormat:@"%@/%@", self.lambdaVariable, mapped] : mapped;
}

#pragma mark - The service's functions

- (NSEntityDescription *)modelEntityForType:(NSString *)qualified
{
  for (NSEntityDescription *entity in self.entity.managedObjectModel.entities) {
    if ([[self.mapper qualifiedTypeForEntity:entity] isEqualToString:qualified]) return entity;
  }
  return nil;
}

// NS.GetFavoriteAirline()/Name: the call, bound to the entity the binding
// key path leads to (or to a collection, when it ends in a to-many
// relationship), and the path into its result. Through type and
// attribute, what the path ends at, for the literal it is compared with.
- (NSString *)translateODataFunction:(ODataFunctionExpression *)expression
                                type:(NSString **)typeOut
                           attribute:(NSAttributeDescription **)attributeOut
                               error:(NSError **)error
{
  NSString *why = nil;
  ODataSchema *schema = self.mapper.schema;
  NSEntityDescription *bound = self.entity;
  BOOL collection = NO;
  if (!schema) why = @"needs the service's $metadata";
  else if (self.elementType) why = @"is bound to entities, not to a collection of values";
  for (NSString *part in why ? @[] : [expression.bindingKeyPath componentsSeparatedByString:@"."] ?: @[]) {
    NSRelationshipDescription *rel = collection ? nil : bound.relationshipsByName[part];
    if (!rel) {
      why = [NSString stringWithFormat:@"is bound through %@, which is no relationship to follow", expression.bindingKeyPath];
      break;
    }
    bound = rel.destinationEntity;
    collection = rel.isToMany;
  }
  ODataSchemaEntityType *boundType = why ? nil : [self.mapper entityTypeForEntity:bound];
  if (!why && !boundType) why = [NSString stringWithFormat:@"is bound to %@, which has no entity type in $metadata", bound.name];
  NSSet *names = [NSSet setWithArray:expression.parameters.allKeys];
  ODataSchemaOperation *function = boundType ? [schema operationNamed:expression.functionName boundToEntityType:boundType
                                                              collection:collection parameterNames:names] : nil;
  if (!why && (!function || function.isAction)) {
    why = [NSString stringWithFormat:@"is no function bound to %@%@", collection ? @"a collection of " : @"", boundType.qualifiedName];
  }

  NSMutableArray *arguments = [NSMutableArray array];
  for (NSString *given in why ? @[] : [expression.parameters.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaParameter *parameter = nil;
    for (ODataSchemaParameter *p in function.callerParameters) {
      if ([p.name isEqualToString:given] || (!parameter && [p.name caseInsensitiveCompare:given] == NSOrderedSame)) parameter = p;
    }
    if (!parameter) {
      why = [NSString stringWithFormat:@"has no parameter %@", given];
      break;
    }
    [arguments addObject:[NSString stringWithFormat:@"%@=%@", parameter.name,
                                                     [self.mapper.values literalForValue:expression.parameters[given] typeName:parameter.type]]];
  }

  // Into the result: an entity's properties, a complex value's members.
  NSString *resultPath = nil;
  NSString *resultType = function.returnType;
  NSAttributeDescription *attribute = nil;
  if (!why && expression.resultKeyPath) {
    NSEntityDescription *resultEntity = [schema entityTypeNamed:resultType] ? [self modelEntityForType:resultType] : nil;
    if (resultEntity) {
      NSString *memberType = nil;
      resultPath = [self.mapper propertyPathForKeyPath:expression.resultKeyPath entity:resultEntity memberType:&memberType];
      attribute = [self attributeAtKeyPath:expression.resultKeyPath entity:resultEntity];
      resultType = memberType;
    } else if ([schema complexTypeNamed:resultType]) {
      NSString *memberType = nil;
      resultPath = [self.mapper memberPath:[expression.resultKeyPath componentsSeparatedByString:@"."] ofType:resultType memberType:&memberType];
      resultType = memberType;
    } else {
      why = [NSString stringWithFormat:@"returns %@, which has no %@ to follow", resultType ?: @"nothing", expression.resultKeyPath];
    }
  }
  if (why) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression,
                                 [NSString stringWithFormat:@"%@ %@", expression.functionName, why]);
    return nil;
  }

  NSString *call = [NSString stringWithFormat:@"%@(%@)", function.qualifiedName, [arguments componentsJoinedByString:@","]];
  NSString *prefix = expression.bindingKeyPath ? [self mapKeyPath:expression.bindingKeyPath] : self.lambdaVariable;
  if (prefix.length) call = [NSString stringWithFormat:@"%@/%@", prefix, call];
  if (resultPath.length) call = [NSString stringWithFormat:@"%@/%@", call, resultPath];
  if (typeOut) *typeOut = attribute ? nil : resultType;
  if (attributeOut) *attributeOut = attribute;
  return call;
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

  // Walk the path to its first collection: a to-many relationship, or an
  // attribute or complex member holding a collection of values.
  NSArray *parts = [left.keyPath componentsSeparatedByString:@"."];
  NSEntityDescription *current = self.elementType ? nil : self.entity;
  NSString *currentType = self.elementType;
  NSEntityDescription *elementEntity = nil;
  NSString *elementType = nil;
  NSUInteger i = 0;
  for (; i < parts.count; i++) {
    NSString *type = nil;
    if (current) {
      NSRelationshipDescription *rel = current.relationshipsByName[parts[i]];
      if (rel) {
        if (rel.isToMany) {
          elementEntity = rel.destinationEntity;
          break;
        }
        current = rel.destinationEntity;
        continue;
      }
      NSAttributeDescription *attr = current.attributesByName[parts[i]];
      if (!attr) break;
      type = [self.mapper.values typeNameOfAttribute:attr];
      current = nil;
    } else {
      [self.mapper memberPath:@[ parts[i] ] ofType:currentType memberType:&type];
    }
    if ([type hasPrefix:@"Collection("] && [type hasSuffix:@")"]) {
      elementType = [type substringWithRange:NSMakeRange(11, type.length - 12)];
      break;
    }
    if (!type) break;
    currentType = type;
  }
  NSComparisonPredicate *direct =
      [NSComparisonPredicate predicateWithLeftExpression:left
                                         rightExpression:cmp.rightExpression
                                                modifier:NSDirectPredicateModifier
                                                    type:cmp.predicateOperatorType
                                                 options:cmp.options];
  // No collection on the path: ANY and ALL of one value is the value.
  if (!elementEntity && !elementType) return [self translateComparison:direct error:error];

  NSString *collection = [self mapKeyPath:[[parts subarrayWithRange:NSMakeRange(0, i + 1)] componentsJoinedByString:@"."]];
  NSArray *rest = [parts subarrayWithRange:NSMakeRange(i + 1, parts.count - i - 1)];
  NSString *variable = [NSString stringWithFormat:@"x%lu", (unsigned long)self.lambdaDepth];

  ODataPredicateTranslator *inner = [[ODataPredicateTranslator alloc] initWithMapper:self.mapper entity:elementEntity ?: self.entity];
  inner.elementType = elementType;
  inner.lambdaVariable = variable;
  inner.lambdaDepth = self.lambdaDepth + 1;
  inner.keysForObjectID = self.keysForObjectID;
  inner.version = self.version;
  NSExpression *innerLeft = rest.count
      ? [NSExpression expressionForKeyPath:[rest componentsJoinedByString:@"."]]
      : [NSExpression expressionForEvaluatedObject];
  // The same modifier again: it takes effect only if the rest of the path
  // crosses another collection.
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
        return [self membership:singles.firstObject[0] literals:literals];
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
  if (self.comparedType) return [self.mapper.values literalForValue:value typeName:self.comparedType];
  return [self.mapper.values literalForValue:value attribute:self.comparedAttribute];
}

// The type a key path ends at when that is no attribute: a complex value's
// member, or inside a lambda over values, the element or its member.
- (NSString *)typeAtExpression:(NSExpression *)expression
{
  NSString *type = nil;
  if ([expression isKindOfClass:[ODataFunctionExpression class]]) {
    [self translateODataFunction:(ODataFunctionExpression *)expression type:&type attribute:NULL error:NULL];
    return type;
  }
  if (expression.expressionType == NSEvaluatedObjectExpressionType) return self.elementType;
  if (expression.expressionType != NSKeyPathExpressionType) return nil;
  if (self.elementType) {
    [self.mapper memberPath:[expression.keyPath componentsSeparatedByString:@"."] ofType:self.elementType memberType:&type];
  } else {
    [self.mapper propertyPathForKeyPath:expression.keyPath entity:self.entity memberType:&type];
  }
  return type;
}

// The attribute at the end of a key path, through to-one relationships.
- (NSAttributeDescription *)attributeAtExpression:(NSExpression *)expression
{
  if ([expression isKindOfClass:[ODataFunctionExpression class]]) {
    NSAttributeDescription *attribute = nil;
    [self translateODataFunction:(ODataFunctionExpression *)expression type:NULL attribute:&attribute error:NULL];
    return attribute;
  }
  if (expression.expressionType != NSKeyPathExpressionType || self.elementType) return nil;
  return [self attributeAtKeyPath:expression.keyPath entity:self.entity];
}

- (NSAttributeDescription *)attributeAtKeyPath:(NSString *)keyPath entity:(NSEntityDescription *)entity
{
  NSEntityDescription *current = entity;
  NSAttributeDescription *found = nil;
  for (NSString *part in [keyPath componentsSeparatedByString:@"."]) {
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
