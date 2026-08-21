// ois-filter — NSPredicate → OData $filter, on GNUstep.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Default build links FreeCoreData (https://github.com/ashalkhakov/FreeCoreData).
// Without it: make OIS_COREDATA=stub
//
//   ./ois-filter 'unitPrice > 20 AND discontinued == NO'
//   UnitPrice gt 20 and Discontinued eq false

#import "ODataIncrementalStore.h"
#import <stdio.h>

static NSManagedObjectModel *OISLoadCatalogModel(void)
{
  NSString *here = [@(__FILE__) stringByDeletingLastPathComponent];
  NSArray *candidates = @[
    [here stringByAppendingPathComponent:@"../Examples/Catalog/Catalog.xcdatamodeld"],
    [here stringByAppendingPathComponent:@"Catalog.xcdatamodeld"],
  ];
  for (NSString *path in candidates) {
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
      return [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]];
    }
  }
  return nil;
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSString *format = argc > 1
      ? [NSString stringWithUTF8String:argv[1]]
      : @"unitPrice > 20 AND discontinued == NO";

    NSManagedObjectModel *model = OISLoadCatalogModel();
    NSEntityDescription *entity = model.entitiesByName[@"Product"];
    if (!entity) {
      fprintf(stderr, "ois-filter: could not load Catalog.xcdatamodeld\n");
      return 1;
    }

    ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
    ODataPredicateTranslator *translator =
        [[ODataPredicateTranslator alloc] initWithMapper:mapper entity:entity];

    NSError *error = nil;
    NSPredicate *predicate = [NSPredicate predicateWithFormat:format];
    NSString *filter = [translator translatePredicate:predicate error:&error];
    if (!filter) {
      fprintf(stderr, "ois-filter: %s\n",
              error.localizedDescription.UTF8String ?: "unsupported predicate");
      return 1;
    }
    puts(filter.UTF8String);
  }
  return 0;
}
