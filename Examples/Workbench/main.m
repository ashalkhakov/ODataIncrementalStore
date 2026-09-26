// Workbench — AppKit session against an in-memory OData v4 service.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <AppKit/AppKit.h>
#import "WorkbenchController.h"

int main(int argc, const char *argv[])
{
  (void)argc;
  (void)argv;
  @autoreleasepool {
    [NSApplication sharedApplication];
    WorkbenchController *app = [[WorkbenchController alloc] init];
    [NSApp setDelegate:(id)app];
    [app showWindow];
    [NSApp run];
  }
  return 0;
}
