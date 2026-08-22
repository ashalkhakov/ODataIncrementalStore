// Native Cocoa workbench for ODataIncrementalStore.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#import <AppKit/AppKit.h>

@interface WorkbenchController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate>

@property (nonatomic, strong) IBOutlet NSWindow *window;
@property (nonatomic, strong) IBOutlet NSPopUpButton *presets;
@property (nonatomic, strong) IBOutlet NSPopUpButton *entity;
@property (nonatomic, strong) IBOutlet NSPopUpButton *resultType;
@property (nonatomic, strong) IBOutlet NSPopUpButton *sort;
@property (nonatomic, strong) IBOutlet NSPopUpButton *dir;
@property (nonatomic, strong) IBOutlet NSPopUpButton *expand;
@property (nonatomic, strong) IBOutlet NSTextField *limit;
@property (nonatomic, strong) IBOutlet NSTextView *predicate;
@property (nonatomic, strong) IBOutlet NSButton *faults;
@property (nonatomic, strong) IBOutlet NSTextField *wireURL;
@property (nonatomic, strong) IBOutlet NSTextField *status;
@property (nonatomic, strong) IBOutlet NSTableView *table;
@property (nonatomic, strong) IBOutlet NSTextView *logView;
@property (nonatomic, strong) IBOutlet NSTextView *inspector;
@property (nonatomic, strong) IBOutlet NSMenu *mainMenu;

- (void)showWindow;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender;

- (IBAction)applyPreset:(id)sender;
- (IBAction)entityChanged:(id)sender;
- (IBAction)runFetch:(id)sender;
- (IBAction)resetStore:(id)sender;
- (IBAction)refreshTranslation;
- (IBAction)bumpPrice:(id)sender;
- (IBAction)insertProduct:(id)sender;
- (IBAction)deleteSelected:(id)sender;
- (IBAction)fulfillFault:(id)sender;
- (IBAction)fireRelationships:(id)sender;

@end
