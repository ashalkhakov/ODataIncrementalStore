// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataResourceIdentifier.h"

NSString *OISKeyLiteral(id value)
{
  if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
  if ([value isKindOfClass:[NSUUID class]]) return [value UUIDString];
  NSString *s = [value description];
  s = [s stringByReplacingOccurrencesOfString:@"'" withString:@"''"];
  return [NSString stringWithFormat:@"'%@'", s];
}

@implementation ODataResourceIdentifier

- (instancetype)initWithEntitySet:(NSString *)entitySet keys:(NSDictionary *)keys
{
  self = [super init];
  if (!self) return nil;
  _entitySet = [entitySet copy];
  _keys = [keys copy] ?: @{};
  _unquotedKeys = [NSSet set];
  return self;
}

- (NSString *)path
{
  if (self.keys.count == 1) {
    NSString *name = self.keys.allKeys.firstObject;
    return [NSString stringWithFormat:@"%@(%@)", self.entitySet, [self literalForKey:name]];
  }
  NSMutableArray *parts = [NSMutableArray array];
  NSArray *names = [self.keys.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    [parts addObject:[NSString stringWithFormat:@"%@=%@", name, [self literalForKey:name]]];
  }
  return [NSString stringWithFormat:@"%@(%@)", self.entitySet, [parts componentsJoinedByString:@","]];
}

- (NSString *)literalForKey:(NSString *)name
{
  id value = self.keys[name];
  if ([self.unquotedKeys containsObject:name] && [value isKindOfClass:[NSString class]]) return value;
  return OISKeyLiteral(value);
}

// "unquoted" only when there are any, so the reference of an object with
// plain keys, and so its object ID, is what it always was.
- (NSDictionary *)dictionary
{
  if (!self.unquotedKeys.count) return @{ @"set": self.entitySet, @"keys": self.keys };
  NSArray *unquoted = [self.unquotedKeys.allObjects sortedArrayUsingSelector:@selector(compare:)];
  return @{ @"set": self.entitySet, @"keys": self.keys, @"unquoted": unquoted };
}

- (NSData *)data
{
  NSJSONWritingOptions opts = 0;
#ifdef NSJSONWritingSortedKeys
  opts = NSJSONWritingSortedKeys;
#endif
  return [NSJSONSerialization dataWithJSONObject:self.dictionary options:opts error:nil] ?: [NSData data];
}

+ (instancetype)identifierFromReference:(id)ref
{
  if ([ref isKindOfClass:[ODataResourceIdentifier class]]) return ref;
  if ([ref isKindOfClass:[NSData class]]) {
    id json = [NSJSONSerialization JSONObjectWithData:ref options:0 error:nil];
    return [self identifierFromReference:json];
  }
  if ([ref isKindOfClass:[NSDictionary class]]) {
    NSDictionary *d = ref;
    if (d[@"set"] && d[@"keys"]) {
      ODataResourceIdentifier *identifier = [[ODataResourceIdentifier alloc] initWithEntitySet:d[@"set"] keys:d[@"keys"]];
      if ([d[@"unquoted"] isKindOfClass:[NSArray class]]) identifier.unquotedKeys = [NSSet setWithArray:d[@"unquoted"]];
      return identifier;
    }
  }
  return nil;
}

@end
