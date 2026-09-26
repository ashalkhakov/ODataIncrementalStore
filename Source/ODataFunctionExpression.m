// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataFunctionExpression.h"
#import "ODataOperationCall.h"

@implementation ODataFunctionExpression

+ (instancetype)expressionForFunction:(NSString *)name
                            onKeyPath:(NSString *)keyPath
                           parameters:(NSDictionary *)parameters
                        resultKeyPath:(NSString *)resultKeyPath
{
  ODataFunctionExpression *e = [[self alloc] initWithExpressionType:NSFunctionExpressionType];
  e->_functionName = [name copy];
  e->_bindingKeyPath = keyPath.length ? [keyPath copy] : nil;
  e->_parameters = [parameters copy] ?: @{};
  e->_resultKeyPath = resultKeyPath.length ? [resultKeyPath copy] : nil;
  return e;
}

+ (BOOL)supportsSecureCoding
{
  return YES;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
  self = [super initWithExpressionType:NSFunctionExpressionType];
  if (!self) return nil;
  _functionName = [[coder decodeObjectOfClass:[NSString class] forKey:@"ODataFunctionName"] copy] ?: @"";
  _bindingKeyPath = [[coder decodeObjectOfClass:[NSString class] forKey:@"ODataBindingKeyPath"] copy];
  NSSet *classes = [NSSet setWithObjects:[NSDictionary class], [NSArray class], [NSString class], [NSNumber class],
                                         [NSDate class], [NSData class], [NSNull class], [NSUUID class], nil];
  _parameters = [[coder decodeObjectOfClasses:classes forKey:@"ODataParameters"] copy] ?: @{};
  _resultKeyPath = [[coder decodeObjectOfClass:[NSString class] forKey:@"ODataResultKeyPath"] copy];
  return self;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
  [coder encodeObject:self.functionName forKey:@"ODataFunctionName"];
  [coder encodeObject:self.bindingKeyPath forKey:@"ODataBindingKeyPath"];
  [coder encodeObject:self.parameters forKey:@"ODataParameters"];
  [coder encodeObject:self.resultKeyPath forKey:@"ODataResultKeyPath"];
}

// Immutable, as expressions are.
- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

- (NSString *)function
{
  return self.functionName;
}

- (NSArray *)arguments
{
  return @[];
}

- (BOOL)isEqual:(id)other
{
  if (other == self) return YES;
  if (![other isKindOfClass:[ODataFunctionExpression class]]) return NO;
  ODataFunctionExpression *o = other;
  return [o.functionName isEqualToString:self.functionName] && [o.parameters isEqual:self.parameters] &&
         (o.bindingKeyPath == self.bindingKeyPath || [o.bindingKeyPath isEqual:self.bindingKeyPath]) &&
         (o.resultKeyPath == self.resultKeyPath || [o.resultKeyPath isEqual:self.resultKeyPath]);
}

- (NSUInteger)hash
{
  return self.functionName.hash ^ self.bindingKeyPath.hash ^ self.resultKeyPath.hash;
}

- (NSString *)description
{
  NSMutableArray *arguments = [NSMutableArray array];
  for (NSString *name in [self.parameters.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [arguments addObject:[NSString stringWithFormat:@"%@=%@", name, self.parameters[name]]];
  }
  NSString *call = [NSString stringWithFormat:@"%@(%@)", self.functionName, [arguments componentsJoinedByString:@","]];
  if (self.bindingKeyPath) call = [NSString stringWithFormat:@"%@.%@", self.bindingKeyPath, call];
  if (self.resultKeyPath) call = [NSString stringWithFormat:@"%@.%@", call, self.resultKeyPath];
  return call;
}

- (NSString *)predicateFormat
{
  return self.description;
}

- (id)expressionValueWithObject:(id)object context:(NSMutableDictionary *)context
{
  id target = self.bindingKeyPath ? [object valueForKeyPath:self.bindingKeyPath] : object;
  if (![target isKindOfClass:[NSManagedObject class]]) return nil;
  NSError *error = nil;
  id result = [target invokeODataOperation:self.functionName parameters:self.parameters error:&error];
  if (!result || result == [NSNull null]) return nil;
  return self.resultKeyPath ? [result valueForKeyPath:self.resultKeyPath] : result;
}

@end

@implementation ODataSortDescriptor

+ (instancetype)sortDescriptorWithExpression:(NSExpression *)expression ascending:(BOOL)ascending
{
  ODataSortDescriptor *d = [[self alloc] initWithKey:@"self" ascending:ascending];
  d->_expression = expression;
  return d;
}

- (id)copyWithZone:(NSZone *)zone
{
  return self;
}

- (id)reversedSortDescriptor
{
  return [ODataSortDescriptor sortDescriptorWithExpression:self.expression ascending:!self.ascending];
}

- (NSComparisonResult)compareObject:(id)a toObject:(id)b
{
  id x = [self.expression expressionValueWithObject:a context:nil];
  id y = [self.expression expressionValueWithObject:b context:nil];
  NSComparisonResult result;
  if (x == y) result = NSOrderedSame;
  else if (!x) result = NSOrderedAscending;
  else if (!y) result = NSOrderedDescending;
  else result = [x compare:y];
  if (!self.ascending) result = -result;
  return result;
}

- (NSString *)description
{
  return [NSString stringWithFormat:@"(%@, %@)", self.expression, self.ascending ? @"ascending" : @"descending"];
}

@end
