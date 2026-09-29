// What the window controller keeps to itself, and its self-test reads.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "WorkbenchController.h"
#import "WBConnection.h"
#import "WBQuery.h"
#import "WBResults.h"

@interface WorkbenchController ()

// The three parts: the connection, the query, and its results.
@property (nonatomic, strong) WBConnection *connection;
@property (nonatomic, strong) WBQuery *query;
@property (nonatomic, strong) WBResults *results;
// The service's canned queries, as the presets menu lists them.
@property (nonatomic, copy) NSArray<NSDictionary *> *presets;

// The query panel's lists and fields.
@property (nonatomic, strong) NSTableView *sortTable;
@property (nonatomic, strong) NSOutlineView *expandOutline;
@property (nonatomic, strong) NSTableView *selectTable;
@property (nonatomic, strong) NSTextField *searchField;
@property (nonatomic, strong) NSTextField *computeField;
@property (nonatomic, strong) NSTextField *groupField;
@property (nonatomic, strong) NSTextField *aggregateField;
@property (nonatomic, strong) NSTextField *timeField;

// What acts on the selected result.
@property (nonatomic, strong) NSButton *deleteButton;
@property (nonatomic, strong) NSButton *faultButton;
@property (nonatomic, strong) NSButton *fireButton;
@property (nonatomic, strong) NSPopUpButton *streamPopup;
@property (nonatomic, strong) NSButton *downloadButton;
@property (nonatomic, strong) NSButton *uploadButton;

// The wire log, newest first, and the window that shows one exchange.
@property (nonatomic, strong) NSMutableArray *log;
@property (nonatomic, strong) NSTableView *logTable;
@property (nonatomic, strong) NSWindow *exchangeWindow;
@property (nonatomic, strong) NSTextView *requestView;
@property (nonatomic, strong) NSTextView *responseView;
@property (nonatomic, strong) NSMenu *storeMenu;

// Explain: the built-in service's plan for the query, physical and logical.
@property (nonatomic, strong) NSButton *explainButton;
@property (nonatomic, strong) NSWindow *planWindow;
@property (nonatomic, strong) NSTextView *explainedView;
@property (nonatomic, strong) NSTextView *physicalPlanView;
@property (nonatomic, strong) NSTextView *logicalPlanView;

// How many rows a screen holds, as a test says; 0: as the table's height says.
@property (nonatomic) NSUInteger screenfulForTests;

// The query, as the panel says it now.
- (WBQuery *)currentQuery;
- (NSManagedObject *)selectedObject;
- (NSString *)itemForPath:(NSString *)path;
- (void)show:(NSString *)text in:(NSTextView *)view;
- (void)setQueryValue:(id)value in:(NSTableView *)table column:(NSTableColumn *)column row:(NSInteger)row;
- (void)outlineView:(NSOutlineView *)outline setObjectValue:(id)value forTableColumn:(NSTableColumn *)column byItem:(id)item;
- (void)predicateChanged:(NSNotification *)notification;
- (void)loadNextPage;
- (void)rebuildOperations;
- (void)rebuildStreams;
- (BOOL)uploadStreamFromFile:(NSURL *)file;
- (IBAction)addSort:(id)sender;
- (IBAction)moveSortUp:(id)sender;
- (IBAction)downloadStream:(id)sender;
- (IBAction)showExchange:(id)sender;
- (IBAction)explainQuery:(id)sender;
- (IBAction)setMergePolicy:(NSMenuItem *)sender;
- (IBAction)toggleRespondAsync:(id)sender;

@end
