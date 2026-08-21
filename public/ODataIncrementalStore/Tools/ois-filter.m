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

static NSAttributeDescription *OISAttr(NSString *name, NSString *wire)
{
  NSAttributeDescription *attr = [[NSAttributeDescription alloc] init];
  attr.name = name;
  if (wire) {
    attr.userInfo = @{ ODataUserInfoProperty: wire };
  }
  return attr;
}

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    NSString *format = argc > 1
      ? [NSString stringWithUTF8String:argv[1]]
      : @"unitPrice > 20 AND discontinued == NO";

    NSEntityDescription *entity = [[NSEntityDescription alloc] init];
    entity.name = @"Product";
    entity.userInfo = @{ ODataUserInfoEntitySet: @"Products" };
    entity.attributesByName = @{
      @"id": OISAttr(@"id", @"ProductID"),
      @"name": OISAttr(@"name", @"ProductName"),
      @"unitPrice": OISAttr(@"unitPrice", @"UnitPrice"),
      @"discontinued": OISAttr(@"discontinued", @"Discontinued"),
      @"unitsInStock": OISAttr(@"unitsInStock", @"UnitsInStock"),
      @"quantityPerUnit": OISAttr(@"quantityPerUnit", @"QuantityPerUnit"),
    };

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
