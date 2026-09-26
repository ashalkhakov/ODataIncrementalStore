// Workbench — try out an OData v4 service interactively: the built-in
// in-memory one, Northwind, TripPin, or any other.
//
//   Workbench --self-test   drives the window against each, and exits
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <AppKit/AppKit.h>
#import "WorkbenchController.h"
#include <string.h>

int main(int argc, const char *argv[])
{
  @autoreleasepool {
    BOOL selfTest = NO;
    for (int i = 1; i < argc; i++) {
      if (!strcmp(argv[i], "--self-test")) selfTest = YES;
    }
    [NSApplication sharedApplication];
    WorkbenchController *app = [[WorkbenchController alloc] init];
    [NSApp setDelegate:(id)app];
    [app showWindow];
    if (selfTest) [app performSelector:@selector(runSelfTest) withObject:nil afterDelay:0.5];
    [NSApp run];
  }
  return 0;
}
