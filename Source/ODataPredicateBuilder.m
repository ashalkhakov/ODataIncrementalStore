// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataPredicateBuilder.h"
#import "ODataError.h"
#import "ODataValue.h"

typedef NS_ENUM(NSInteger, OISTermKind) {
  OISTermValue,       // a scalar: an attribute's value, a count, a computed value
  OISTermEntity,      // one object: $it, a lambda's variable, a to-one relationship
  OISTermCollection,  // a to-many relationship
  OISTermLiteral      // a literal, typed once it is known what it meets
};

// What an expression stands for, on the way to an NSExpression.
@interface OISTerm : NSObject
@property (nonatomic) OISTermKind kind;
@property (nonatomic, copy, nullable) NSString *variable;  // a lambda's, generated; nil: $it
@property (nonatomic, copy, nullable) NSString *keyPath;   // from the variable (or $it); nil: itself
@property (nonatomic, strong, nullable) NSExpression *expression;  // a computed value's
@property (nonatomic, strong, nullable) NSAttributeDescription *attribute;  // types what it meets
@property (nonatomic, strong, nullable) NSEntityDescription *entity;
@property (nonatomic, copy, nullable) NSString *wireName;  // for messages
@property (nonatomic, strong, nullable) ODataExpression *literal;
@property (nonatomic, copy, nullable) NSString *caseFunction;  // tolower or toupper around `inner`
@property (nonatomic, strong, nullable) OISTerm *inner;
@end

@implementation OISTerm
@end

static BOOL OISIsPlainName(NSString *name)
{
  if (!name.length) return NO;
  for (NSUInteger i = 0; i < name.length; i++) {
    unichar c = [name characterAtIndex:i];
    BOOL letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_';
    if (!letter && !(i > 0 && c >= '0' && c <= '9')) return NO;
  }
  return YES;
}

// The function an arithmetic operator is in NSExpression. gnustep-base
// names them as its own parser writes them, and has no modulo.
static NSString *OISArithmeticFunction(NSString *op)
{
#if defined(__APPLE__)
  NSDictionary *names = @{ @"add": @"add:to:", @"sub": @"from:subtract:", @"mul": @"multiply:by:",
                           @"div": @"divide:by:", @"divby": @"divide:by:", @"mod": @"modulus:by:" };
#else
  NSDictionary *names = @{ @"add": @"_add", @"sub": @"_sub", @"mul": @"_mul", @"div": @"_div", @"divby": @"_div" };
#endif
  return names[op];
}

static NSPredicateOperatorType OISComparisonOperator(NSString *op)
{
  if ([op isEqualToString:@"ne"]) return NSNotEqualToPredicateOperatorType;
  if ([op isEqualToString:@"gt"]) return NSGreaterThanPredicateOperatorType;
  if ([op isEqualToString:@"ge"]) return NSGreaterThanOrEqualToPredicateOperatorType;
  if ([op isEqualToString:@"lt"]) return NSLessThanPredicateOperatorType;
  if ([op isEqualToString:@"le"]) return NSLessThanOrEqualToPredicateOperatorType;
  return NSEqualToPredicateOperatorType;
}

// The operator that keeps a comparison true with its sides swapped.
static NSString *OISSwapped(NSString *op)
{
  NSDictionary *swapped = @{ @"gt": @"lt", @"ge": @"le", @"lt": @"gt", @"le": @"ge" };
  return swapped[op] ?: op;
}

static NSPredicate *OISCompare(NSExpression *left, NSPredicateOperatorType type, NSExpression *right, NSComparisonPredicateOptions options)
{
  return [NSComparisonPredicate predicateWithLeftExpression:left
                                            rightExpression:right
                                                   modifier:NSDirectPredicateModifier
                                                       type:type
                                                    options:options];
}

#pragma mark - One translation

@interface OISPredicateBuild : NSObject
@property (nonatomic, strong) ODataPropertyMapper *mapper;
@property (nonatomic, strong) NSEntityDescription *root;
@property (nonatomic, copy) NSDictionary<NSString *, ODataExpression *> *aliases;
@property (nonatomic, strong) NSMutableDictionary<NSString *, OISTerm *> *scope;
@property (nonatomic) NSInteger variables;
@property (nonatomic, strong, nullable) NSError *error;
@end

@implementation OISPredicateBuild

- (id)fail:(NSInteger)status message:(NSString *)message
{
  if (!self.error) self.error = ODataServiceError(status, message);
  return nil;
}

- (id)unsupported:(NSString *)what
{
  return [self fail:501 message:[NSString stringWithFormat:@"%@ is not supported here", what]];
}

// An alias's value, followed through aliases of aliases.
- (ODataExpression *)resolve:(ODataExpression *)e
{
  for (NSInteger depth = 0; e.kind == ODataExpressionAlias; depth++) {
    ODataExpression *value = self.aliases[e.name];
    if (!value || depth > 8) return [self fail:400 message:[NSString stringWithFormat:@"no value for the parameter alias @%@", e.name]];
    e = value;
  }
  return e;
}

- (OISTerm *)itTerm
{
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = OISTermEntity;
  t.entity = self.root;
  return t;
}

- (NSExpression *)pathExpression:(OISTerm *)t
{
  if (t.expression) return t.expression;
  if (t.variable) {
    if (!t.keyPath) return [NSExpression expressionForVariable:t.variable];
    // Generated variable names and model property names only; see the header.
    return [NSExpression expressionWithFormat:[NSString stringWithFormat:@"$%@.%@", t.variable, t.keyPath]];
  }
  return t.keyPath ? [NSExpression expressionForKeyPath:t.keyPath] : [NSExpression expressionForEvaluatedObject];
}

#pragma mark Literals

- (id)valueOfLiteral:(ODataExpression *)literal attribute:(NSAttributeDescription *)attribute ok:(BOOL *)ok
{
  *ok = YES;
  id value = literal.value;
  if (!value || value == [NSNull null]) return nil;
  if (attribute) {
    id typed = [self.mapper.values coreDataValueForJSON:value attribute:attribute];
    if (typed && typed != [NSNull null]) return typed;
    *ok = NO;
    [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value of %@", literal, [self.mapper propertyForAttribute:attribute]]];
    return nil;
  }
  NSString *type = literal.literalType;
  if ([type isEqualToString:@"Edm.Date"] || [type isEqualToString:@"Edm.DateTimeOffset"]) return ODataDateFromString(value);
  if ([type isEqualToString:@"Edm.Duration"]) return ODataDurationFromString(value);
  if ([type isEqualToString:@"Edm.Binary"]) return ODataDataFromBase64(value);
  return value;
}

// A term as an expression, a literal typed by the attribute it meets.
- (NSExpression *)valueExpression:(OISTerm *)t typedBy:(OISTerm *)other
{
  if (t.kind == OISTermLiteral) {
    BOOL ok;
    id value = [self valueOfLiteral:t.literal attribute:other.attribute ?: other.inner.attribute ok:&ok];
    return ok ? [NSExpression expressionForConstantValue:value] : nil;
  }
  if (t.caseFunction) {
    NSExpression *inner = [self valueExpression:t.inner typedBy:other];
    if (!inner) return nil;
    NSString *function = [t.caseFunction isEqualToString:@"tolower"] ? @"lowercase:" : @"uppercase:";
    return [NSExpression expressionForFunction:function arguments:@[ inner ]];
  }
  return [self pathExpression:t];
}

#pragma mark Terms

- (OISTerm *)term:(ODataExpression *)e
{
  e = [self resolve:e];
  if (!e) return nil;
  switch (e.kind) {
    case ODataExpressionLiteral: {
      OISTerm *t = [[OISTerm alloc] init];
      t.kind = OISTermLiteral;
      t.literal = e;
      return t;
    }
    case ODataExpressionVariable: {
      if ([e.name isEqualToString:@"$it"]) return [self itTerm];
      OISTerm *scoped = self.scope[e.name];
      if (scoped) return scoped;
      if ([e.name hasPrefix:@"$"]) return [self unsupported:e.name];
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a lambda variable in scope", e.name]];
    }
    case ODataExpressionMember:
      return [self memberTerm:e];
    case ODataExpressionCount: {
      OISTerm *collection = [self term:e.operand];
      if (!collection) return nil;
      if (collection.kind != OISTermCollection) {
        return [self fail:400 message:[NSString stringWithFormat:@"%@/$count: not a collection", e.operand]];
      }
      OISTerm *t = [[OISTerm alloc] init];
      t.kind = OISTermValue;
      t.variable = collection.variable;
      t.keyPath = [NSString stringWithFormat:@"%@.@count", collection.keyPath];
      t.wireName = e.description;
      return t;
    }
    case ODataExpressionUnary:
      if ([e.name isEqualToString:@"-"]) return [self arithmetic:@"mul" left:e.operand right:nil negate:YES];
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value", e]];
    case ODataExpressionBinary:
      if (OISArithmeticFunction(e.name) || [e.name isEqualToString:@"mod"]) {
        return [self arithmetic:e.name left:e.left right:e.right negate:NO];
      }
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value", e]];
    case ODataExpressionCall:
      return [self callTerm:e];
    case ODataExpressionCast:
      return [self unsupported:@"A type cast"];
    default:
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value", e]];
  }
}

- (OISTerm *)memberTerm:(ODataExpression *)e
{
  OISTerm *base = e.operand ? [self term:e.operand] : [self itTerm];
  if (!base) return nil;
  if (base.kind == OISTermCollection) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ is a collection: its members are reached with any or all", e.operand]];
  }
  if (base.kind != OISTermEntity) return [self unsupported:[NSString stringWithFormat:@"The member %@ of a value", e.name]];

  NSPropertyDescription *property = [self.mapper propertyForWireName:e.name entity:base.entity];
  if (!property) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ has no property %@", base.entity.name, e.name]];
  }
  if (!OISIsPlainName(property.name)) return [self unsupported:[NSString stringWithFormat:@"The property %@", e.name]];

  OISTerm *t = [[OISTerm alloc] init];
  t.variable = base.variable;
  t.keyPath = base.keyPath ? [NSString stringWithFormat:@"%@.%@", base.keyPath, property.name] : property.name;
  t.wireName = base.wireName ? [NSString stringWithFormat:@"%@/%@", base.wireName, e.name] : e.name;
  if ([property isKindOfClass:[NSAttributeDescription class]]) {
    t.kind = OISTermValue;
    t.attribute = (NSAttributeDescription *)property;
  } else {
    NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
    t.kind = relationship.isToMany ? OISTermCollection : OISTermEntity;
    t.entity = relationship.destinationEntity;
  }
  return t;
}

- (OISTerm *)arithmetic:(NSString *)op left:(ODataExpression *)left right:(ODataExpression *)right negate:(BOOL)negate
{
  NSString *function = OISArithmeticFunction(op);
  if (!function) return [self unsupported:[NSString stringWithFormat:@"The operator %@", op]];
  OISTerm *l = [self term:left];
  OISTerm *r;
  if (negate) {
    r = [[OISTerm alloc] init];
    r.kind = OISTermValue;
    r.expression = [NSExpression expressionForConstantValue:@-1];
  } else {
    r = [self term:right];
  }
  if (!l || !r) return nil;
  for (OISTerm *side in @[ l, r ]) {
    if (side.kind == OISTermEntity || side.kind == OISTermCollection) {
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a number", side.wireName ?: @"an operand"]];
    }
  }
  NSExpression *le = [self valueExpression:l typedBy:r];
  NSExpression *re = [self valueExpression:r typedBy:l];
  if (!le || !re) return nil;
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = OISTermValue;
  t.expression = [NSExpression expressionForFunction:function arguments:@[ le, re ]];
  t.attribute = l.attribute ?: r.attribute;
  return t;
}

- (OISTerm *)callTerm:(ODataExpression *)e
{
  if (e.operand || e.namedArguments || [e.name rangeOfString:@"."].location != NSNotFound) {
    return [self unsupported:[NSString stringWithFormat:@"The function %@", e.name]];
  }
  NSArray<ODataExpression *> *args = e.arguments ?: @[];
  if ([e.name isEqualToString:@"tolower"] || [e.name isEqualToString:@"toupper"]) {
    if (args.count != 1) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes one argument", e.name]];
    OISTerm *inner = [self term:args[0]];
    if (!inner) return nil;
    if (inner.kind == OISTermLiteral) {
      NSString *text = [inner.literal.value isKindOfClass:[NSString class]] ? inner.literal.value : nil;
      if (!text) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes a string", e.name]];
      OISTerm *t = [[OISTerm alloc] init];
      t.kind = OISTermValue;
      t.expression = [NSExpression expressionForConstantValue:[e.name isEqualToString:@"tolower"] ? text.lowercaseString : text.uppercaseString];
      return t;
    }
    if (inner.kind != OISTermValue) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes a string", e.name]];
    OISTerm *t = [[OISTerm alloc] init];
    t.kind = OISTermValue;
    t.caseFunction = e.name;
    t.inner = inner;
    t.attribute = inner.attribute;
    return t;
  }
  if ([e.name isEqualToString:@"length"]) {
    if (args.count != 1) return [self fail:400 message:@"length takes one argument"];
    OISTerm *inner = [self term:args[0]];
    if (!inner) return nil;
    if (inner.kind != OISTermValue || inner.expression || inner.caseFunction || !inner.keyPath) {
      return [self unsupported:@"length of anything but a property"];
    }
    OISTerm *t = [[OISTerm alloc] init];
    t.kind = OISTermValue;
    t.variable = inner.variable;
    t.keyPath = [inner.keyPath stringByAppendingString:@".length"];
    return t;
  }
  if ([e.name isEqualToString:@"now"] && args.count == 0) {
    OISTerm *t = [[OISTerm alloc] init];
    t.kind = OISTermValue;
    t.expression = [NSExpression expressionForConstantValue:[NSDate date]];
    return t;
  }
  return [self unsupported:[NSString stringWithFormat:@"The function %@", e.name]];
}

#pragma mark Predicates

- (NSPredicate *)predicate:(ODataExpression *)e
{
  e = [self resolve:e];
  if (!e) return nil;
  switch (e.kind) {
    case ODataExpressionBinary: {
      if ([e.name isEqualToString:@"and"] || [e.name isEqualToString:@"or"]) {
        NSPredicate *l = [self predicate:e.left];
        NSPredicate *r = l ? [self predicate:e.right] : nil;
        if (!r) return nil;
        return [e.name isEqualToString:@"and"] ? [NSCompoundPredicate andPredicateWithSubpredicates:@[ l, r ]]
                                               : [NSCompoundPredicate orPredicateWithSubpredicates:@[ l, r ]];
      }
      if ([@[ @"eq", @"ne", @"gt", @"ge", @"lt", @"le" ] containsObject:e.name]) return [self compare:e.name left:e.left right:e.right];
      if ([e.name isEqualToString:@"in"]) return [self in:e.left list:e.right];
      if ([e.name isEqualToString:@"has"]) return [self unsupported:@"has"];
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a condition", e]];
    }
    case ODataExpressionUnary: {
      if (![e.name isEqualToString:@"not"]) return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a condition", e]];
      NSPredicate *p = [self predicate:e.operand];
      return p ? [NSCompoundPredicate notPredicateWithSubpredicate:p] : nil;
    }
    case ODataExpressionLambda:
      return [self lambda:e];
    case ODataExpressionLiteral:
      if ([e.value isKindOfClass:[NSNumber class]] && [e.literalType isEqualToString:@"Edm.Boolean"]) {
        return [NSPredicate predicateWithValue:[e.value boolValue]];
      }
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a condition", e]];
    case ODataExpressionCall:
      if (!e.operand && !e.namedArguments) {
        NSDictionary *operators = @{ @"contains": @(NSContainsPredicateOperatorType),
                                     @"startswith": @(NSBeginsWithPredicateOperatorType),
                                     @"endswith": @(NSEndsWithPredicateOperatorType) };
        NSNumber *type = operators[e.name];
        if (type) {
          if (e.arguments.count != 2) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes two arguments", e.name]];
          return [self stringOperator:(NSPredicateOperatorType)type.integerValue name:e.name left:e.arguments[0] right:e.arguments[1]];
        }
      }
      // fall through: a function that returns a boolean value
    default: {
      OISTerm *t = [self term:e];
      if (!t) return nil;
      if (t.kind == OISTermValue && t.attribute.attributeType == NSBooleanAttributeType) {
        return OISCompare([self pathExpression:t], NSEqualToPredicateOperatorType,
                          [NSExpression expressionForConstantValue:@YES], 0);
      }
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a condition", e]];
    }
  }
}

// tolower(Name) eq 'abc' is Name ==[c] 'abc'; tolower(Name) eq 'Abc' is
// never true. So a store that can compare without case need not lower
// every row.
- (NSPredicate *)caseless:(OISTerm *)wrapped type:(NSPredicateOperatorType)type literal:(NSString *)text
{
  NSString *folded = [wrapped.caseFunction isEqualToString:@"tolower"] ? text.lowercaseString : text.uppercaseString;
  if (![folded isEqualToString:text]) return [NSPredicate predicateWithValue:type == NSNotEqualToPredicateOperatorType];
  NSExpression *inner = [self valueExpression:wrapped.inner typedBy:nil];
  if (!inner) return nil;
  return OISCompare(inner, type, [NSExpression expressionForConstantValue:text], NSCaseInsensitivePredicateOption);
}

- (NSPredicate *)compare:(NSString *)op left:(ODataExpression *)left right:(ODataExpression *)right
{
  OISTerm *l = [self term:left];
  OISTerm *r = l ? [self term:right] : nil;
  if (!r) return nil;
  if (l.kind == OISTermLiteral && r.kind != OISTermLiteral) {
    OISTerm *swap = l;
    l = r;
    r = swap;
    op = OISSwapped(op);
  }
  NSPredicateOperatorType type = OISComparisonOperator(op);

  if (l.caseFunction && r.kind == OISTermLiteral && [r.literal.value isKindOfClass:[NSString class]] &&
      (type == NSEqualToPredicateOperatorType || type == NSNotEqualToPredicateOperatorType)) {
    return [self caseless:l type:type literal:r.literal.value];
  }

  // A to-one relationship compares only with null.
  if (l.kind == OISTermEntity || r.kind == OISTermEntity) {
    OISTerm *entity = l.kind == OISTermEntity ? l : r;
    OISTerm *other = entity == l ? r : l;
    BOOL null = other.kind == OISTermLiteral && (!other.literal.value || other.literal.value == [NSNull null]);
    if (!null || !entity.keyPath || (type != NSEqualToPredicateOperatorType && type != NSNotEqualToPredicateOperatorType)) {
      return [self unsupported:[NSString stringWithFormat:@"Comparing %@ with anything but null", entity.wireName ?: @"an entity"]];
    }
    return OISCompare([self pathExpression:entity], type, [NSExpression expressionForConstantValue:nil], 0);
  }
  for (OISTerm *side in @[ l, r ]) {
    if (side.kind == OISTermCollection) {
      return [self fail:400 message:[NSString stringWithFormat:@"%@ is a collection: use any, all or $count", side.wireName]];
    }
  }
  NSExpression *le = [self valueExpression:l typedBy:r];
  NSExpression *re = le ? [self valueExpression:r typedBy:l] : nil;
  if (!re) return nil;
  return OISCompare(le, type, re, 0);
}

- (NSPredicate *)stringOperator:(NSPredicateOperatorType)type name:(NSString *)name left:(ODataExpression *)left right:(ODataExpression *)right
{
  OISTerm *l = [self term:left];
  OISTerm *r = l ? [self term:right] : nil;
  if (!r) return nil;
  if (l.kind != OISTermValue && l.kind != OISTermLiteral) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes strings", name]];
  if (l.caseFunction && r.kind == OISTermLiteral && [r.literal.value isKindOfClass:[NSString class]]) {
    NSString *text = r.literal.value;
    NSString *folded = [l.caseFunction isEqualToString:@"tolower"] ? text.lowercaseString : text.uppercaseString;
    if (![folded isEqualToString:text]) return [NSPredicate predicateWithValue:NO];
    NSExpression *inner = [self valueExpression:l.inner typedBy:nil];
    return inner ? OISCompare(inner, type, [NSExpression expressionForConstantValue:text], NSCaseInsensitivePredicateOption) : nil;
  }
  NSExpression *le = [self valueExpression:l typedBy:r];
  NSExpression *re = le ? [self valueExpression:r typedBy:l] : nil;
  return re ? OISCompare(le, type, re, 0) : nil;
}

- (NSPredicate *)in:(ODataExpression *)left list:(ODataExpression *)list
{
  OISTerm *l = [self term:left];
  if (!l) return nil;
  list = [self resolve:list];
  if (!list) return nil;
  if (list.kind != ODataExpressionList) return [self unsupported:@"in with anything but a list of values"];
  if (l.kind != OISTermValue) return [self fail:400 message:[NSString stringWithFormat:@"%@ is not a value", left]];
  NSMutableArray *values = [NSMutableArray array];
  for (ODataExpression *item in list.arguments) {
    ODataExpression *value = [self resolve:item];
    if (!value) return nil;
    if (value.kind != ODataExpressionLiteral) return [self unsupported:@"in with anything but a list of values"];
    BOOL ok;
    id typed = [self valueOfLiteral:value attribute:l.attribute ok:&ok];
    if (!ok) return nil;
    [values addObject:typed ?: [NSNull null]];
  }
  return OISCompare([self valueExpression:l typedBy:nil], NSInPredicateOperatorType,
                    [NSExpression expressionForConstantValue:values], 0);
}

- (NSPredicate *)lambda:(ODataExpression *)e
{
  OISTerm *collection = [self term:e.operand];
  if (!collection) return nil;
  if (collection.kind != OISTermCollection) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@/%@: %@ is not a collection", e.operand, e.name, e.operand]];
  }
  BOOL all = [e.name isEqualToString:@"all"];
  NSExpression *zero = [NSExpression expressionForConstantValue:@0];
  if (!e.body) {
    if (all) return [self fail:400 message:@"all needs a condition"];
    NSExpression *count = [self pathExpression:collection];
    count = [NSExpression expressionForFunction:@"count:" arguments:@[ count ]];
    return OISCompare(count, NSGreaterThanPredicateOperatorType, zero, 0);
  }

  NSString *variable = [NSString stringWithFormat:@"v%ld", (long)self.variables++];
  OISTerm *element = [[OISTerm alloc] init];
  element.kind = OISTermEntity;
  element.variable = variable;
  element.entity = collection.entity;
  element.wireName = e.variable;
  OISTerm *outer = self.scope[e.variable];
  self.scope[e.variable] = element;
  NSPredicate *body = [self predicate:e.body];
  if (outer) {
    self.scope[e.variable] = outer;
  } else {
    [self.scope removeObjectForKey:e.variable];
  }
  if (!body) return nil;

  // any: some element matches; all: none fails to.
  NSPredicate *test = all ? [NSCompoundPredicate notPredicateWithSubpredicate:body] : body;
  NSExpression *subquery = [NSExpression expressionForSubquery:[self pathExpression:collection]
                                          usingIteratorVariable:variable
                                                      predicate:test];
  NSExpression *count = [NSExpression expressionForFunction:@"count:" arguments:@[ subquery ]];
  return OISCompare(count, all ? NSEqualToPredicateOperatorType : NSGreaterThanPredicateOperatorType, zero, 0);
}

@end

#pragma mark - The builder

@implementation ODataPredicateBuilder

- (instancetype)initWithMapper:(ODataPropertyMapper *)mapper
{
  self = [super init];
  if (!self) return nil;
  _mapper = mapper;
  return self;
}

- (OISPredicateBuild *)buildForEntity:(NSEntityDescription *)entity aliases:(NSDictionary *)aliases
{
  OISPredicateBuild *build = [[OISPredicateBuild alloc] init];
  build.mapper = self.mapper;
  build.root = entity;
  build.aliases = aliases ?: @{};
  build.scope = [NSMutableDictionary dictionary];
  return build;
}

- (NSPredicate *)predicateForExpression:(ODataExpression *)expression
                                 entity:(NSEntityDescription *)entity
                                aliases:(NSDictionary *)aliases
                                  error:(NSError **)error
{
  OISPredicateBuild *build = [self buildForEntity:entity aliases:aliases];
  NSPredicate *predicate = [build predicate:expression];
  if (!predicate && error) *error = build.error ?: ODataServiceError(400, @"The filter does not apply");
  return predicate;
}

- (NSArray *)sortDescriptorsForOrderBy:(NSArray *)items entity:(NSEntityDescription *)entity error:(NSError **)error
{
  OISPredicateBuild *build = [self buildForEntity:entity aliases:nil];
  NSMutableArray *descriptors = [NSMutableArray array];
  for (ODataOrderItem *item in items) {
    OISTerm *t = [build term:item.expression];
    if (t && (t.kind != OISTermValue || t.expression || t.caseFunction || t.variable || !t.keyPath)) {
      [build unsupported:[NSString stringWithFormat:@"Ordering by %@", item.expression]];
      t = nil;
    }
    if (!t) {
      if (error) *error = build.error;
      return nil;
    }
    [descriptors addObject:[NSSortDescriptor sortDescriptorWithKey:t.keyPath ascending:!item.descending]];
  }
  return descriptors;
}

- (NSString *)keyPathForPath:(NSArray *)path entity:(NSEntityDescription *)entity property:(NSPropertyDescription **)property error:(NSError **)error
{
  NSMutableArray *keys = [NSMutableArray array];
  NSEntityDescription *current = entity;
  NSPropertyDescription *found = nil;
  for (NSUInteger i = 0; i < path.count; i++) {
    NSString *name = path[i];
    found = current ? [self.mapper propertyForWireName:name entity:current] : nil;
    if (!found) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ has no property %@", current.name ?: @"A value", name]);
      return nil;
    }
    [keys addObject:found.name];
    NSRelationshipDescription *relationship = [found isKindOfClass:[NSRelationshipDescription class]] ? (NSRelationshipDescription *)found : nil;
    if (relationship.isToMany && i + 1 < path.count) {
      if (error) *error = ODataServiceError(400, [NSString stringWithFormat:@"%@ is a collection", name]);
      return nil;
    }
    current = relationship.destinationEntity;
  }
  if (property) *property = found;
  return [keys componentsJoinedByString:@"."];
}

@end
