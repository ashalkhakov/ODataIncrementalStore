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
// What a type cast on the way asks of an object's entity: the term has a
// value only where it holds, and is null elsewhere.
@property (nonatomic, strong, nullable) NSPredicate *guard;
// A collection's cast (Staff/NS.Manager): only its members of this type.
@property (nonatomic, strong, nullable) NSEntityDescription *elementType;
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

static NSPredicate *OISAnd(NSPredicate *a, NSPredicate *b)
{
  if (!a) return b;
  if (!b) return a;
  return [NSCompoundPredicate andPredicateWithSubpredicates:@[ a, b ]];
}

static void OISCollectSubentities(NSEntityDescription *entity, NSMutableArray *into)
{
  [into addObject:entity];
  for (NSEntityDescription *subentity in entity.subentities) OISCollectSubentities(subentity, into);
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
@property (nonatomic, copy) NSDictionary<NSString *, NSEntityDescription *> *entitiesByTypeName;
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

#pragma mark Types

// t (an object) is of type, or of a type derived from it: its entity is one
// of them. Apple's stores and FreeCoreData's all answer "entity" in a
// predicate, of the fetched object or one it reaches.
- (NSPredicate *)object:(OISTerm *)t isOfType:(NSEntityDescription *)type
{
  OISTerm *entity = [[OISTerm alloc] init];
  entity.variable = t.variable;
  entity.keyPath = t.keyPath ? [t.keyPath stringByAppendingString:@".entity"] : @"entity";
  NSMutableArray *entities = [NSMutableArray array];
  OISCollectSubentities(type, entities);
  return OISCompare([self pathExpression:entity], NSInPredicateOperatorType, [NSExpression expressionForConstantValue:entities], 0);
}

// The entity type a cast or isof names: a qualified name (NS.Manager), or,
// as some clients write it, the name in quotes.
- (NSEntityDescription *)typeNamed:(ODataExpression *)e what:(NSString *)what
{
  e = [self resolve:e];
  if (!e) return nil;
  NSString *name = nil;
  if (e.kind == ODataExpressionCast && !e.operand) name = e.name;
  if (e.kind == ODataExpressionLiteral && [e.value isKindOfClass:[NSString class]]) name = e.value;
  if (!name) return [self fail:400 message:[NSString stringWithFormat:@"%@ takes a qualified type name, not %@", what, e]];
  return [self typeForName:name what:what];
}

- (NSEntityDescription *)typeForName:(NSString *)name what:(NSString *)what
{
  if ([name hasPrefix:@"Edm."]) return [self unsupported:[NSString stringWithFormat:@"%@ with the primitive type %@", what, name]];
  NSEntityDescription *type = self.entitiesByTypeName[name];
  if (!type) return [self fail:400 message:[NSString stringWithFormat:@"%@ is not an entity type of this service", name]];
  return type;
}

// base as type: an object that is null unless it is of the type, a
// collection of those of its members that are.
- (OISTerm *)cast:(OISTerm *)base to:(NSEntityDescription *)type named:(NSString *)name
{
  if (base.kind != OISTermEntity && base.kind != OISTermCollection) {
    return [self unsupported:[NSString stringWithFormat:@"A cast of %@", base.wireName ?: @"a value"]];
  }
  if (![type isKindOfEntity:base.entity] && ![base.entity isKindOfEntity:type]) {
    return [self fail:400 message:[NSString stringWithFormat:@"%@ is not derived from %@, nor it from %@", name, base.entity.name, name]];
  }
  OISTerm *t = [[OISTerm alloc] init];
  t.kind = base.kind;
  t.variable = base.variable;
  t.keyPath = base.keyPath;
  t.guard = base.guard;
  t.elementType = base.elementType;
  t.entity = type;
  t.wireName = base.wireName ? [NSString stringWithFormat:@"%@/%@", base.wireName, name] : name;
  if (type != base.entity && [type isKindOfEntity:base.entity]) {
    if (base.kind == OISTermCollection) {
      t.elementType = type;
    } else {
      t.guard = OISAnd(base.guard, [self object:base isOfType:type]);
    }
  }
  return t;
}

// isof(Type), of $it, or isof(expression, Type).
- (NSPredicate *)isOf:(ODataExpression *)e
{
  NSArray<ODataExpression *> *args = e.arguments ?: @[];
  if (args.count != 1 && args.count != 2) return [self fail:400 message:@"isof takes a type, or an expression and a type"];
  NSEntityDescription *type = [self typeNamed:args.lastObject what:@"isof"];
  if (!type) return nil;
  OISTerm *object = args.count == 2 ? [self term:args[0]] : [self itTerm];
  if (!object) return nil;
  if (object.kind == OISTermCollection) return [self fail:400 message:[NSString stringWithFormat:@"isof: %@ is a collection", args[0]]];
  if (object.kind != OISTermEntity) return [self unsupported:@"isof of a value"];
  NSPredicate *test;
  if ([object.entity isKindOfEntity:type]) {
    // It is, when it is there at all.
    test = object.keyPath ? OISCompare([self pathExpression:object], NSNotEqualToPredicateOperatorType, [NSExpression expressionForConstantValue:nil], 0)
                          : [NSPredicate predicateWithValue:YES];
  } else if ([type isKindOfEntity:object.entity]) {
    test = [self object:object isOfType:type];
  } else {
    test = [NSPredicate predicateWithValue:NO];
  }
  return OISAnd(object.guard, test);
}

// p, about terms of which some are null where their guard does not hold:
// there p is as it would be for null, whenNull.
- (NSPredicate *)guarded:(NSPredicate *)p terms:(NSArray<OISTerm *> *)terms whenNull:(BOOL)whenNull
{
  if (!p) return nil;
  NSPredicate *guard = nil;
  for (OISTerm *t in terms) guard = OISAnd(guard, t.guard);
  if (!guard) return p;
  if (whenNull) return [NSCompoundPredicate orPredicateWithSubpredicates:@[ [NSCompoundPredicate notPredicateWithSubpredicate:guard], p ]];
  return OISAnd(guard, p);
}

// A collection member's test, where the collection is cast: of the type,
// and then the test.
- (NSPredicate *)member:(OISTerm *)element of:(OISTerm *)collection test:(NSPredicate *)test
{
  if (!collection.elementType) return test ?: [NSPredicate predicateWithValue:YES];
  return OISAnd([self object:element isOfType:collection.elementType], test);
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
      t.guard = collection.guard;
      t.wireName = e.description;
      if (collection.elementType) {
        OISTerm *element = [self elementOf:collection];
        NSPredicate *member = [self member:element of:collection test:nil];
        NSExpression *members = [NSExpression expressionForSubquery:[self pathExpression:collection]
                                              usingIteratorVariable:element.variable
                                                          predicate:member];
        t.expression = [NSExpression expressionForFunction:@"count:" arguments:@[ members ]];
        return t;
      }
      t.variable = collection.variable;
      t.keyPath = [NSString stringWithFormat:@"%@.@count", collection.keyPath];
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
    case ODataExpressionCast: {
      OISTerm *base = e.operand ? [self term:e.operand] : [self itTerm];
      if (!base) return nil;
      NSEntityDescription *type = [self typeForName:e.name what:@"A cast"];
      return type ? [self cast:base to:type named:e.name] : nil;
    }
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
  t.guard = base.guard;
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
  t.guard = OISAnd(l.guard, r.guard);
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
    t.guard = inner.guard;
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
    t.guard = inner.guard;
    return t;
  }
  if ([e.name isEqualToString:@"cast"]) {
    if (args.count != 1 && args.count != 2) return [self fail:400 message:@"cast takes a type, or an expression and a type"];
    NSEntityDescription *type = [self typeNamed:args.lastObject what:@"cast"];
    OISTerm *base = !type ? nil : args.count == 2 ? [self term:args[0]] : [self itTerm];
    return base ? [self cast:base to:type named:args.lastObject.description] : nil;
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
      if (!e.operand && !e.namedArguments && [e.name isEqualToString:@"isof"]) return [self isOf:e];
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
        NSPredicate *p = OISCompare([self valueExpression:t typedBy:nil], NSEqualToPredicateOperatorType,
                                    [NSExpression expressionForConstantValue:@YES], 0);
        return [self guarded:p terms:@[ t ] whenNull:NO];
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
  // Where a cast leaves a side null: null eq null, null ne 'x'.
  BOOL whenNull = NO;
  if (r.kind == OISTermLiteral && !(l.guard && r.guard)) {
    BOOL null = !r.literal.value || r.literal.value == [NSNull null];
    if (type == NSEqualToPredicateOperatorType) whenNull = null;
    if (type == NSNotEqualToPredicateOperatorType) whenNull = !null;
  }
  return [self guarded:[self comparison:type left:l right:r] terms:@[ l, r ] whenNull:whenNull];
}

- (NSPredicate *)comparison:(NSPredicateOperatorType)type left:(OISTerm *)l right:(OISTerm *)r
{
  if (l.caseFunction && r.kind == OISTermLiteral && [r.literal.value isKindOfClass:[NSString class]] &&
      (type == NSEqualToPredicateOperatorType || type == NSNotEqualToPredicateOperatorType)) {
    return [self caseless:l type:type literal:r.literal.value];
  }

  // A to-one relationship compares only with null.
  if (l.kind == OISTermEntity || r.kind == OISTermEntity) {
    OISTerm *entity = l.kind == OISTermEntity ? l : r;
    OISTerm *other = entity == l ? r : l;
    BOOL null = other.kind == OISTermLiteral && (!other.literal.value || other.literal.value == [NSNull null]);
    if (!null || (type != NSEqualToPredicateOperatorType && type != NSNotEqualToPredicateOperatorType)) {
      return [self unsupported:[NSString stringWithFormat:@"Comparing %@ with anything but null", entity.wireName ?: @"an entity"]];
    }
    // $it, or a lambda's variable, is there (a cast of it may not be).
    if (!entity.keyPath) return [NSPredicate predicateWithValue:type == NSNotEqualToPredicateOperatorType];
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
  return [self guarded:[self stringOperator:type name:name leftTerm:l rightTerm:r] terms:@[ l, r ] whenNull:NO];
}

- (NSPredicate *)stringOperator:(NSPredicateOperatorType)type name:(NSString *)name leftTerm:(OISTerm *)l rightTerm:(OISTerm *)r
{
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
  NSPredicate *p = OISCompare([self valueExpression:l typedBy:nil], NSInPredicateOperatorType,
                              [NSExpression expressionForConstantValue:values], 0);
  return [self guarded:p terms:@[ l ] whenNull:[values containsObject:[NSNull null]]];
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
  if (!e.body && all) return [self fail:400 message:@"all needs a condition"];
  if (!e.body && !collection.elementType) {
    NSExpression *count = [self pathExpression:collection];
    count = [NSExpression expressionForFunction:@"count:" arguments:@[ count ]];
    return [self guarded:OISCompare(count, NSGreaterThanPredicateOperatorType, zero, 0) terms:@[ collection ] whenNull:NO];
  }

  OISTerm *element = [self elementOf:collection];
  if (!e.body) {
    NSExpression *subquery = [NSExpression expressionForSubquery:[self pathExpression:collection]
                                            usingIteratorVariable:element.variable
                                                        predicate:[self member:element of:collection test:nil]];
    NSExpression *count = [NSExpression expressionForFunction:@"count:" arguments:@[ subquery ]];
    return [self guarded:OISCompare(count, NSGreaterThanPredicateOperatorType, zero, 0) terms:@[ collection ] whenNull:NO];
  }
  element.wireName = e.variable;
  NSString *variable = element.variable;
  OISTerm *outer = self.scope[e.variable];
  self.scope[e.variable] = element;
  NSPredicate *body = [self predicate:e.body];
  if (outer) {
    self.scope[e.variable] = outer;
  } else {
    [self.scope removeObjectForKey:e.variable];
  }
  if (!body) return nil;

  // any: some element matches; all: none fails to. Of a cast collection,
  // its elements of the type.
  NSPredicate *test = all ? [NSCompoundPredicate notPredicateWithSubpredicate:body] : body;
  test = [self member:element of:collection test:test];
  NSExpression *subquery = [NSExpression expressionForSubquery:[self pathExpression:collection]
                                          usingIteratorVariable:variable
                                                      predicate:test];
  NSExpression *count = [NSExpression expressionForFunction:@"count:" arguments:@[ subquery ]];
  NSPredicate *p = OISCompare(count, all ? NSEqualToPredicateOperatorType : NSGreaterThanPredicateOperatorType, zero, 0);
  return [self guarded:p terms:@[ collection ] whenNull:NO];
}

// A new variable for the members of a collection.
- (OISTerm *)elementOf:(OISTerm *)collection
{
  OISTerm *element = [[OISTerm alloc] init];
  element.kind = OISTermEntity;
  element.variable = [NSString stringWithFormat:@"v%ld", (long)self.variables++];
  element.entity = collection.entity;
  return element;
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
  build.entitiesByTypeName = self.entitiesByTypeName ?: @{};
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
    if (t && (t.kind != OISTermValue || t.expression || t.caseFunction || t.variable || !t.keyPath || t.guard)) {
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
