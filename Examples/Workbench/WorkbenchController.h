// Native Cocoa workbench for ODataIncrementalStore.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>

@interface WorkbenchController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) IBOutlet NSWindow *window;
@property (nonatomic, strong) IBOutlet NSPopUpButton *presetsPopup;
@property (nonatomic, strong) IBOutlet NSPopUpButton *entityPopup;
@property (nonatomic, strong) IBOutlet NSPopUpButton *resultTypePopup;
@property (nonatomic, strong) IBOutlet NSPopUpButton *sortPopup;
@property (nonatomic, strong) IBOutlet NSPopUpButton *directionPopup;
@property (nonatomic, strong) IBOutlet NSPopUpButton *expandPopup;
@property (nonatomic, strong) IBOutlet NSTextField *limitField;
@property (nonatomic, strong) IBOutlet NSTextView *predicateView;
@property (nonatomic, strong) IBOutlet NSButton *faultsButton;
@property (nonatomic, strong) IBOutlet NSTextField *wireURLField;
@property (nonatomic, strong) IBOutlet NSTextField *statusField;
@property (nonatomic, strong) IBOutlet NSTableView *tableView;
@property (nonatomic, strong) IBOutlet NSTextView *logView;
@property (nonatomic, strong) IBOutlet NSTextView *inspectorView;
@property (nonatomic, strong) IBOutlet NSMenu *mainMenu;

- (void)showWindow;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender;
- (IBAction)applyPreset:(id)sender;
- (IBAction)entityChanged:(id)sender;
- (IBAction)runFetch:(id)sender;
- (IBAction)resetStore:(id)sender;
- (IBAction)bumpPrice:(id)sender;
- (IBAction)insertProduct:(id)sender;
- (IBAction)deleteSelected:(id)sender;
- (IBAction)fulfillFault:(id)sender;
- (IBAction)fireRelationships:(id)sender;
- (void)refreshTranslation;

@end
