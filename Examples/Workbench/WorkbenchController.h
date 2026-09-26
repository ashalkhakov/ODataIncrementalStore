// Native Cocoa workbench for ODataIncrementalStore.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <AppKit/AppKit.h>

@interface WorkbenchController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

@property (nonatomic, strong) IBOutlet NSWindow *window;
@property (nonatomic, strong) IBOutlet NSPopUpButton *servicePopup;
@property (nonatomic, strong) IBOutlet NSTextField *serviceURLField;
@property (nonatomic, strong) IBOutlet NSButton *connectButton;
@property (nonatomic, strong) IBOutlet NSPopUpButton *presetsPopup;
@property (nonatomic, strong) IBOutlet NSPopUpButton *entityPopup;
@property (nonatomic, strong) IBOutlet NSPopUpButton *resultTypePopup;
@property (nonatomic, strong) IBOutlet NSTextField *limitField;
@property (nonatomic, strong) IBOutlet NSTextField *skipField;
@property (nonatomic, strong) IBOutlet NSTextField *batchSizeField;
@property (nonatomic, strong) IBOutlet NSButton *subentitiesButton;
@property (nonatomic, strong) IBOutlet NSTextView *predicateView;
@property (nonatomic, strong) IBOutlet NSButton *faultsButton;
@property (nonatomic, strong) IBOutlet NSTextField *wireURLField;
@property (nonatomic, strong) IBOutlet NSTextField *statusField;
@property (nonatomic, strong) IBOutlet NSTableView *tableView;
// The wire log: a table of exchanges, put in this scroll view.
@property (nonatomic, strong) IBOutlet NSScrollView *logScrollView;
@property (nonatomic, strong) IBOutlet NSTextView *inspectorView;
@property (nonatomic, strong) IBOutlet NSButton *insertButton;
@property (nonatomic, strong) IBOutlet NSButton *saveButton;
@property (nonatomic, strong) IBOutlet NSButton *revertButton;
@property (nonatomic, strong) IBOutlet NSPopUpButton *operationPopup;
@property (nonatomic, strong) IBOutlet NSTextField *operationParametersField;
@property (nonatomic, strong) IBOutlet NSMenu *mainMenu;

- (void)showWindow;
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender;
- (IBAction)serviceChanged:(id)sender;
- (IBAction)connect:(id)sender;
- (IBAction)applyPreset:(id)sender;
- (IBAction)entityChanged:(id)sender;
- (IBAction)runFetch:(id)sender;
- (IBAction)resetStore:(id)sender;
- (IBAction)insertObject:(id)sender;
- (IBAction)deleteSelected:(id)sender;
- (IBAction)saveChanges:(id)sender;
- (IBAction)revertChanges:(id)sender;
- (IBAction)fulfillFault:(id)sender;
- (IBAction)fireRelationships:(id)sender;
- (IBAction)invokeOperation:(id)sender;
- (IBAction)fetchRemoteChanges:(id)sender;
- (void)refreshTranslation;
// Workbench --self-test [builtin]: see WorkbenchController.m. builtin
// tests the built-in service alone, with no network: a package's smoke test.
@property (nonatomic) BOOL selfTestOffline;
- (void)runSelfTest;

@end
