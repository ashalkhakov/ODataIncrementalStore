// ois-model — a Core Data model from an OData service's $metadata.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   ois-model <service root URL | $metadata file> <Model.xcdatamodeld>
//
// Writes the model the service's schema describes into the package,
// creating it if need be. When the schema has changed since the package's
// current version was written, the model becomes a new version ("Model
// 2") and the current one; the old versions stay, as Core Data versioning
// wants. When it has not, nothing is written. The package is then an
// ordinary model: edit it in Xcode, compile it with momc.

#import "ODataIncrementalStore.h"
#include <stdio.h>

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    if (argc != 3) {
      fprintf(stderr, "usage: ois-model <service root URL | $metadata file> <Model.xcdatamodeld>\n");
      return 2;
    }
    NSString *source = @(argv[1]);
    NSString *package = @(argv[2]);
    if (![package.pathExtension isEqualToString:@"xcdatamodeld"]) {
      fprintf(stderr, "ois-model: %s is not an .xcdatamodeld\n", package.UTF8String);
      return 2;
    }

    NSError *error = nil;
    ODataSchema *schema = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:source]) {
      NSData *xml = [NSData dataWithContentsOfFile:source];
      schema = xml ? [ODataSchema schemaWithData:xml error:&error] : nil;
    } else {
      NSURL *url = [NSURL URLWithString:source];
      ODataClient *client = url ? [[ODataClient alloc] initWithConfiguration:[[ODataConfiguration alloc] initWithURL:url options:nil]] : nil;
      NSData *xml = [client metadataWithError:&error];
      schema = xml ? [ODataSchema schemaWithData:xml error:&error] : nil;
    }
    if (!schema) {
      fprintf(stderr, "ois-model: %s\n", (error.localizedDescription ?: @"cannot read the schema").UTF8String);
      return 1;
    }

    NSManagedObjectModel *model = [ODataModelBuilder modelWithSchema:schema];
    BOOL changed = NO;
    NSString *version = [ODataModelBuilder writeModel:model toPackage:package changed:&changed error:&error];
    if (!version) {
      fprintf(stderr, "ois-model: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }
    printf("%s: %s (%s, %lu entities)\n", package.lastPathComponent.UTF8String, version.UTF8String,
           changed ? "written" : "unchanged", (unsigned long)model.entities.count);
    for (NSEntityDescription *entity in [model.entities sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
           return [[a name] compare:[b name]];
         }]) {
      NSString *unmapped = entity.userInfo[ODataUserInfoUnmapped];
      if (unmapped) printf("  %s: not mapped: %s\n", entity.name.UTF8String, unmapped.UTF8String);
    }
    return 0;
  }
}
