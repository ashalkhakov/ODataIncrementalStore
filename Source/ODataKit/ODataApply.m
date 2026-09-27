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
    case ODataApplyIdentity:
      return @"identity";
    case ODataApplySearch:
      return [NSString stringWithFormat:@"search(%@)", self.search];
    case ODataApplyCompute:
      return [NSString stringWithFormat:@"compute(%@)", [[self.compute valueForKey:@"description"] componentsJoinedByString:@","]];
    case ODataApplyOrderBy:
      return [NSString stringWithFormat:@"orderby(%@)", [[self.orderBy valueForKey:@"description"] componentsJoinedByString:@","]];
    case ODataApplyTop:
      return [NSString stringWithFormat:@"top(%@)", self.number];
    case ODataApplySkip:
      return [NSString stringWithFormat:@"skip(%@)", self.number];
    case ODataApplyTopBottom:
      return [NSString stringWithFormat:@"%@(%@,%@)", self.method, self.number, self.expression];
    case ODataApplyConcat: {
      NSMutableArray *branches = [NSMutableArray array];
      for (NSArray *branch in self.branches) [branches addObject:[ODataApplyTransformation stringForTransformations:branch]];
      return [NSString stringWithFormat:@"concat(%@)", [branches componentsJoinedByString:@","]];
    }
    case ODataApplyExpand:
      return [NSString stringWithFormat:@"expand(%@)", self.expansion];
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

// search, compute, orderby, top, skip, and the top and bottom kin.
+ (instancetype)readOther:(NSString *)name inside:(NSString *)inside text:(NSString *)text error:(NSError **)error
{
  ODataApplyTransformation *t = [[self alloc] init];
  t->_groupPaths = @[];
  t->_aggregates = @[];
  NSString *trimmed = [inside stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  NSNumber *(^number)(NSString *) = ^NSNumber *(NSString *value) {
    NSScanner *scanner = [NSScanner scannerWithString:[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]];
    double d;
    return [scanner scanDouble:&d] && scanner.isAtEnd && d >= 0 ? @(d) : nil;
  };
  if ([name isEqualToString:@"search"]) {
    t->_kind = ODataApplySearch;
    t->_search = [ODataSearchExpression searchWithString:trimmed error:error];
    return t->_search ? t : nil;
  }
  if ([name isEqualToString:@"compute"] || [name isEqualToString:@"orderby"]) {
    ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:@{ [@"$" stringByAppendingString:name]: trimmed } error:error];
    if (!options) return nil;
    t->_kind = [name isEqualToString:@"compute"] ? ODataApplyCompute : ODataApplyOrderBy;
    t->_compute = options.compute;
    t->_orderBy = options.orderBy;
    return t;
  }
  if ([name isEqualToString:@"top"] || [name isEqualToString:@"skip"]) {
    t->_kind = [name isEqualToString:@"top"] ? ODataApplyTop : ODataApplySkip;
    t->_number = number(trimmed);
    if (!t->_number || t->_number.doubleValue != floor(t->_number.doubleValue)) {
      if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"%@ takes a count", name], text);
      return nil;
    }
    return t;
  }
  NSArray *arguments = OISSplitTop(trimmed, ',');
  t->_kind = ODataApplyTopBottom;
  t->_method = name;
  t->_number = arguments.count == 2 ? number(arguments[0]) : nil;
  t->_expression = t->_number ? [ODataExpression expressionWithString:arguments[1] error:error] : nil;
  if (!t->_expression) {
    if (error && !*error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, [NSString stringWithFormat:@"%@ takes a number and a value", name], text);
    return nil;
  }
  return t;
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
    if ([[part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] isEqualToString:@"identity"]) {
      ODataApplyTransformation *t = [[self alloc] init];
      t->_kind = ODataApplyIdentity;
      t->_groupPaths = @[];
      t->_aggregates = @[];
      [transformations addObject:t];
      continue;
    }
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
    } else if ([@[ @"search", @"compute", @"orderby", @"top", @"skip", @"topcount", @"topsum", @"toppercent",
                   @"bottomcount", @"bottomsum", @"bottompercent" ] containsObject:name]) {
      ODataApplyTransformation *t = [self readOther:name inside:inside text:text error:error];
      if (!t) return nil;
      [transformations addObject:t];
    } else if ([name isEqualToString:@"concat"]) {
      // Each argument a sequence of its own, on the same input.
      NSMutableArray *branches = [NSMutableArray array];
      for (NSString *branch in OISSplitTop(inside, ',')) {
        NSArray *sequence = [self transformationsWithString:branch error:error];
        if (!sequence) return nil;
        [branches addObject:sequence];
      }
      if (branches.count < 2) {
        if (error) *error = OISApplyError(ODataIncrementalStoreErrorSyntax, @"concat takes two sequences or more", text);
        return nil;
      }
      ODataApplyTransformation *t = [[self alloc] init];
      t->_kind = ODataApplyConcat;
      t->_groupPaths = @[];
      t->_aggregates = @[];
      t->_branches = branches;
      [transformations addObject:t];
    } else if ([name isEqualToString:@"expand"]) {
      // expand(Nav) or expand(Nav, filter(...)): as $expand=Nav($filter=...).
      NSArray *arguments = OISSplitTop(inside, ',');
      NSArray *path = OISPath(arguments.firstObject ?: @"");
      NSString *inner = nil, *filter = arguments.count == 2 ? OISCall(arguments[1], &inner) : nil;
      if (path.count != 1 || arguments.count > 2 || (arguments.count == 2 && (!filter || ![inner isEqualToString:@"filter"]))) {
        if (error) *error = OISApplyError(arguments.count == 2 && [inner isEqualToString:@"expand"] ? ODataIncrementalStoreErrorUnsupportedExpression
                                                                                                   : ODataIncrementalStoreErrorSyntax,
                                          @"expand takes a navigation property and a filter", text);
        return nil;
      }
      ODataApplyTransformation *t = [[self alloc] init];
      t->_kind = ODataApplyExpand;
      t->_groupPaths = @[];
      t->_aggregates = @[];
      t->_expansion = filter ? [NSString stringWithFormat:@"%@($filter=%@)", path[0], filter] : path[0];
      [transformations addObject:t];
    } else if ([@[ @"nest", @"ancestors", @"descendants", @"traverse" ] containsObject:name]) {
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

+ (id)valueOfExpression:(ODataExpression *)e inRow:(id)row error:(NSError **)error
{
  if (e.kind == ODataExpressionLiteral) return e.value;
  NSArray *path = e.memberPath;
  if (e.kind == ODataExpressionMember && path.count) {
    id value = row;
    for (NSString *segment in path) value = [value isKindOfClass:[NSDictionary class]] ? value[segment] : [value valueForKey:segment];
    return value ?: [NSNull null];
  }
  BOOL negate = e.kind == ODataExpressionUnary && [e.name isEqualToString:@"-"];
  BOOL arithmetic = e.kind == ODataExpressionBinary && [@[ @"add", @"sub", @"mul", @"div", @"divby" ] containsObject:e.name];
  if (negate || arithmetic) {
    id l = [self valueOfExpression:negate ? e.operand : e.left inRow:row error:error];
    id r = negate ? @-1 : (l ? [self valueOfExpression:e.right inRow:row error:error] : nil);
    if (!l || !r) return nil;
    if (![l isKindOfClass:[NSNumber class]] || ![r isKindOfClass:[NSNumber class]]) return [NSNull null];
    // Decimals stay decimal; anything else is a double.
    if ([l isKindOfClass:[NSDecimalNumber class]] || [r isKindOfClass:[NSDecimalNumber class]]) {
      NSDecimalNumber *a = [l isKindOfClass:[NSDecimalNumber class]] ? l : [NSDecimalNumber decimalNumberWithDecimal:[l decimalValue]];
      NSDecimalNumber *b = [r isKindOfClass:[NSDecimalNumber class]] ? r : [NSDecimalNumber decimalNumberWithDecimal:[r decimalValue]];
      NSString *op = negate ? @"mul" : e.name;
      if ([op isEqualToString:@"add"]) return [a decimalNumberByAdding:b];
      if ([op isEqualToString:@"sub"]) return [a decimalNumberBySubtracting:b];
      if ([op isEqualToString:@"mul"]) return [a decimalNumberByMultiplyingBy:b];
      return [b isEqual:[NSDecimalNumber zero]] ? [NSNull null] : [a decimalNumberByDividingBy:b];
    }
    double a = [l doubleValue], b = [r doubleValue];
    NSString *op = negate ? @"mul" : e.name;
    if ([op isEqualToString:@"add"]) return @(a + b);
    if ([op isEqualToString:@"sub"]) return @(a - b);
    if ([op isEqualToString:@"mul"]) return @(a * b);
    return b == 0 ? [NSNull null] : @(a / b);
  }
  if (error) *error = OISError(ODataIncrementalStoreErrorUnsupportedExpression, [NSString stringWithFormat:@"%@ over aggregated rows", e]);
  return nil;
}

+ (NSArray *)rows:(NSArray *)rows values:(NSArray *)values method:(NSString *)method number:(double)number
{
  BOOL top = [method hasPrefix:@"top"];
  NSMutableArray *indexes = [NSMutableArray array];
  for (NSUInteger i = 0; i < rows.count; i++) {
    if ([values[i] isKindOfClass:[NSNumber class]]) [indexes addObject:@(i)];  // a null is none of them
  }
  [indexes sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
    NSComparisonResult order = [values[a.unsignedIntegerValue] compare:values[b.unsignedIntegerValue]];
    return top ? -order : order;
  }];
  double whole = 0;
  for (NSNumber *i in indexes) whole += [values[i.unsignedIntegerValue] doubleValue];
  double goal = [method hasSuffix:@"percent"] ? whole * number / 100.0 : number;
  NSMutableArray *out = [NSMutableArray array];
  double sum = 0;
  for (NSNumber *i in indexes) {
    if ([method hasSuffix:@"count"]) {
      if (out.count >= (NSUInteger)number) break;
    } else if (sum >= goal) {
      break;
    }
    [out addObject:rows[i.unsignedIntegerValue]];
    sum += [values[i.unsignedIntegerValue] doubleValue];
  }
  return out;
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
