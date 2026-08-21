// Native Cocoa workbench for ODataIncrementalStore.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#import <AppKit/AppKit.h>

@interface WorkbenchController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
- (void)showWindow;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender;
@end
