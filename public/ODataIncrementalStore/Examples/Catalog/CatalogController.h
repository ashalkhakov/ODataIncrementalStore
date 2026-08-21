// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#import <AppKit/AppKit.h>

@interface CatalogController : NSObject <NSTableViewDataSource, NSTableViewDelegate>
- (void)showWindow;
@end
