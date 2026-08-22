// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#import <AppKit/AppKit.h>

@interface CatalogController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) IBOutlet NSWindow *window;
@property (nonatomic, strong) IBOutlet NSPopUpButton *entityPopup;
@property (nonatomic, strong) IBOutlet NSTextField *searchField;
@property (nonatomic, strong) IBOutlet NSTableView *tableView;
@property (nonatomic, strong) IBOutlet NSTextView *inspectorView;
@property (nonatomic, strong) IBOutlet NSTextField *statusField;
@property (nonatomic, strong) IBOutlet NSMenu *mainMenu;

- (void)showWindow;
- (IBAction)entityChanged:(id)sender;
- (IBAction)runFetch:(id)sender;
- (IBAction)save:(id)sender;

@end
