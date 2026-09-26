// ois-live — the store against a real OData v4 service.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The snapshot suite checks what the store sends; this checks that real
// services agree, using two of Microsoft's public reference services:
//
// - Northwind v4, read-only, through the Catalog model, whose Product and
//   Category match Northwind's: paging, filters, sorting, relationships.
// - Northwind v4 again, through Tests/Live/Northwind.xcdatamodeld, for
//   data types: dates in filters and rows, exact decimals, binary.
// - TripPin RW, through Tests/Live/TripPin.xcdatamodeld: creating a person
//   with a client-chosen key, updates carrying ETags, to-one and to-many
//   references, a 412 conflict, and a delete. TripPin gives each
//   client a session of its own, so these writes touch nobody's data.
//
//   ois-live <directory holding Catalog.momd, Northwind.momd and TripPin.momd>
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

static NSPersistentStoreCoordinator *openStore(NSString *modelPath, NSURL *root)
{
  NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:modelPath]];
  if (!model) {
    check(NO, @"load the model", modelPath);
    return nil;
  }
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  id store = [psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                               configuration:nil
                                         URL:root
                                     options:nil
                                       error:&error];
  check(store != nil, [NSString stringWithFormat:@"open %@ ($metadata)", root.host], error.localizedDescription);
  return store ? psc : nil;
}

static NSManagedObjectContext *newContext(NSPersistentStoreCoordinator *psc)
{
  NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  moc.persistentStoreCoordinator = psc;
  return moc;
}

static void northwind(NSString *models)
{
  fprintf(stderr, "== Northwind (read)\n");
  NSURL *root = [NSURL URLWithString:@"https://services.odata.org/V4/Northwind/Northwind.svc/"];
  NSPersistentStoreCoordinator *psc = openStore([models stringByAppendingPathComponent:@"Catalog.momd"], root);
  if (!psc) return;
  NSManagedObjectContext *moc = newContext(psc);
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
}

static void northwindTypes(NSString *models)
{
  fprintf(stderr, "== Northwind (types)\n");
  NSURL *root = [NSURL URLWithString:@"https://services.odata.org/V4/Northwind/Northwind.svc/"];
  NSPersistentStoreCoordinator *psc = openStore([models stringByAppendingPathComponent:@"Northwind.momd"], root);
  if (!psc) return;
  NSManagedObjectContext *moc = newContext(psc);
  [moc performBlockAndWait:^{
    NSError *e = nil;
    // A DateTimeOffset literal in $filter, and dates read back as NSDate.
    NSDate *since = ODataDateFromString(@"1998-05-01T00:00:00Z");
    NSFetchRequest *late = [NSFetchRequest fetchRequestWithEntityName:@"Order"];
    late.predicate = [NSPredicate predicateWithFormat:@"orderDate >= %@", since];
    NSArray *orders = [moc executeFetchRequest:late error:&e];
    BOOL datesOK = orders.count > 0;
    for (NSManagedObject *order in orders) {
      NSDate *date = [order valueForKey:@"orderDate"];
      datesOK = datesOK && [date isKindOfClass:[NSDate class]] && [date compare:since] != NSOrderedAscending;
    }
    check(datesOK, @"filter on a date, read dates back (DateTimeOffset)", describe(orders, e));

    // Freight arrives as "32.3800" with IEEE754Compatible, and stays exact.
    e = nil;
    NSFetchRequest *first = [NSFetchRequest fetchRequestWithEntityName:@"Order"];
    first.predicate = [NSPredicate predicateWithFormat:@"id == 10248"];
    NSManagedObject *order = [[moc executeFetchRequest:first error:&e] firstObject];
    NSDecimalNumber *freight = [order valueForKey:@"freight"];
    check([freight isKindOfClass:[NSDecimalNumber class]] && [freight isEqual:[NSDecimalNumber decimalNumberWithString:@"32.38"]],
          @"decimals keep every digit (IEEE754Compatible)", e.localizedDescription ?: freight.stringValue);

    e = nil;
    NSFetchRequest *filtered = [NSFetchRequest fetchRequestWithEntityName:@"Order"];
    filtered.predicate = [NSPredicate predicateWithFormat:@"freight > %@", [NSDecimalNumber decimalNumberWithString:@"1000.5"]];
    NSArray *heavy = [moc executeFetchRequest:filtered error:&e];
    BOOL heavyOK = heavy.count > 0;
    for (NSManagedObject *o in heavy) heavyOK = heavyOK && [[o valueForKey:@"freight"] compare:@1000.5] == NSOrderedDescending;
    check(heavyOK, @"filter on a decimal", describe(heavy, e));

    // Pictures are base64 (Northwind's is plain base64, not base64url).
    e = nil;
    NSFetchRequest *categories = [NSFetchRequest fetchRequestWithEntityName:@"Category"];
    categories.fetchLimit = 1;
    NSData *picture = [[[moc executeFetchRequest:categories error:&e] firstObject] valueForKey:@"picture"];
    check([picture isKindOfClass:[NSData class]] && picture.length > 1000, @"read binary data (Binary)",
          e.localizedDescription ?: [NSString stringWithFormat:@"%lu bytes", (unsigned long)picture.length]);
  }];
}

// TripPin keeps each client's writes in a session named in the URL,
// /(S(<24 characters>))/TripPinServiceRW/, and creates one on first use.
// Its entry URL hands out a session by a relative redirect, which
// gnustep-base's NSURLConnection does not follow (it resolves Location
// without the request URL and times out), so the session is named here.
static NSURL *tripPinSession(void)
{
  static const char alphabet[] = "abcdefghijklmnopqrstuvwxyz0123456789";
  char session[25] = "ois";
  for (int i = 3; i < 24; i++) session[i] = alphabet[arc4random_uniform(sizeof alphabet - 1)];
  session[24] = 0;
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://services.odata.org/V4/(S(%s))/TripPinServiceRW/", session]];
}

// A write the store knows nothing about, as another client would make it:
// the person's ETag changes behind the store's back.
static BOOL changeBehindTheStoresBack(NSURL *root, NSString *userName)
{
  NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"People('%@')", userName] relativeToURL:root];
  NSMutableURLRequest *get = [NSMutableURLRequest requestWithURL:url];
  [get setValue:@"application/json" forHTTPHeaderField:@"Accept"];
  NSHTTPURLResponse *response = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  [NSURLConnection sendSynchronousRequest:get returningResponse:(NSURLResponse **)&response error:NULL];
  NSString *etag = response.allHeaderFields[@"ETag"] ?: response.allHeaderFields[@"Etag"];
  NSMutableURLRequest *patch = [NSMutableURLRequest requestWithURL:url];
  patch.HTTPMethod = @"PATCH";
  patch.HTTPBody = [@"{\"LastName\":\"Elsewhere\"}" dataUsingEncoding:NSUTF8StringEncoding];
  [patch setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
  [patch setValue:@"4.0" forHTTPHeaderField:@"OData-Version"];
  if (etag) [patch setValue:etag forHTTPHeaderField:@"If-Match"];
  response = nil;
  [NSURLConnection sendSynchronousRequest:patch returningResponse:(NSURLResponse **)&response error:NULL];
#pragma clang diagnostic pop
  return response.statusCode / 100 == 2;
}

static NSManagedObject *personNamed(NSManagedObjectContext *moc, NSString *userName, NSError **error)
{
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Person"];
  fetch.predicate = [NSPredicate predicateWithFormat:@"userName == %@", userName];
  return [[moc executeFetchRequest:fetch error:error] firstObject];
}

static void tripPin(NSString *models)
{
  fprintf(stderr, "== TripPin (write)\n");
  NSURL *root = tripPinSession();
  check(root != nil, @"start a TripPin session", root.absoluteString);
  if (!root) return;
  NSPersistentStoreCoordinator *psc = openStore([models stringByAppendingPathComponent:@"TripPin.momd"], root);
  if (!psc) return;
  NSString *userName = [NSString stringWithFormat:@"ois%u", (unsigned)(arc4random() % 1000000)];

  NSManagedObjectContext *moc = newContext(psc);
  [moc performBlockAndWait:^{
    NSError *e = nil;
    NSManagedObject *person = [NSEntityDescription insertNewObjectForEntityForName:@"Person" inManagedObjectContext:moc];
    [person setValue:userName forKey:@"userName"];
    [person setValue:@"Ois" forKey:@"firstName"];
    [person setValue:@"Live" forKey:@"lastName"];
    BOOL saved = [moc save:&e];
    check(saved && !person.objectID.isTemporaryID, @"insert with a client-chosen key (POST)", e.localizedDescription ?: userName);
    if (!saved) return;

    // Concurrency is an Int64 past 2^53: the store's value has to be the
    // service's, digit for digit.
    NSURL *raw = [NSURL URLWithString:[NSString stringWithFormat:@"People('%@')?$select=Concurrency", userName] relativeToURL:root];
    NSMutableURLRequest *get = [NSMutableURLRequest requestWithURL:raw];
    [get setValue:@"application/json;IEEE754Compatible=true" forHTTPHeaderField:@"Accept"];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSData *body = [NSURLConnection sendSynchronousRequest:get returningResponse:NULL error:NULL];
#pragma clang diagnostic pop
    NSString *digits = body ? [[NSJSONSerialization JSONObjectWithData:body options:0 error:NULL] objectForKey:@"Concurrency"] : nil;
    NSManagedObjectContext *fetched = newContext(psc);
    __block NSNumber *concurrency = nil;
    [fetched performBlockAndWait:^{ concurrency = [personNamed(fetched, userName, NULL) valueForKey:@"concurrency"]; }];
    check(digits.length && [[NSString stringWithFormat:@"%lld", concurrency.longLongValue] isEqualToString:digits],
          @"Int64 keeps every digit (IEEE754Compatible)", [NSString stringWithFormat:@"%@ vs %@", concurrency, digits]);

    // Two updates in a row: the second has to send the ETag the first
    // came back with.
    e = nil;
    [person setValue:@"Ois2" forKey:@"firstName"];
    BOOL first = [moc save:&e];
    [person setValue:@"Ois3" forKey:@"firstName"];
    BOOL second = first && [moc save:&e];
    NSManagedObjectContext *check1 = newContext(psc);
    __block NSString *firstName = nil;
    [check1 performBlockAndWait:^{ firstName = [personNamed(check1, userName, NULL) valueForKey:@"firstName"]; }];
    check(second && [firstName isEqualToString:@"Ois3"], @"update twice, each with the current ETag (PATCH, If-Match)",
          e.localizedDescription ?: firstName);

    e = nil;
    NSFetchRequest *photos = [NSFetchRequest fetchRequestWithEntityName:@"Photo"];
    photos.fetchLimit = 1;
    NSManagedObject *photo = [[moc executeFetchRequest:photos error:&e] firstObject];
    [person setValue:photo forKey:@"photo"];
    BOOL bound = photo && [moc save:&e];
    NSManagedObjectContext *check2 = newContext(psc);
    __block id photoID = nil;
    [check2 performBlockAndWait:^{ photoID = [[personNamed(check2, userName, NULL) valueForKey:@"photo"] valueForKey:@"id"]; }];
    check(bound && [photoID isEqual:[photo valueForKey:@"id"]], @"change a to-one relationship (PUT $ref)",
          e.localizedDescription ?: [NSString stringWithFormat:@"photo %@", photoID]);

    e = nil;
    NSManagedObject *russell = personNamed(moc, @"russellwhyte", &e);
    [[person mutableSetValueForKey:@"friends"] addObject:russell];
    BOOL added = russell && [moc save:&e];
    NSManagedObjectContext *check3 = newContext(psc);
    __block NSUInteger friends = NSNotFound;
    [check3 performBlockAndWait:^{ friends = [[personNamed(check3, userName, NULL) valueForKey:@"friends"] count]; }];
    check(added && friends == 1, @"add to a to-many relationship (POST $ref)",
          e.localizedDescription ?: [NSString stringWithFormat:@"%lu friends", (unsigned long)friends]);

    e = nil;
    [[person mutableSetValueForKey:@"friends"] removeObject:russell];
    BOOL removed = [moc save:&e];
    NSManagedObjectContext *check4 = newContext(psc);
    [check4 performBlockAndWait:^{ friends = [[personNamed(check4, userName, NULL) valueForKey:@"friends"] count]; }];
    check(removed && friends == 0, @"remove from a to-many relationship (DELETE $ref)",
          e.localizedDescription ?: [NSString stringWithFormat:@"%lu friends", (unsigned long)friends]);

    // Someone else changes the person; saving over it has to fail.
    e = nil;
    BOOL elsewhere = changeBehindTheStoresBack(root, userName);
    [person setValue:@"Stale" forKey:@"firstName"];
    BOOL overwrote = [moc save:&e];
    check(elsewhere && !overwrote, @"a stale ETag is refused (412)",
          overwrote ? @"the save went through" : e.localizedDescription);
    [moc rollback];

    e = nil;
    [moc refreshObject:person mergeChanges:NO];
    NSManagedObject *fresh = personNamed(moc, userName, &e);
    if (fresh) [moc deleteObject:fresh];
    BOOL deleted = fresh && [moc save:&e];
    NSManagedObjectContext *check5 = newContext(psc);
    __block NSManagedObject *gone = nil;
    [check5 performBlockAndWait:^{ gone = personNamed(check5, userName, NULL); }];
    check(deleted && !gone, @"delete with the current ETag (DELETE)", e.localizedDescription);
  }];
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSString *models = argc > 1 ? @(argv[1]) : @".";
    [ODataIncrementalStore registerStore];
    northwind(models);
    northwindTypes(models);
    tripPin(models);
    fprintf(stderr, "%s\n", failures ? "ois-live: FAILED" : "ois-live: all checks passed");
    return failures ? 1 : 0;
  }
}
