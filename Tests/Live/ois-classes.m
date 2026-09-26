// ois-classes — classes generated from TripPin's $metadata, used as a
// client built on it would use them.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   ois-model --classes TripPinClasses <TripPin> TripPin.xcdatamodeld
//   momc TripPin.xcdatamodeld TripPinGenerated.momd
//   (compile this with TripPinClasses/*.m)
//   ois-classes TripPinGenerated.momd
//
// Built with the classes ois-model wrote, it opens a TripPin session with
// the compiled model and calls the service's operations as the methods
// the classes have. Checks print PASS or FAIL; the exit status is the
// number of failures.

#import <ODataIncrementalStore/ODataIncrementalStore.h>
#import "Airline.h"
#import "Airport.h"
#import "Person.h"
#import "TripPinService.h"
#include <stdio.h>

static int failures = 0;

static void check(BOOL ok, NSString *what, NSString *detail)
{
  if (!ok) failures++;
  fprintf(stderr, "%s  %s%s%s\n", ok ? "PASS" : "FAIL", what.UTF8String, detail.length ? " — " : "", detail.UTF8String ?: "");
}

static NSString *reason(NSError *error)
{
  return error.localizedDescription ?: @"no error";
}

// A session of its own, as ois-live makes one: TripPin keys writable
// state by the (S(...)) segment.
static NSURL *session(void)
{
  NSMutableString *key = [NSMutableString stringWithString:@"oiscls"];
  const char *alphabet = "abcdefghijklmnopqrstuvwxyz012345";
  while (key.length < 24) [key appendFormat:@"%c", alphabet[arc4random_uniform(32)]];
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://services.odata.org/V4/(S(%@))/TripPinServiceRW/", key]];
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    fprintf(stderr, "== Generated classes\n");
    NSString *path = argc > 1 ? @(argv[1]) : @"TripPinGenerated.momd";
    NSManagedObjectModel *model = [[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]];
    if (!model) {
      check(NO, @"load the generated model", path);
      return 1;
    }
    [ODataIncrementalStore registerStore];
    NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    NSError *error = nil;
    if (![psc addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil URL:session() options:nil error:&error]) {
      check(NO, @"open TripPin with the generated model", reason(error));
      return 1;
    }
    NSManagedObjectContext *moc = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    moc.persistentStoreCoordinator = psc;

    __block NSString *personClass = nil, *userName = nil, *airline = nil, *airport = nil;
    __block BOOL shared = NO;
    __block NSError *e1 = nil, *e2 = nil, *e3 = nil;
    [moc performBlockAndWait:^{
      NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Person"];
      fetch.predicate = [NSPredicate predicateWithFormat:@"userName == %@", @"russellwhyte"];
      Person *russell = [[moc executeFetchRequest:fetch error:NULL] firstObject];
      personClass = NSStringFromClass([russell class]);
      userName = russell.userName;

      NSError *e = nil;
      Airline *favorite = [russell getFavoriteAirline:&e];
      airline = favorite.name;
      e1 = e;

      e = nil;
      Airport *nearest = [TripPinService getNearestAirportInContext:moc lat:@33.94 lon:@-118.4 error:&e];
      airport = nearest.icaoCode;
      e2 = e;

      e = nil;
      shared = [russell shareTripWithUserName:@"scottketchum" tripId:@0 error:&e];
      e3 = e;
    }];
    check([personClass hasPrefix:@"Person"] && [userName isEqualToString:@"russellwhyte"], @"objects are of the generated classes",
          [NSString stringWithFormat:@"%@, %@", personClass, userName]);
    check([airline isEqualToString:@"American Airlines"], @"an instance method: -[Person getFavoriteAirline:]", airline ?: reason(e1));
    check([airport isEqualToString:@"KLAX"], @"a service method: +[TripPinService getNearestAirportInContext:lat:lon:error:]",
          airport ?: reason(e2));
    check(shared, @"an action returning nothing: -[Person shareTripWithUserName:tripId:error:]", shared ? @"YES" : reason(e3));
    fprintf(stderr, "%s\n", failures ? "ois-classes: FAILED" : "ois-classes: all checks passed");
    return failures;
  }
}
