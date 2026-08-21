// Loads Examples/Catalog/Catalog.xcdatamodeld. No programmatic model.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "OISCatalogModel.h"

@interface OISCatalogModelLoader : NSObject
@end
@implementation OISCatalogModelLoader
@end

NSURL *OISTestServiceRoot(void)
{
  return [NSURL URLWithString:@"https://odata.test/V4/Northwind.svc/"];
}

NSString *OISSnapshotDirectory(void)
{
  NSString *env = NSProcessInfo.processInfo.environment[@"OIS_SNAPSHOTS"];
  if (env.length) return env;
  NSBundle *bundle = [NSBundle bundleForClass:[OISCatalogModelLoader class]];
  NSString *inBundle = [bundle.resourcePath stringByAppendingPathComponent:@"Snapshots"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:inBundle]) return inBundle;
  NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
  return [here stringByAppendingPathComponent:@"Snapshots"];
}

NSURL *OISCatalogModelURL(void)
{
  NSBundle *bundle = [NSBundle bundleForClass:[OISCatalogModelLoader class]];
  for (NSString *ext in @[ @"momd", @"xcdatamodeld" ]) {
    NSURL *url = [bundle URLForResource:@"Catalog" withExtension:ext];
    if (url) return url;
  }
#ifdef OIS_CATALOG_MODEL_DIR
  NSString *src = [@(OIS_CATALOG_MODEL_DIR) stringByAppendingPathComponent:@"Catalog.xcdatamodeld"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:src]) {
    return [NSURL fileURLWithPath:src];
  }
#endif
  NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
  NSArray *candidates = @[
    [here stringByAppendingPathComponent:@"Catalog.xcdatamodeld"],
    [here stringByAppendingPathComponent:@"../Examples/Catalog/Catalog.xcdatamodeld"],
  ];
  for (NSString *path in candidates) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
      return [NSURL fileURLWithPath:path];
    }
  }
  return nil;
}

NSManagedObjectModel *OISCatalogModel(void)
{
  static NSManagedObjectModel *model;
  if (model) return model;
  NSURL *url = OISCatalogModelURL();
  if (!url) return nil;
  model = [[NSManagedObjectModel alloc] initWithContentsOfURL:url];
  return model;
}

NSEntityDescription *OISCatalogEntity(NSString *name)
{
  return OISCatalogModel().entitiesByName[name];
}
