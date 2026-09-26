// Catalog — AppKit demo of ODataIncrementalStore.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <AppKit/AppKit.h>
#import "CatalogController.h"

int main(int argc, const char *argv[])
{
  (void)argc; (void)argv;
  @autoreleasepool {
#if defined(__APPLE__)
    [NSApplication sharedApplication];
#endif
    [NSApplication sharedApplication];
    CatalogController *catalog = [[CatalogController alloc] init];
    [catalog showWindow];
    [NSApp run];
  }
  return 0;
}
