// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WBSync.h"
#import "WorkbenchSupport.h"

// The device's way to the service: the built-in engine, or nothing at all.
// Each exchange the device has, recorded as it went.
@interface WBSyncLine : NSObject <ODataTransport>
@property (nonatomic, weak) WorkbenchEngine *engine;
@property (atomic) BOOL offline;
@property (nonatomic, copy) void (^didFinish)(WorkbenchLogEntry *entry);
@end

@implementation WBSyncLine
- (WorkbenchLogEntry *)entryOf:(NSURLRequest *)request started:(NSDate *)started
{
  WorkbenchLogEntry *entry = [[WorkbenchLogEntry alloc] init];
  entry.method = request.HTTPMethod.uppercaseString ?: @"GET";
  entry.URL = request.URL.absoluteString ?: @"";
  entry.requestHeaders = request.allHTTPHeaderFields;
  entry.requestData = request.HTTPBody;
  entry.date = started;
  entry.storeHint = @"";
  return entry;
}

// On the main thread, by its run loop (which a nested run loop runs too).
- (void)report:(WorkbenchLogEntry *)entry
{
  if (![NSThread isMainThread]) {
    [self performSelectorOnMainThread:_cmd withObject:entry waitUntilDone:NO];
    return;
  }
  if (self.didFinish) self.didFinish(entry);
}

- (void)startExchange:(ODataExchange *)exchange
{
  if (self.offline || !self.engine) {
    exchange.error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet
                                     userInfo:@{ NSLocalizedDescriptionKey: @"The device is offline." }];
    WorkbenchLogEntry *entry = [self entryOf:exchange.request started:[NSDate date]];
    entry.failure = exchange.error.localizedDescription;
    [self report:entry];
    [exchange finish];
    return;
  }
  ODataExchange *inner = [[ODataExchange alloc] initWithRequest:exchange.request target:self action:@selector(innerDidFinish:)];
  inner.context = @[ exchange, [NSDate date] ];
  [self.engine startExchange:inner];
}

- (void)innerDidFinish:(ODataExchange *)inner
{
  ODataExchange *outer = inner.context[0];
  outer.URLResponse = inner.URLResponse;
  outer.data = inner.data;
  outer.error = inner.error;
  NSHTTPURLResponse *http = [inner.URLResponse isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)inner.URLResponse : nil;
  WorkbenchLogEntry *entry = [self entryOf:inner.request started:inner.context[1]];
  entry.status = http.statusCode;
  entry.responseHeaders = http.allHeaderFields;
  entry.responseData = inner.data ?: [NSData data];
  entry.failure = inner.error.localizedDescription;
  entry.duration = -[entry.date timeIntervalSinceNow];
  [self report:entry];
  [outer finish];
}
@end

@interface WBSyncConflict ()
@property (nonatomic, readwrite) ODataSyncConflict *conflict;
@property (nonatomic, readwrite) ODataSyncResolutionKind outcome;
@property (nonatomic, readwrite) NSDate *date;
@end

@implementation WBSyncConflict
@end

// The rule the window chose, and each conflict it settled, kept.
@interface WBSyncRecorder : NSObject <ODataSyncResolving>
@property (atomic) WBSyncRule rule;
@property (nonatomic, strong) NSMutableArray<WBSyncConflict *> *conflicts;
@end

@implementation WBSyncRecorder
- (instancetype)init
{
  self = [super init];
  _conflicts = [NSMutableArray array];
  return self;
}

- (ODataSyncResolution *)resolveConflict:(ODataSyncConflict *)conflict
{
  id<ODataSyncResolving> rule = nil;
  switch (self.rule) {
    case WBSyncRuleRemoteWins: rule = [[ODataSyncRemoteWins alloc] init]; break;
    case WBSyncRuleDeviceWins: rule = [[ODataSyncLocalWins alloc] init]; break;
    case WBSyncRuleLastWriterWins: rule = [[ODataSyncLastWriterWins alloc] init]; break;
    case WBSyncRuleMergeFields: rule = [[ODataSyncMergeFields alloc] init]; break;
    case WBSyncRuleSetAside: break;
  }
  ODataSyncResolution *resolution = rule ? [rule resolveConflict:conflict] : [ODataSyncResolution defer];
  WBSyncConflict *met = [[WBSyncConflict alloc] init];
  met.conflict = conflict;
  met.outcome = resolution.kind;
  met.date = [NSDate date];
  @synchronized (_conflicts) {
    [_conflicts insertObject:met atIndex:0];
  }
  return resolution;
}

- (NSArray<WBSyncConflict *> *)recorded
{
  @synchronized (_conflicts) {
    return [_conflicts copy];
  }
}
@end

static NSString *WBOperationName(ODataSyncOperation operation)
{
  switch (operation) {
    case ODataSyncOperationInsert: return @"insert";
    case ODataSyncOperationUpdate: return @"update";
    case ODataSyncOperationDelete: return @"delete";
    case ODataSyncOperationRefresh: return @"read again";
  }
  return @"?";
}

static NSString *WBOutcomeName(ODataSyncResolutionKind kind)
{
  switch (kind) {
    case ODataSyncTakeRemote: return @"the service's";
    case ODataSyncKeepLocal: return @"the device's";
    case ODataSyncMerge: return @"merged";
    case ODataSyncDefer: return @"set aside";
  }
  return @"?";
}

static NSString *WBKeyText(NSDictionary *key)
{
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *name in [key.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [parts addObject:key.count == 1 ? [key[name] description] : [NSString stringWithFormat:@"%@=%@", name, key[name]]];
  }
  return [parts componentsJoinedByString:@","];
}

static NSString *WBValuesText(NSDictionary *values, NSSet *changed)
{
  if (!values) return @"  (deleted)\n";
  NSMutableString *text = [NSMutableString string];
  for (NSString *name in [values.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    id value = values[name] == [NSNull null] ? @"-" : values[name];
    [text appendFormat:@"  %@ %@ = %@\n", [changed containsObject:name] ? @"*" : @" ", name, WBCellValue(value)];
  }
  return text;
}

static NSTableColumn *WBSyncColumn(NSString *identifier, NSString *title, CGFloat width)
{
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:identifier];
  [column.headerCell setStringValue:title];
  column.width = width;
  column.editable = NO;
  return column;
}

static NSButton *WBSyncButton(NSString *title, NSRect frame, id target, SEL action)
{
  NSButton *button = [[NSButton alloc] initWithFrame:frame];
  button.title = title;
#if defined(__APPLE__)
  button.bezelStyle = NSBezelStyleRounded;
#else
  button.bezelStyle = NSRoundedBezelStyle;
#endif
  button.target = target;
  button.action = action;
  return button;
}

// The entities the device shows, in the menu's order, and which way each
// goes (the device's model says so in each entity's userInfo).
static NSArray<NSString *> *WBSyncEntities(void)
{
  return @[ @"Product", @"Stock", @"Category", @"Supplier", @"Location" ];
}

static NSDictionary<NSString *, NSString *> *WBSyncDirections(void)
{
  return @{ @"Category": @"down", @"Supplier": @"down", @"Location": @"down", @"Product": @"both", @"Stock": @"both" };
}

static NSString *WBDirectionTitle(NSString *entity)
{
  NSString *direction = WBSyncDirections()[entity];
  if ([direction isEqualToString:@"both"]) return [entity stringByAppendingString:@" (both ways)"];
  if ([direction isEqualToString:@"up"]) return [entity stringByAppendingString:@" (up: the device's)"];
  return [entity stringByAppendingString:@" (down: the service's)"];
}

// What the rules are, for the entity shown.
static NSString *WBDirectionRules(NSString *entity)
{
  NSString *direction = WBSyncDirections()[entity];
  if ([direction isEqualToString:@"both"]) {
    return [NSString stringWithFormat:@"%@: both ways. Edit it here (a cell, New, Delete): the change waits under Waiting to be sent until "
                                      @"Sync or Upload sends it. The service's changes come with Sync or Download. Changed on both sides: "
                                      @"the Conflicts rule settles it.", entity];
  }
  if ([direction isEqualToString:@"up"]) {
    return [NSString stringWithFormat:@"%@: up, the device's. Made and changed here, sent by Sync or Upload; the service never sends it back.",
                                      entity];
  }
  return [NSString stringWithFormat:@"%@: down, the service's. It comes with Sync or Download, and is read only here (the "
                                    @"Workbench has no up entity: Products and Stock go both ways).", entity];
}

@implementation WBSyncWindow {
  WBSyncLine *_line;
  WBSyncRecorder *_recorder;
  NSURL *_storeURL;
  NSArray<NSString *> *_columns;
  NSTimer *_poll;
}

- (instancetype)initWithEngine:(WorkbenchEngine *)engine
{
  self = [super init];
  if (!self) return nil;
  _engine = engine;
  _line = [[WBSyncLine alloc] init];
  _line.engine = engine;
  _recorder = [[WBSyncRecorder alloc] init];
  _objects = @[];
  _changes = @[];
  _conflicts = @[];
  _requests = @[];
  __weak WBSyncWindow *weak = self;
  _line.didFinish = ^(WorkbenchLogEntry *entry) {
    [weak logged:entry];
  };
  if (![self openDevice]) return nil;
  [self makeWindow];
  [self entityChanged:nil];
  return self;
}

- (void)dealloc
{
  [_poll invalidate];
  [self forgetStore];
}

#pragma mark The device

- (void)forgetStore
{
  if (!_storeURL) return;
  for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
    [[NSFileManager defaultManager] removeItemAtPath:[_storeURL.path stringByAppendingString:suffix] error:NULL];
  }
  _storeURL = nil;
}

// The built-in model, which way each entity goes said in its userInfo, and
// the engine's own entities added: a store of its own, an engine over it.
- (BOOL)openDevice
{
  NSManagedObjectModel *model = WorkbenchBuiltInModel(_engine.modelURL);
  if (!model) return NO;
  NSDictionary *directions = WBSyncDirections();
  for (NSString *name in directions) {
    NSEntityDescription *entity = model.entitiesByName[name];
    NSMutableDictionary *info = [entity.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    info[ODataSyncDirectionKey] = directions[name];
    if ([name isEqualToString:@"Product"]) info[ODataSyncModifiedKey] = @"lastChanged";
    entity.userInfo = info;
  }
  // The device keeps a deleted object's key, for the service to be told.
  for (NSEntityDescription *entity in model.entities) {
    for (NSAttributeDescription *attribute in entity.attributesByName.allValues) {
      if (WBIsKey(attribute)) attribute.preservesValueInHistoryOnDeletion = YES;
    }
  }
  [ODataSyncEngine addBookkeepingToModel:model configuration:nil];
  NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  [self forgetStore];
  _storeURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
                                         [NSString stringWithFormat:@"Workbench-device-%@.sqlite", [NSProcessInfo processInfo].globallyUniqueString]]];
  NSError *error = nil;
  if (![coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil URL:_storeURL
                                       options:@{ NSPersistentHistoryTrackingKey: @YES } error:&error]) {
    NSLog(@"Workbench: the device's store does not open: %@", error);
    return NO;
  }
  _deviceStore = coordinator;
  _context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  _context.persistentStoreCoordinator = coordinator;
  _sync = [[ODataSyncEngine alloc] initWithCoordinator:coordinator];
  _sync.resolver = _recorder;
  _sync.delegate = self;
  ODataSyncRemote *remote = [ODataSyncRemote remoteWithServiceRoot:_engine.serviceRoot];
  remote.transport = _line;
  [_sync addRemote:remote];
  return YES;
}

- (ODataSyncRemote *)remote
{
  return _sync.remotes.firstObject;
}

#pragma mark The window

- (NSScrollView *)scrollViewFor:(NSView *)document frame:(NSRect)frame
{
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.borderType = NSBezelBorder;
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.documentView = document;
  return scroll;
}

- (NSTextField *)labelWithFrame:(NSRect)frame text:(NSString *)text
{
  NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
  label.stringValue = text;
  label.editable = NO;
  label.selectable = NO;
  label.bordered = NO;
  label.drawsBackground = NO;
  return label;
}

- (NSTableView *)tableWithColumns:(NSArray<NSTableColumn *> *)columns frame:(NSRect)frame
{
  NSTableView *table = [[NSTableView alloc] initWithFrame:frame];
  for (NSTableColumn *column in columns) [table addTableColumn:column];
  table.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
  table.dataSource = self;
  table.delegate = self;
  table.allowsEmptySelection = YES;
  return table;
}

- (void)makeWindow
{
  NSRect frame = NSMakeRect(160, 100, 1180, 780);
  _window = [[NSWindow alloc] initWithContentRect:frame
                                        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                                                  NSWindowStyleMaskMiniaturizable
                                          backing:NSBackingStoreBuffered defer:YES];
  _window.title = @"Sync: an Offline Device";
  _window.releasedWhenClosed = NO;
  _window.minSize = NSMakeSize(760, 480);
  NSView *content = _window.contentView;
  CGFloat width = frame.size.width, height = frame.size.height;

  // Along the top: what a sync does, the rule, the line.
  CGFloat top = height - 40, x = 12;
  for (NSArray *button in @[ @[ @"Sync", NSStringFromSelector(@selector(sync:)), @70 ],
                             @[ @"Download", NSStringFromSelector(@selector(download:)), @90 ],
                             @[ @"Upload", NSStringFromSelector(@selector(upload:)), @76 ],
                             @[ @"Reconcile", NSStringFromSelector(@selector(reconcile:)), @90 ],
                             @[ @"Change at the Service", NSStringFromSelector(@selector(changeAtTheService:)), @170 ] ]) {
    NSButton *made = WBSyncButton(button[0], NSMakeRect(x, top, [button[2] doubleValue], 28), self, NSSelectorFromString(button[1]));
    made.autoresizingMask = NSViewMinYMargin;
    [content addSubview:made];
    x += [button[2] doubleValue] + 6;
  }
  NSTextField *conflicts = [self labelWithFrame:NSMakeRect(x + 8, top + 4, 70, 20) text:@"Conflicts:"];
  conflicts.autoresizingMask = NSViewMinYMargin;
  [content addSubview:conflicts];
  _rulePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(x + 80, top + 2, 200, 26) pullsDown:NO];
  [_rulePopup addItemsWithTitles:@[ @"The service's wins", @"The device's wins", @"The last writer wins", @"Merge the fields", @"Set aside, to decide" ]];
  _rulePopup.target = self;
  _rulePopup.action = @selector(ruleChanged:);
  _rulePopup.autoresizingMask = NSViewMinYMargin;
  [content addSubview:_rulePopup];
  _offlineButton = [[NSButton alloc] initWithFrame:NSMakeRect(x + 292, top + 4, 80, 22)];
  [_offlineButton setButtonType:NSSwitchButton];
  _offlineButton.title = @"Offline";
  _offlineButton.target = self;
  _offlineButton.action = @selector(offlineChanged:);
  _offlineButton.autoresizingMask = NSViewMinYMargin;
  [content addSubview:_offlineButton];
  _autoSyncButton = [[NSButton alloc] initWithFrame:NSMakeRect(x + 372, top + 4, 140, 22)];
  [_autoSyncButton setButtonType:NSSwitchButton];
  _autoSyncButton.title = @"Sync each change";
  _autoSyncButton.autoresizingMask = NSViewMinYMargin;
  [content addSubview:_autoSyncButton];
  NSButton *reset = WBSyncButton(@"Reset Device", NSMakeRect(width - 122, top, 110, 28), self, @selector(resetDevice:));
  reset.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  [content addSubview:reset];

  // Along the bottom: what happened last.
  _statusField = [self labelWithFrame:NSMakeRect(12, 8, width - 24, 20) text:@"Sync reads the service's data into the device."];
  _statusField.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [content addSubview:_statusField];

  NSSplitView *across = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 34, width, height - 84)];
  across.vertical = YES;
  across.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  // At the left: the device's objects, edited in place.
  NSView *left = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 560, height - 84)];
  left.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  CGFloat leftHeight = left.frame.size.height;
  _entityPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(8, leftHeight - 30, 220, 26) pullsDown:NO];
  for (NSString *entity in WBSyncEntities()) {
    [_entityPopup addItemWithTitle:WBDirectionTitle(entity)];
    _entityPopup.lastItem.representedObject = entity;
  }
  _entityPopup.target = self;
  _entityPopup.action = @selector(entityChanged:);
  _entityPopup.autoresizingMask = NSViewMinYMargin;
  [left addSubview:_entityPopup];
  _makeButton = WBSyncButton(@"New", NSMakeRect(236, leftHeight - 32, 64, 28), self, @selector(newObject:));
  _makeButton.autoresizingMask = NSViewMinYMargin;
  [left addSubview:_makeButton];
  _deleteButton = WBSyncButton(@"Delete", NSMakeRect(304, leftHeight - 32, 72, 28), self, @selector(deleteObject:));
  _deleteButton.autoresizingMask = NSViewMinYMargin;
  [left addSubview:_deleteButton];
  // What the rules are, for the entity shown.
  _rulesField = [self labelWithFrame:NSMakeRect(8, leftHeight - 84, 544, 50) text:@""];
  [_rulesField.cell setWraps:YES];
  _rulesField.font = [NSFont systemFontOfSize:11];
  _rulesField.autoresizingMask = NSViewMinYMargin | NSViewWidthSizable;
  [left addSubview:_rulesField];
  _dataTable = [self tableWithColumns:@[] frame:NSMakeRect(0, 0, 560, leftHeight - 90)];
  NSScrollView *data = [self scrollViewFor:_dataTable frame:NSMakeRect(0, 0, 560, leftHeight - 90)];
  [left addSubview:data];
  [across addSubview:left];

  // At the right: what waits to be sent, the conflicts met, one in detail.
  NSSplitView *down = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 520, height - 84)];
  down.vertical = NO;
  down.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSView *waiting = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 220)];
  waiting.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSTextField *waitingLabel = [self labelWithFrame:NSMakeRect(8, 194, 220, 20) text:@"Waiting to be sent"];
  waitingLabel.autoresizingMask = NSViewMinYMargin;
  [waiting addSubview:waitingLabel];
  NSButton *retry = WBSyncButton(@"Retry", NSMakeRect(300, 190, 70, 28), self, @selector(retryIssue:));
  retry.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
  [waiting addSubview:retry];
  NSButton *discard = WBSyncButton(@"Discard", NSMakeRect(374, 190, 80, 28), self, @selector(discardIssue:));
  discard.autoresizingMask = NSViewMinYMargin | NSViewMinXMargin;
  [waiting addSubview:discard];
  _changesTable = [self tableWithColumns:@[ WBSyncColumn(@"entity", @"Entity", 70), WBSyncColumn(@"key", @"Key", 60),
                                            WBSyncColumn(@"change", @"Change", 150), WBSyncColumn(@"attempts", @"Sent", 40),
                                            WBSyncColumn(@"issue", @"Set aside", 180) ]
                                    frame:NSMakeRect(0, 0, 520, 186)];
  [waiting addSubview:[self scrollViewFor:_changesTable frame:NSMakeRect(0, 0, 520, 186)]];
  [down addSubview:waiting];

  NSView *met = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 200)];
  met.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSTextField *metLabel = [self labelWithFrame:NSMakeRect(8, 176, 300, 20) text:@"Conflicts met"];
  metLabel.autoresizingMask = NSViewMinYMargin;
  [met addSubview:metLabel];
  _conflictTable = [self tableWithColumns:@[ WBSyncColumn(@"time", @"Time", 70), WBSyncColumn(@"entity", @"Entity", 70),
                                             WBSyncColumn(@"key", @"Key", 50), WBSyncColumn(@"here", @"Device changed", 110),
                                             WBSyncColumn(@"there", @"Service changed", 110), WBSyncColumn(@"outcome", @"Outcome", 90) ]
                                     frame:NSMakeRect(0, 0, 520, 172)];
  [met addSubview:[self scrollViewFor:_conflictTable frame:NSMakeRect(0, 0, 520, 172)]];
  [down addSubview:met];

  NSView *asked = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 520, 180)];
  asked.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSTextField *askedLabel = [self labelWithFrame:NSMakeRect(8, 156, 300, 20) text:@"The device's requests"];
  askedLabel.autoresizingMask = NSViewMinYMargin;
  [asked addSubview:askedLabel];
  _requestTable = [self tableWithColumns:@[ WBSyncColumn(@"time", @"Time", 70), WBSyncColumn(@"method", @"Method", 60),
                                            WBSyncColumn(@"url", @"URL", 260), WBSyncColumn(@"status", @"Status", 50),
                                            WBSyncColumn(@"ms", @"ms", 50) ]
                                    frame:NSMakeRect(0, 0, 520, 152)];
  [asked addSubview:[self scrollViewFor:_requestTable frame:NSMakeRect(0, 0, 520, 152)]];
  [down addSubview:asked];

  _detailView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 520, 200)];
  _detailView.editable = NO;
  _detailView.richText = NO;
  _detailView.font = [NSFont userFixedPitchFontOfSize:11];
  // GNUstep leaves a text view made in code black on black.
  _detailView.textColor = [NSColor textColor];
  _detailView.backgroundColor = [NSColor textBackgroundColor];
  _detailView.drawsBackground = YES;
  _detailView.verticallyResizable = YES;
  _detailView.horizontallyResizable = NO;
  _detailView.autoresizingMask = NSViewWidthSizable;
  _detailView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
  _detailView.textContainer.widthTracksTextView = YES;
  _detailView.string = @"Select a conflict for its three versions (the one both last agreed on, the device's, the service's; * changed), "
                       @"or a request for what went and what came back.";
  [down addSubview:[self scrollViewFor:_detailView frame:NSMakeRect(0, 0, 520, 200)]];
  [across addSubview:down];
  [content addSubview:across];
  [across adjustSubviews];
  [down adjustSubviews];
  [across setPosition:560 ofDividerAtIndex:0];
  [down setPosition:180 ofDividerAtIndex:0];
  [down setPosition:340 ofDividerAtIndex:1];
  [down setPosition:540 ofDividerAtIndex:2];
}

- (void)show
{
  [self reload];
  [_window makeKeyAndOrderFront:nil];
}

#pragma mark Reading

- (NSString *)entityName
{
  return _entityPopup.selectedItem.representedObject ?: @"Product";
}

- (BOOL)entityIsEditable
{
  NSEntityDescription *entity = _deviceStore.managedObjectModel.entitiesByName[[self entityName]];
  NSString *direction = entity.userInfo[ODataSyncDirectionKey];
  return [direction isEqualToString:@"both"] || [direction isEqualToString:@"up"];
}

- (IBAction)entityChanged:(id)sender
{
  (void)sender;
  NSEntityDescription *entity = _deviceStore.managedObjectModel.entitiesByName[[self entityName]];
  // As the Workbench shows the Catalog's entities; then the version and the
  // stamp (the service's and the engine's), and what it belongs to.
  NSMutableArray *columns = [NSMutableArray array];
  for (NSString *name in WBColumnNames(entity, YES)) {
    if (entity.attributesByName[name]) [columns addObject:name];
  }
  for (NSString *name in @[ @"version", @"lastChanged", @"versions" ]) {
    if (entity.attributesByName[name] && ![columns containsObject:name]) [columns addObject:name];
  }
  for (NSString *name in [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSRelationshipDescription *relationship = entity.relationshipsByName[name];
    if (!relationship.isToMany) [columns addObject:name];
  }
  _columns = columns;
  _rulesField.stringValue = WBDirectionRules([self entityName]);
  _makeButton.enabled = [self entityIsEditable];
  _deleteButton.enabled = [self entityIsEditable];
  while (_dataTable.tableColumns.count) [_dataTable removeTableColumn:_dataTable.tableColumns.lastObject];
  BOOL editable = [self entityIsEditable];
  for (NSString *name in columns) {
    NSAttributeDescription *attribute = entity.attributesByName[name];
    NSTableColumn *column = WBSyncColumn(name, name, [name isEqualToString:@"lastChanged"] || [name isEqualToString:@"versions"] ? 190 : 90);
    // The key, the version, the stamp and the history are the engine's and
    // the service's.
    column.editable = editable && attribute && !WBIsKey(attribute) && ![@[ @"version", @"lastChanged", @"versions" ] containsObject:name];
    [_dataTable addTableColumn:column];
  }
  [self reloadObjects];
}

- (void)logged:(WorkbenchLogEntry *)entry
{
  NSMutableArray *requests = [_requests mutableCopy];
  [requests insertObject:entry atIndex:0];
  if (requests.count > 200) [requests removeLastObject];
  _requests = requests;
  [_requestTable reloadData];
  // The newest at the top, in view.
  if (_requestTable.selectedRow < 1) [_requestTable scrollRowToVisible:0];
}

- (void)reloadObjects
{
  [_context reset];
  NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:[self entityName]];
  fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"id" ascending:YES] ];
  _objects = [_context executeFetchRequest:fetch error:NULL] ?: @[];
  [_dataTable reloadData];
}

- (void)reload
{
  [self reloadObjects];
  _changes = [_sync pendingChanges];
  _conflicts = [_recorder recorded];
  [_changesTable reloadData];
  [_conflictTable reloadData];
}

- (id)valueOfAttribute:(NSString *)attribute entity:(NSString *)entity key:(id)key
{
  __block id value = nil;
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = _deviceStore;
  [context performBlockAndWait:^{
    NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity];
    fetch.predicate = [NSPredicate predicateWithFormat:@"id == %@", key];
    value = [[[context executeFetchRequest:fetch error:NULL] firstObject] valueForKey:attribute];
  }];
  return value;
}

#pragma mark Running

// The work on a thread of its own, the result said and the tables read
// again on the main thread.
- (void)run:(NSString *)what work:(BOOL (^)(NSError **error))work
{
  if (_busy) {
    _statusField.stringValue = @"Still syncing.";
    return;
  }
  _busy = YES;
  _statusField.stringValue = [what stringByAppendingString:@"…"];
  ODataSyncEngine *sync = _sync;
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSError *error = nil;
    BOOL ok = work(&error);
    ODataSyncResult *result = sync.lastResult;
    dispatch_async(dispatch_get_main_queue(), ^{
      [self finished:what ok:ok result:result error:error];
    });
  });
}

- (void)finished:(NSString *)what ok:(BOOL)ok result:(ODataSyncResult *)result error:(NSError *)error
{
  _busy = NO;
  [self reload];
  if (!ok) {
    _statusField.stringValue = [NSString stringWithFormat:@"%@ failed: %@ The changes wait for the next sync.", what,
                                                          error.localizedDescription ?: @"no answer."];
    return;
  }
  NSMutableArray *parts = [NSMutableArray array];
  if (result) {
    [parts addObject:[NSString stringWithFormat:@"%lu down", (unsigned long)result.downloaded]];
    if (result.removed) [parts addObject:[NSString stringWithFormat:@"%lu removed", (unsigned long)result.removed]];
    [parts addObject:[NSString stringWithFormat:@"%lu up", (unsigned long)result.uploaded]];
    if (result.conflicts) [parts addObject:[NSString stringWithFormat:@"%lu conflict(s)", (unsigned long)result.conflicts]];
    if (result.refused) [parts addObject:[NSString stringWithFormat:@"%lu set aside", (unsigned long)result.refused]];
  }
  _statusField.stringValue = [NSString stringWithFormat:@"%@: %@. %lu change(s) waiting.", what,
                                                        parts.count ? [parts componentsJoinedByString:@", "] : @"done",
                                                        (unsigned long)_changes.count];
}

- (IBAction)sync:(id)sender
{
  (void)sender;
  ODataSyncEngine *sync = _sync;
  [self run:@"Sync" work:^BOOL(NSError **error) {
    return [sync syncWithError:error];
  }];
}

- (IBAction)download:(id)sender
{
  (void)sender;
  ODataSyncEngine *sync = _sync;
  ODataSyncRemote *remote = [self remote];
  [self run:@"Download" work:^BOOL(NSError **error) {
    return [sync downloadFromRemote:remote error:error];
  }];
}

- (IBAction)upload:(id)sender
{
  (void)sender;
  ODataSyncEngine *sync = _sync;
  ODataSyncRemote *remote = [self remote];
  [self run:@"Upload" work:^BOOL(NSError **error) {
    return [sync uploadToRemote:remote error:error];
  }];
}

- (IBAction)reconcile:(id)sender
{
  (void)sender;
  ODataSyncEngine *sync = _sync;
  ODataSyncRemote *remote = [self remote];
  [self run:@"Reconcile" work:^BOOL(NSError **error) {
    return [sync reconcileWithRemote:remote error:error];
  }];
}

- (BOOL)syncAndWait:(NSError **)error
{
  BOOL ok = [_sync syncWithError:error];
  [self reload];
  return ok;
}

- (IBAction)changeAtTheService:(id)sender
{
  (void)sender;
  NSInteger row = _dataTable.selectedRow;
  NSNumber *product = [[self entityName] isEqualToString:@"Product"] && row >= 0 && (NSUInteger)row < _objects.count
      ? [_objects[(NSUInteger)row] valueForKey:@"id"] : nil;
  _statusField.stringValue = [[_engine changeProductAtTheService:product] stringByAppendingString:@" Sync to meet it."];
}

#pragma mark Changing the device

- (id)valueFromCell:(id)value attribute:(NSAttributeDescription *)attribute
{
  if (value == nil || [value isKindOfClass:[NSNull class]]) return nil;
  NSString *text = [value isKindOfClass:[NSString class]] ? value : [value description];
  if (!text.length && attribute.attributeType != NSStringAttributeType) return nil;
  switch (attribute.attributeType) {
    case NSInteger16AttributeType:
    case NSInteger32AttributeType:
    case NSInteger64AttributeType: return @(text.longLongValue);
    case NSDecimalAttributeType: return [NSDecimalNumber decimalNumberWithString:text];
    case NSDoubleAttributeType:
    case NSFloatAttributeType: return @(text.doubleValue);
    case NSBooleanAttributeType: return @([@[ @"1", @"yes", @"true" ] containsObject:text.lowercaseString]);
    case NSDateAttributeType: return WBDate(text);
    default: return text;
  }
}

- (void)saveSaying:(NSString *)what
{
  NSError *error = nil;
  if (![_context save:&error]) {
    _statusField.stringValue = [NSString stringWithFormat:@"Not saved: %@", error.localizedDescription];
    [_context rollback];
    return;
  }
  [self reload];
  if (_autoSyncButton.state == NSOnState) {
    [self sync:nil];
    return;
  }
  _statusField.stringValue = [NSString stringWithFormat:@"%@ on the device; %lu change(s) waiting: Sync (or Upload) sends them.", what,
                                                        (unsigned long)_changes.count];
}

- (void)setValue:(id)value ofAttribute:(NSString *)name row:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= _objects.count) return;
  NSManagedObject *object = _objects[(NSUInteger)row];
  NSAttributeDescription *attribute = object.entity.attributesByName[name];
  if (!attribute) return;
  [object setValue:[self valueFromCell:value attribute:attribute] forKey:name];
  [self saveSaying:[NSString stringWithFormat:@"%@ %@ changed", object.entity.name, [object valueForKey:@"id"]]];
}

- (IBAction)newObject:(id)sender
{
  (void)sender;
  if (![self entityIsEditable]) {
    _statusField.stringValue = [NSString stringWithFormat:@"%@ is the service's: the device only reads it.", [self entityName]];
    return;
  }
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:[self entityName] inManagedObjectContext:_context];
  // A key no one else will take (the Catalog's keys are numbers).
  [object setValue:@(100000 + (NSInteger)([NSUUID UUID].UUIDString.hash % 900000)) forKey:@"id"];
  if (object.entity.attributesByName[@"name"]) [object setValue:@"New on the device" forKey:@"name"];
  if (object.entity.attributesByName[@"quantity"]) [object setValue:@0 forKey:@"quantity"];
  [self saveSaying:[NSString stringWithFormat:@"%@ %@ made (a random key: the Catalog's keys are numbers; an offline app's own would be UUIDs)",
                                             object.entity.name, [object valueForKey:@"id"]]];
}

- (IBAction)deleteObject:(id)sender
{
  (void)sender;
  NSInteger row = _dataTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _objects.count) return;
  NSManagedObject *object = _objects[(NSUInteger)row];
  NSString *what = [NSString stringWithFormat:@"%@ %@ deleted", object.entity.name, [object valueForKey:@"id"]];
  [_context deleteObject:object];
  [self saveSaying:what];
}

- (ODataSyncIssue *)selectedIssue
{
  NSInteger row = _changesTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _changes.count) return nil;
  ODataSyncChange *change = _changes[(NSUInteger)row];
  return [change isKindOfClass:[ODataSyncIssue class]] ? (ODataSyncIssue *)change : nil;
}

- (IBAction)retryIssue:(id)sender
{
  (void)sender;
  ODataSyncIssue *issue = [self selectedIssue];
  if (!issue) {
    _statusField.stringValue = @"Select a change set aside to retry it.";
    return;
  }
  [_sync retryIssue:issue];
  [self reload];
  _statusField.stringValue = @"It goes again at the next sync (a conflict's: the device's version over the service's).";
}

- (IBAction)discardIssue:(id)sender
{
  (void)sender;
  ODataSyncIssue *issue = [self selectedIssue];
  if (!issue) {
    _statusField.stringValue = @"Select a change set aside to discard it.";
    return;
  }
  [_sync discardIssue:issue];
  [self reload];
  _statusField.stringValue = @"Discarded (a conflict's: the service's version is read at the next sync).";
}

- (IBAction)resetDevice:(id)sender
{
  (void)sender;
  if (_busy) return;
  [_recorder.conflicts removeAllObjects];
  WBSyncRule rule = self.rule;
  if (![self openDevice]) {
    _statusField.stringValue = @"The device's store does not open.";
    return;
  }
  self.rule = rule;
  [self entityChanged:nil];
  [self reload];
  _statusField.stringValue = @"A new device: Sync reads the service's data into it.";
}

- (WBSyncRule)rule
{
  return _recorder.rule;
}

- (void)setRule:(WBSyncRule)rule
{
  _recorder.rule = rule;
  [_rulePopup selectItemAtIndex:rule];
}

- (IBAction)ruleChanged:(id)sender
{
  (void)sender;
  _recorder.rule = (WBSyncRule)_rulePopup.indexOfSelectedItem;
}

- (BOOL)isOffline
{
  return _line.offline;
}

- (void)setOffline:(BOOL)offline
{
  _line.offline = offline;
  _offlineButton.state = offline ? NSOnState : NSOffState;
}

- (IBAction)offlineChanged:(id)sender
{
  (void)sender;
  _line.offline = _offlineButton.state == NSOnState;
  _statusField.stringValue = _line.offline ? @"Offline: change things on the device; they wait, and go when it is back."
                                           : @"Back online: Sync sends what waits.";
}

#pragma mark ODataSyncDelegate

- (void)syncEngine:(ODataSyncEngine *)engine didSetAside:(ODataSyncIssue *)issue
{
  (void)engine;
  (void)issue;
}

- (void)syncEngine:(ODataSyncEngine *)engine ignoredLocalChangeToObject:(NSManagedObjectID *)objectID
{
  (void)engine;
  dispatch_async(dispatch_get_main_queue(), ^{
    self.statusField.stringValue = [NSString stringWithFormat:@"A change to %@ is not sent: the service owns it.", objectID.entity.name];
  });
}

#pragma mark Tables

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  if (table == _dataTable) return (NSInteger)_objects.count;
  if (table == _changesTable) return (NSInteger)_changes.count;
  if (table == _conflictTable) return (NSInteger)_conflicts.count;
  if (table == _requestTable) return (NSInteger)_requests.count;
  return 0;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  NSString *identifier = column.identifier;
  if (table == _dataTable) {
    if ((NSUInteger)row >= _objects.count) return nil;
    NSManagedObject *object = _objects[(NSUInteger)row];
    id value = [object valueForKey:identifier];
    if ([value isKindOfClass:[NSManagedObject class]]) return WBTitleOf(value, YES);
    return WBCellValue(value);
  }
  if (table == _changesTable) {
    if ((NSUInteger)row >= _changes.count) return nil;
    ODataSyncChange *change = _changes[(NSUInteger)row];
    if ([identifier isEqualToString:@"entity"]) return change.entityName;
    if ([identifier isEqualToString:@"key"]) return WBKeyText(change.key);
    if ([identifier isEqualToString:@"attempts"]) return @(change.attempts);
    if ([identifier isEqualToString:@"change"]) {
      NSString *name = WBOperationName(change.operation);
      return change.operation == ODataSyncOperationUpdate && change.properties
          ? [NSString stringWithFormat:@"%@ %@", name, [change.properties componentsJoinedByString:@", "]] : name;
    }
    if ([identifier isEqualToString:@"issue"]) {
      if (![change isKindOfClass:[ODataSyncIssue class]]) return @"";
      ODataSyncIssue *issue = (ODataSyncIssue *)change;
      return [NSString stringWithFormat:@"%ld %@", (long)issue.status, issue.message];
    }
    return nil;
  }
  if (table == _requestTable) return [self requestValue:identifier row:row];
  if (table == _conflictTable) {
    if ((NSUInteger)row >= _conflicts.count) return nil;
    WBSyncConflict *met = _conflicts[(NSUInteger)row];
    ODataSyncConflict *conflict = met.conflict;
    if ([identifier isEqualToString:@"time"]) {
      NSDateFormatter *format = [[NSDateFormatter alloc] init];
      format.dateFormat = @"HH:mm:ss";
      return [format stringFromDate:met.date];
    }
    if ([identifier isEqualToString:@"entity"]) return conflict.entity.name;
    if ([identifier isEqualToString:@"key"]) return WBKeyText(conflict.key);
    if ([identifier isEqualToString:@"here"]) {
      return conflict.local ? [[conflict.localChanges.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "] : @"deleted";
    }
    if ([identifier isEqualToString:@"there"]) {
      return conflict.remote ? [[conflict.remoteChanges.allObjects sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@", "] : @"deleted";
    }
    if ([identifier isEqualToString:@"outcome"]) return WBOutcomeName(met.outcome);
  }
  return nil;
}

- (NSString *)pathOf:(WorkbenchLogEntry *)entry
{
  NSString *root = _engine.serviceRoot.absoluteString;
  return [entry.URL hasPrefix:root] ? [entry.URL substringFromIndex:root.length] : entry.URL;
}

- (id)requestValue:(NSString *)identifier row:(NSInteger)row
{
  if ((NSUInteger)row >= _requests.count) return nil;
  WorkbenchLogEntry *entry = _requests[(NSUInteger)row];
  if ([identifier isEqualToString:@"time"]) {
    NSDateFormatter *format = [[NSDateFormatter alloc] init];
    format.dateFormat = @"HH:mm:ss";
    return [format stringFromDate:entry.date];
  }
  if ([identifier isEqualToString:@"method"]) return entry.method;
  if ([identifier isEqualToString:@"url"]) return [self pathOf:entry];
  if ([identifier isEqualToString:@"status"]) return entry.status ? @(entry.status) : @"-";
  if ([identifier isEqualToString:@"ms"]) return entry.duration ? [NSString stringWithFormat:@"%.0f", entry.duration * 1000] : @"";
  return nil;
}

static NSString *WBBodyText(NSData *data)
{
  if (!data.length) return @"";
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
  NSData *pretty = json ? [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:NULL] : nil;
  return [[NSString alloc] initWithData:pretty ?: data encoding:NSUTF8StringEncoding] ?: @"(binary)";
}

- (void)showRequest:(WorkbenchLogEntry *)entry
{
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@\n", entry.method, entry.URL];
  for (NSString *name in [entry.requestHeaders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [text appendFormat:@"%@: %@\n", name, entry.requestHeaders[name]];
  }
  if (entry.requestData.length) [text appendFormat:@"\n%@\n", WBBodyText(entry.requestData)];
  if (entry.failure && !entry.status) {
    [text appendFormat:@"\nNo answer: %@\n", entry.failure];
  } else {
    [text appendFormat:@"\n%ld\n", (long)entry.status];
    for (NSString *name in [entry.responseHeaders.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      [text appendFormat:@"%@: %@\n", name, entry.responseHeaders[name]];
    }
    if (entry.responseData.length) [text appendFormat:@"\n%@\n", WBBodyText(entry.responseData)];
  }
  _detailView.string = text;
}

- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table != _dataTable) return;
  [self setValue:value ofAttribute:column.identifier row:row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
  if (notification.object == _requestTable) {
    NSInteger selected = _requestTable.selectedRow;
    if (selected >= 0 && (NSUInteger)selected < _requests.count) [self showRequest:_requests[(NSUInteger)selected]];
    return;
  }
  if (notification.object != _conflictTable) return;
  NSInteger row = _conflictTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _conflicts.count) return;
  WBSyncConflict *met = _conflicts[(NSUInteger)row];
  ODataSyncConflict *conflict = met.conflict;
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@: %@\n\n", conflict.entity.name, WBKeyText(conflict.key), WBOutcomeName(met.outcome)];
  [text appendString:@"Agreed on last:\n"];
  [text appendString:conflict.base ? WBValuesText(conflict.base, nil) : @"  (not known)\n"];
  [text appendString:@"\nOn the device:\n"];
  [text appendString:WBValuesText(conflict.local, conflict.localChanges)];
  [text appendString:@"\nAt the service:\n"];
  [text appendString:WBValuesText(conflict.remote, conflict.remoteChanges)];
  _detailView.string = text;
}

@end
