// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataPropertyMapper.h"

NSString * const ODataUserInfoEntitySet = @"OData.entitySet";
NSString * const ODataUserInfoProperty = @"OData.property";
NSString * const ODataUserInfoKey = @"OData.key";

@implementation ODataPropertyMapper

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _naming = ODataPropertyNamingPascalCase;
  return self;
}

- (NSString *)entitySetForEntity:(NSEntityDescription *)entity
{
  NSString *override = entity.userInfo[ODataUserInfoEntitySet];
  if ([override isKindOfClass:[NSString class]]) return override;
  NSString *name = entity.name ?: @"Entity";
  if ([name hasSuffix:@"s"]) return name;
  if ([name hasSuffix:@"y"] && name.length > 1) {
    return [[name substringToIndex:name.length - 1] stringByAppendingString:@"ies"];
  }
  return [name stringByAppendingString:@"s"];
}

- (NSString *)propertyForAttribute:(NSAttributeDescription *)attribute
{
  NSString *override = attribute.userInfo[ODataUserInfoProperty];
  if ([override isKindOfClass:[NSString class]]) return override;
  return [self wireName:attribute.name];
}

- (NSString *)propertyForRelationship:(NSRelationshipDescription *)relationship
{
  NSString *override = relationship.userInfo[ODataUserInfoProperty];
  if ([override isKindOfClass:[NSString class]]) return override;
  return [self wireName:relationship.name];
}

- (NSArray *)keyAttributesForEntity:(NSEntityDescription *)entity
{
  NSMutableArray *flagged = [NSMutableArray array];
  [entity.attributesByName enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
    // gnustep-base types this block (id, id, BOOL *): no generics to narrow it.
    NSString *name = key;
    NSAttributeDescription *attr = obj;
    (void)name;
    id flag = attr.userInfo[ODataUserInfoKey];
    if ([flag isEqual:@"YES"] || [flag isEqual:@YES]) [flagged addObject:attr];
  }];
  if (flagged.count) return flagged;
  NSArray *candidates = @[ @"id", @"ID", @"Id", [NSString stringWithFormat:@"%@ID", entity.name ?: @""] ];
  for (NSString *c in candidates) {
    NSAttributeDescription *attr = entity.attributesByName[c];
    if (attr) return @[ attr ];
  }
  return @[];
}

- (NSString *)wireName:(NSString *)coreDataName
{
  if (self.naming == ODataPropertyNamingAsIs || coreDataName.length == 0) return coreDataName;
  NSString *first = [[coreDataName substringToIndex:1] uppercaseString];
  return [first stringByAppendingString:[coreDataName substringFromIndex:1]];
}

@end
