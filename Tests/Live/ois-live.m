// ois-live — the store against a real OData v4 service.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The snapshot suite checks what the store sends; this checks that a real
// service agrees. It reads Microsoft's public Northwind v4 service through
// the Catalog model, whose Product and Category match Northwind's:
//
//   ois-live [path/to/Catalog.momd] [service root]
//
// Exits 1 if any check fails. The service is not ours, so CI runs this
// without letting it fail a build.

#import "ODataIncrementalStore.h"
#include <stdio.h>

static int failures = 0;

static void check(BOOL ok, NSString *what, NSString *detail)
{
  if (!ok) failures++;
  fprintf(stderr, "%s  %s%s%s\n", ok ? "PASS" : "FAIL", what.UTF8String,
          detail.length ? " — " : "", detail.UTF8String ?: "");
}

static NSString *describe(NSArray *rows, NSError *error)
{
  if (error) return error.localizedDescription;
  return rows ? [NSString stringWithFormat:@"%lu rows", (unsigned long)rows.count] : @"nil";
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSString *modelPath = argc > 1 ? @(argv[1]) : @"Catalog.momd";
    NSString *root = argc > 2 ? @(argv[2]) : @"https://services.odata.org/V4/Northwind/Northwind.svc/";

    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:modelPath]];
    if (!model) {
      fprintf(stderr, "ois-live: cannot load %s\n", modelPath.UTF8String);
      return 2;
    }
    [ODataIncrementalStore registerStore];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSError *error = nil;
    id store = [psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                 configuration:nil
                                           URL:[NSURL URLWithString:root]
                                       options:nil
                                         error:&error];
    check(store != nil, @"open the store ($metadata)", error.localizedDescription);
    if (!store) return 1;

    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    moc.persistentStoreCoordinator = psc;
    [moc performBlockAndWait:^{
      NSError *e = nil;
      NSFetchRequest *all = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      NSUInteger count = [moc countForFetchRequest:all error:&e];
      check(e == nil && count > 0 && count != NSNotFound, @"count products ($count)",
            e ? e.localizedDescription : [NSString stringWithFormat:@"%lu", (unsigned long)count]);

      // Northwind pages at 20, so every product means following next links.
      e = nil;
      NSArray *products = [moc executeFetchRequest:all error:&e];
      check(products.count == count, @"fetch every product across pages",
            [NSString stringWithFormat:@"%@, expected %lu", describe(products, e), (unsigned long)count]);

      e = nil;
      NSFetchRequest *filtered = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      filtered.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 20 AND discontinued == NO"];
      filtered.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
      NSArray *some = [moc executeFetchRequest:filtered error:&e];
      NSUInteger someCount = [moc countForFetchRequest:filtered error:NULL];
      check(some.count > 0 && some.count == someCount, @"filter and sort ($filter, $orderby)",
            [NSString stringWithFormat:@"%@, count says %lu", describe(some, e), (unsigned long)someCount]);

      NSManagedObject *product = some.firstObject;
      NSManagedObject *category = [product valueForKey:@"category"];
      NSString *categoryName = [category valueForKey:@"name"];
      check(categoryName.length > 0, @"fault a to-one relationship", categoryName);

      e = nil;
      NSFetchRequest *byCategory = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      byCategory.predicate = [NSPredicate predicateWithFormat:@"category == %@", category];
      NSArray *inCategory = [moc executeFetchRequest:byCategory error:&e];
      NSUInteger related = [[category valueForKey:@"products"] count];
      check(inCategory.count > 0 && inCategory.count == related, @"compare a relationship with an object",
            [NSString stringWithFormat:@"%@, the category has %lu", describe(inCategory, e), (unsigned long)related]);

      e = nil;
      NSFetchRequest *sorted = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      sorted.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"category.name" ascending:YES] ];
      NSArray *byName = [moc executeFetchRequest:sorted error:&e];
      NSString *firstName = [byName.firstObject valueForKeyPath:@"category.name"];
      NSString *lastName = [byName.lastObject valueForKeyPath:@"category.name"];
      check(byName.count == count && [firstName compare:lastName] != NSOrderedDescending,
            @"sort through a relationship", [NSString stringWithFormat:@"%@, %@ … %@", describe(byName, e), firstName, lastName]);

      e = nil;
      NSFetchRequest *pricey = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
      pricey.predicate = [NSPredicate predicateWithFormat:@"ANY products.unitPrice > 100"];
      NSArray *categories = [moc executeFetchRequest:pricey error:&e];
      check(categories.count > 0, @"ANY over a to-many relationship (any())", describe(categories, e));

      e = nil;
      NSFetchRequest *cheap = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
      cheap.predicate = [NSPredicate predicateWithFormat:@"ALL products.unitPrice < 1000"];
      NSArray *allCheap = [moc executeFetchRequest:cheap error:&e];
      NSUInteger categoryCount = [moc countForFetchRequest:[NSFetchRequest fetchRequestWithEntityName:@"Category"] error:NULL];
      check(allCheap.count > 0 && allCheap.count == categoryCount, @"ALL over a to-many relationship (all())",
            [NSString stringWithFormat:@"%@ of %lu", describe(allCheap, e), (unsigned long)categoryCount]);
    }];

    fprintf(stderr, "%s\n", failures ? "ois-live: FAILED" : "ois-live: all checks passed");
    return failures ? 1 : 0;
  }
}
