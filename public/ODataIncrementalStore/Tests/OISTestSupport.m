// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "OISTestSupport.h"

NSString *OISSnapshotDirectory(void)
{
  NSString *env = NSProcessInfo.processInfo.environment[@"OIS_SNAPSHOTS"];
  if (env.length) return env;
  NSBundle *bundle = [NSBundle bundleForClass:NSClassFromString(@"ODataSnapshotStoreTests")];
  NSString *inBundle = [bundle.resourcePath stringByAppendingPathComponent:@"Snapshots"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:inBundle]) return inBundle;
  NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
  return [here stringByAppendingPathComponent:@"Snapshots"];
}

NSURL *OISTestServiceRoot(void)
{
  return [NSURL URLWithString:@"https://odata.test/V4/Northwind.svc/"];
}

NSAttributeDescription *OISAttr(NSString *name, NSString *wire, NSAttributeType type)
{
  NSAttributeDescription *attr = [[NSAttributeDescription alloc] init];
  attr.name = name;
  attr.attributeType = type;
  if (wire) attr.userInfo = @{ ODataUserInfoProperty: wire };
  return attr;
}

static NSEntityDescription *OISCachedProduct;
static NSEntityDescription *OISCachedCategory;

static void OISApplyProperties(NSEntityDescription *entity, NSDictionary *attrs, NSRelationshipDescription *rel)
{
  NSMutableArray *all = [NSMutableArray arrayWithArray:attrs.allValues];
  if (rel) [all addObject:rel];
  if ([entity respondsToSelector:@selector(setProperties:)]) {
    [entity setValue:all forKey:@"properties"];
    return;
  }
  entity.attributesByName = attrs;
  if (rel) entity.relationshipsByName = @{ rel.name: rel };
}

NSEntityDescription *OISCategoryEntity(void)
{
  if (OISCachedCategory) return OISCachedCategory;
  NSEntityDescription *entity = [[NSEntityDescription alloc] init];
  entity.name = @"Category";
  entity.userInfo = @{ ODataUserInfoEntitySet: @"Categories" };
  NSAttributeDescription *idAttr = OISAttr(@"id", @"CategoryID", NSInteger32AttributeType);
  NSMutableDictionary *info = [idAttr.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
  info[ODataUserInfoKey] = @"YES";
  idAttr.userInfo = info;
  NSDictionary *attrs = @{
    @"id": idAttr,
    @"name": OISAttr(@"name", @"CategoryName", NSStringAttributeType),
    @"descriptionText": OISAttr(@"descriptionText", @"Description", NSStringAttributeType),
  };
  OISApplyProperties(entity, attrs, nil);
  OISCachedCategory = entity;
  return entity;
}

NSEntityDescription *OISProductEntity(void)
{
  if (OISCachedProduct) return OISCachedProduct;
  NSEntityDescription *entity = [[NSEntityDescription alloc] init];
  entity.name = @"Product";
  entity.userInfo = @{ ODataUserInfoEntitySet: @"Products" };
  NSAttributeDescription *idAttr = OISAttr(@"id", @"ProductID", NSInteger32AttributeType);
  NSMutableDictionary *info = [idAttr.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
  info[ODataUserInfoKey] = @"YES";
  idAttr.userInfo = info;
  NSDictionary *attrs = @{
    @"id": idAttr,
    @"name": OISAttr(@"name", @"ProductName", NSStringAttributeType),
    @"unitPrice": OISAttr(@"unitPrice", @"UnitPrice", NSDecimalAttributeType),
    @"discontinued": OISAttr(@"discontinued", @"Discontinued", NSBooleanAttributeType),
    @"unitsInStock": OISAttr(@"unitsInStock", @"UnitsInStock", NSInteger16AttributeType),
    @"quantityPerUnit": OISAttr(@"quantityPerUnit", @"QuantityPerUnit", NSStringAttributeType),
  };
  NSRelationshipDescription *rel = [[NSRelationshipDescription alloc] init];
  rel.name = @"category";
  rel.destinationEntity = OISCategoryEntity();
  if ([rel respondsToSelector:@selector(setIsToMany:)]) {
    rel.isToMany = NO;
  } else if ([rel respondsToSelector:@selector(setMaxCount:)]) {
    [rel setValue:@1 forKey:@"maxCount"];
  }
  rel.userInfo = @{ ODataUserInfoProperty: @"Category" };
  OISApplyProperties(entity, attrs, rel);
  OISCachedProduct = entity;
  return entity;
}

NSManagedObjectModel *OISNorthwindModel(void)
{
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] init];
  NSEntityDescription *product = OISProductEntity();
  NSEntityDescription *category = OISCategoryEntity();
  if ([model respondsToSelector:@selector(setEntities:)]) {
    [model setValue:@[product, category] forKey:@"entities"];
  } else {
    model.entitiesByName = @{ @"Product": product, @"Category": category };
  }
  return model;
}

NSManagedObject *OISMakeObject(NSEntityDescription *entity, NSDictionary *values, BOOL inserted)
{
  NSManagedObject *object = nil;
#if defined(__APPLE__) && !defined(OIS_FORCE_STUB_COREDATA)
  object = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:nil];
  for (NSString *key in values) {
    [object setValue:values[key] forKey:key];
  }
  (void)inserted;
#else
  object = [[NSManagedObject alloc] init];
  object.entity = entity;
  object.inserted = inserted;
  for (NSString *key in values) {
    [object setPrimitiveValue:values[key] forKey:key];
  }
#endif
  return object;
}
