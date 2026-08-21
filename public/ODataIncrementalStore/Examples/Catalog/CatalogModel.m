// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "CatalogModel.h"
#import "ODataPropertyMapper.h"

static NSAttributeDescription *Attr(NSString *name, NSString *wire, NSAttributeType type, BOOL key)
{
  NSAttributeDescription *attr = [[NSAttributeDescription alloc] init];
  attr.name = name;
  if ([attr respondsToSelector:@selector(setAttributeType:)]) attr.attributeType = type;
  NSMutableDictionary *info = [NSMutableDictionary dictionary];
  if (wire) info[ODataUserInfoProperty] = wire;
  if (key) info[ODataUserInfoKey] = @"YES";
  attr.userInfo = info;
  return attr;
}

NSManagedObjectModel *CatalogModel(void)
{
  NSEntityDescription *product = [[NSEntityDescription alloc] init];
  product.name = @"Product";
  product.userInfo = @{ ODataUserInfoEntitySet: @"Products" };
  NSArray *attrs = @[
    Attr(@"id", @"ProductID", NSInteger32AttributeType, YES),
    Attr(@"name", @"ProductName", NSStringAttributeType, NO),
    Attr(@"unitPrice", @"UnitPrice", NSDecimalAttributeType, NO),
    Attr(@"discontinued", @"Discontinued", NSBooleanAttributeType, NO),
    Attr(@"unitsInStock", @"UnitsInStock", NSInteger16AttributeType, NO),
  ];
  if ([product respondsToSelector:@selector(setProperties:)]) {
    [product setValue:attrs forKey:@"properties"];
  } else {
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    for (NSAttributeDescription *a in attrs) map[a.name] = a;
    [product setValue:map forKey:@"attributesByName"];
  }

  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  if ([model respondsToSelector:@selector(setEntities:)]) {
    [model setValue:@[product] forKey:@"entities"];
  } else {
    [model setValue:@{ @"Product": product } forKey:@"entitiesByName"];
  }
  return model;
}
