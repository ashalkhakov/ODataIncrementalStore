// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataApply.h"
#import "ODataError.h"

@implementation ODataAggregate

+ (instancetype)aggregateOfPath:(NSArray *)path method:(NSString *)method alias:(NSString *)alias
{
  ODataAggregate *a = [[self alloc] init];
  a->_path = [path copy];
  a->_method = [method copy];
  a->_alias = [alias copy];
  return a;
}

- (NSString *)description
{
  if (!self.path) return [NSString stringWithFormat:@"$count as %@", self.alias];
  return [NSString stringWithFormat:@"%@ with %@ as %@", [self.path componentsJoinedByString:@"/"], self.method, self.alias];
}

@end

@implementation ODataApplyTransformation

+ (instancetype)filterWithExpression:(ODataExpression *)expression
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyFilter;
  t->_filter = expression;
  t->_groupPaths = @[];
  t->_aggregates = @[];
  return t;
}

+ (instancetype)groupByPaths:(NSArray *)paths aggregates:(NSArray *)aggregates
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyGroupBy;
  t->_groupPaths = [paths copy];
  t->_aggregates = [aggregates copy] ?: @[];
  return t;
}

+ (instancetype)aggregateWith:(NSArray *)aggregates
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_kind = ODataApplyAggregate;
  t->_groupPaths = @[];
  t->_aggregates = [aggregates copy];
  return t;
}

- (NSString *)description
{
  switch (self.kind) {
    case ODataApplyFilter:
      return [NSString stringWithFormat:@"filter(%@)", self.filter];
    case ODataApplyAggregate:
      return [NSString stringWithFormat:@"aggregate(%@)", [[self.aggregates valueForKey:@"description"] componentsJoinedByString:@","]];
    case ODataApplyGroupBy: {
      NSMutableArray *paths = [NSMutableArray array];
      for (NSArray *path in self.groupPaths) [paths addObject:[path componentsJoinedByString:@"/"]];
      NSString *grouped = [NSString stringWithFormat:@"(%@)", [paths componentsJoinedByString:@","]];
      if (!self.aggregates.count) return [NSString stringWithFormat:@"groupby(%@)", grouped];
      return [NSString stringWithFormat:@"groupby(%@,aggregate(%@))", grouped,
              [[self.aggregates valueForKey:@"description"] componentsJoinedByString:@","]];
    }
  }
  return @"";
}

+ (NSString *)stringForTransformations:(NSArray *)transformations
{
  return [[transformations valueForKey:@"description"] componentsJoinedByString:@"/"];
}

#pragma mark Reading

static NSError *OISApplyError(ODataIncrementalStoreErrorCode code, NSString *message, NSString *text)
{
  return OISError(code, [NSString stringWithFormat:@"$apply: %@ in \"%@\"", message, text]);
}

// text split at separator where it is outside parentheses and quotes.
static NSArray<NSString *> *OISSplitTop(NSString *text, unichar separator)
{
  NSMutableArray *parts = [NSMutableArray array];
  NSInteger depth = 0;
  BOOL quoted = NO;
  NSUInteger start = 0;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c == '\'') quoted = !quoted;  // '' inside a string toggles twice
    if (quoted) continue;
    if (c == '(') depth++;
    if (c == ')') depth--;
    if (c == separator && depth == 0) {
      [parts addObject:[[text substringWithRange:NSMakeRange(start, i - start)] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
      start = i + 1;
    }
  }
  [parts addObject:[[text substringFromIndex:start] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
  return parts;
}

// name(inside), or nil.
static NSString *OISCall(NSString *text, NSString **name)
{
  NSRange open = [text rangeOfString:@"("];
  if (open.location == NSNotFound || ![text hasSuffix:@")"]) return nil;
  *name = [[text substringToIndex:open.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  return [text substringWithRange:NSMakeRange(NSMaxRange(open), text.length - NSMaxRange(open) - 1)];
}

static NSArray<NSString *> *OISPath(NSString *text)
{
  NSArray *segments = [text componentsSeparatedByString:@"/"];
  for (NSString *segment in segments) {
    if (!segment.length) return nil;
    for (NSUInteger i = 0; i < segment.length; i++) {
      unichar c = [segment characterAtIndex:i];
      if (!(c == '_' || c == '.' || [[NSCharacterSet alphanumericCharacterSet] characterIsMember:c])) return nil;
    }
  }
  return segments;
}

+ (NSArray *)aggregatesIn:(NSString *)inside text:(NSString *)text error:(NSError **)error
{
  NSMutableArray *aggregates = [NSMutableArray array];
  for (NSString *item in OISSplitTop(inside, ',')) {
    NSArray *words = [[item componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]
                      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    if (words.count == 3 && [words[0] isEqualToString:@"$count"] && [words[1] isEqualToString:@"as"] && OISPath(words[2]).count == 1) {
      [aggregates addObject:[ODataAggregate aggregateOfPath:nil method:nil alias:words[2]]];
      continue;
    }
    if (words.count >= 3 && [words[1] isEqualToString:@"from"]) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, @"from is not supported", text);
      return nil;
    }
    NSArray *path = words.count == 5 ? OISPath(words[0]) : nil;
    if (!path || ![words[1] isEqualToString:@"with"] || ![words[3] isEqualToString:@"as"] || OISPath(words[4]).count != 1) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"\"%@\" is not path with method as alias", item], text);
      return nil;
    }
    if (![[ODataAggregation methods] containsObject:words[2]]) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"the method %@ is not supported", words[2]], text);
      return nil;
    }
    [aggregates addObject:[ODataAggregate aggregateOfPath:path method:words[2] alias:words[4]]];
  }
  return aggregates;
}

+ (NSArray *)transformationsWithString:(NSString *)text error:(NSError **)error
{
  NSMutableArray *transformations = [NSMutableArray array];
  NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!trimmed.length) {
    if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, @"no transformation", text);
    return nil;
  }
  for (NSString *part in OISSplitTop(trimmed, '/')) {
    NSString *name = nil;
    NSString *inside = OISCall(part, &name);
    if (!inside) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"\"%@\" is not a transformation", part], text);
      return nil;
    }
    if ([name isEqualToString:@"filter"]) {
      ODataExpression *expression = [ODataExpression expressionWithString:inside error:error];
      if (!expression) return nil;
      [transformations addObject:[self filterWithExpression:expression]];
    } else if ([name isEqualToString:@"aggregate"]) {
      NSArray *aggregates = [self aggregatesIn:inside text:text error:error];
      if (!aggregates) return nil;
      [transformations addObject:[self aggregateWith:aggregates]];
    } else if ([name isEqualToString:@"groupby"]) {
      NSArray *arguments = OISSplitTop(inside, ',');
      NSString *list = arguments.firstObject;
      if (![list hasPrefix:@"("] || ![list hasSuffix:@")"] || arguments.count > 2) {
        if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, @"groupby takes (paths) and an aggregate", text);
        return nil;
      }
      NSMutableArray *paths = [NSMutableArray array];
      for (NSString *item in OISSplitTop([list substringWithRange:NSMakeRange(1, list.length - 2)], ',')) {
        if ([item hasPrefix:@"rollup("] || [item isEqualToString:@"$all"]) {
          if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, @"rollup is not supported", text);
          return nil;
        }
        NSArray *path = OISPath(item);
        if (!path) {
          if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"\"%@\" is not a property path", item], text);
          return nil;
        }
        [paths addObject:path];
      }
      NSArray *aggregates = @[];
      if (arguments.count == 2) {
        NSString *inner = nil;
        NSString *innerInside = OISCall(arguments[1], &inner);
        if (!innerInside || ![inner isEqualToString:@"aggregate"]) {
          if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, @"groupby takes only aggregate after its paths", text);
          return nil;
        }
        aggregates = [self aggregatesIn:innerInside text:text error:error];
        if (!aggregates) return nil;
      }
      [transformations addObject:[self groupByPaths:paths aggregates:aggregates]];
    } else if ([@[ @"compute", @"topcount", @"topsum", @"toppercent", @"bottomcount", @"bottomsum", @"bottompercent",
                   @"identity", @"concat", @"expand", @"search", @"orderby", @"top", @"skip" ] containsObject:name]) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@ is not supported", name], text);
      return nil;
    } else {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"%@ is not a transformation", name], text);
      return nil;
    }
  }
  return transformations;
}

@end

#pragma mark - Evaluating

@implementation ODataAggregation

+ (NSSet *)methods
{
  static NSSet *methods;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    methods = [NSSet setWithObjects:@"sum", @"min", @"max", @"average", @"countdistinct", nil];
  });
  return methods;
}

static NSDecimalNumber *OISDecimal(NSNumber *n)
{
  return [n isKindOfClass:[NSDecimalNumber class]] ? (NSDecimalNumber *)n : [NSDecimalNumber decimalNumberWithDecimal:n.decimalValue];
}

static BOOL OISIsReal(NSNumber *n)
{
  if ([n isKindOfClass:[NSDecimalNumber class]]) return NO;
  const char *type = n.objCType;
  return type && (type[0] == 'd' || type[0] == 'f');
}

+ (id)aggregate:(ODataAggregate *)aggregate over:(NSArray *)objects
{
  if (!aggregate.path) return @(objects.count);
  NSString *keyPath = [aggregate.path componentsJoinedByString:@"."];
  NSMutableArray *values = [NSMutableArray array];
  for (id object in objects) {
    id value = [object valueForKeyPath:keyPath];
    if (value && value != [NSNull null]) [values addObject:value];
  }
  NSString *method = aggregate.method;
  if ([method isEqualToString:@"countdistinct"]) return @([NSSet setWithArray:values].count);
  if (!values.count) return [NSNull null];
  if ([method isEqualToString:@"min"] || [method isEqualToString:@"max"]) {
    id best = values.firstObject;
    BOOL min = [method isEqualToString:@"min"];
    for (id value in values) {
      NSComparisonResult order = [value compare:best];
      if ((min && order == NSOrderedAscending) || (!min && order == NSOrderedDescending)) best = value;
    }
    return best;
  }
  // sum and average: of numbers, exactly unless one is a double.
  BOOL real = NO;
  for (id value in values) {
    if (![value isKindOfClass:[NSNumber class]]) return [NSNull null];
    if (OISIsReal(value)) real = YES;
  }
  if (real) {
    double total = 0;
    for (NSNumber *value in values) total += value.doubleValue;
    return [method isEqualToString:@"average"] ? @(total / values.count) : @(total);
  }
  NSDecimalNumber *total = [NSDecimalNumber zero];
  for (NSNumber *value in values) total = [total decimalNumberByAdding:OISDecimal(value)];
  if ([method isEqualToString:@"average"]) {
    return [total decimalNumberByDividingBy:[NSDecimalNumber decimalNumberWithDecimal:@(values.count).decimalValue]];
  }
  return total;
}

+ (NSArray *)groupObjects:(NSArray *)objects byKeyPaths:(NSArray *)keyPaths aggregates:(NSArray *)aggregates
{
  NSMutableArray *order = [NSMutableArray array];
  NSMutableDictionary *groups = [NSMutableDictionary dictionary];
  for (id object in objects) {
    NSMutableArray *key = [NSMutableArray array];
    for (NSString *keyPath in keyPaths) [key addObject:[object valueForKeyPath:keyPath] ?: [NSNull null]];
    if (!groups[key]) {
      groups[key] = [NSMutableArray array];
      [order addObject:key];
    }
    [groups[key] addObject:object];
  }
  if (!keyPaths.count && !order.count) {
    [order addObject:@[]];
    groups[@[]] = [NSMutableArray array];
  }
  NSMutableArray *rows = [NSMutableArray array];
  for (NSArray *key in order) {
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < keyPaths.count; i++) row[keyPaths[i]] = key[i];
    for (ODataAggregate *aggregate in aggregates) row[aggregate.alias] = [self aggregate:aggregate over:groups[key]];
    [rows addObject:row];
  }
  return rows;
}

static NSExpression *OISRowOperand(ODataExpression *e, NSError **error)
{
  if (e.kind == ODataExpressionLiteral) {
    return [NSExpression expressionForConstantValue:e.value == [NSNull null] ? nil : e.value];
  }
  NSArray *path = e.memberPath;
  if (e.kind == ODataExpressionMember && path.count) {
    return [NSExpression expressionForKeyPath:[path componentsJoinedByString:@"."]];
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@ over aggregated rows", e]);
  return nil;
}

+ (NSPredicate *)predicateForExpression:(ODataExpression *)e error:(NSError **)error
{
  if (e.kind == ODataExpressionUnary && [e.name isEqualToString:@"not"]) {
    NSPredicate *inner = [self predicateForExpression:e.operand error:error];
    return inner ? [NSCompoundPredicate notPredicateWithSubpredicate:inner] : nil;
  }
  if (e.kind == ODataExpressionBinary && ([e.name isEqualToString:@"and"] || [e.name isEqualToString:@"or"])) {
    NSPredicate *left = [self predicateForExpression:e.left error:error];
    NSPredicate *right = left ? [self predicateForExpression:e.right error:error] : nil;
    if (!right) return nil;
    return [e.name isEqualToString:@"and"] ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ left, right ]]
                                           : [NSCompoundPredicate orPredicateWithSubpredicates:@[ left, right ]];
  }
  NSDictionary *operators = @{ @"eq": @(NSEqualToPredicateOperatorType), @"ne": @(NSNotEqualToPredicateOperatorType),
                               @"gt": @(NSGreaterThanPredicateOperatorType), @"ge": @(NSGreaterThanOrEqualToPredicateOperatorType),
                               @"lt": @(NSLessThanPredicateOperatorType), @"le": @(NSLessThanOrEqualToPredicateOperatorType) };
  NSNumber *type = e.kind == ODataExpressionBinary ? operators[e.name] : nil;
  if (!type) {
    if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@ over aggregated rows", e]);
    return nil;
  }
  NSExpression *left = OISRowOperand(e.left, error);
  NSExpression *right = left ? OISRowOperand(e.right, error) : nil;
  if (!right) return nil;
  return [NSComparisonPredicate predicateWithLeftExpression:left rightExpression:right modifier:NSDirectPredicateModifier
                                                       type:(NSPredicateOperatorType)type.unsignedIntegerValue options:0];
}

@end
