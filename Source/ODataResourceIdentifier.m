// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

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
  return self;
}

- (NSString *)path
{
  if (self.keys.count == 1) {
    return [NSString stringWithFormat:@"%@(%@)", self.entitySet, OISKeyLiteral(self.keys.allValues.firstObject)];
  }
  NSMutableArray *parts = [NSMutableArray array];
  NSArray *names = [self.keys.allKeys sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    [parts addObject:[NSString stringWithFormat:@"%@=%@", name, OISKeyLiteral(self.keys[name])]];
  }
  return [NSString stringWithFormat:@"%@(%@)", self.entitySet, [parts componentsJoinedByString:@","]];
}

- (NSDictionary *)dictionary
{
  return @{ @"set": self.entitySet, @"keys": self.keys };
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
      return [[ODataResourceIdentifier alloc] initWithEntitySet:d[@"set"] keys:d[@"keys"]];
    }
  }
  return nil;
}

@end
