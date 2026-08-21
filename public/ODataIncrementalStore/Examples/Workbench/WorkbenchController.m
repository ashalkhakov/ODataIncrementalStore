// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "WorkbenchController.h"
#import "WorkbenchEngine.h"
#import "ODataIncrementalStore.h"
#import "ODataQueryBuilder.h"

static NSURL *WorkbenchModelURL(void)
{
  NSBundle *bundle = [NSBundle mainBundle];
  for (NSString *ext in @[ @"momd", @"xcdatamodeld" ]) {
    NSURL *url = [bundle URLForResource:@"Catalog" withExtension:ext];
    if (url) return url;
  }
#ifdef WORKBENCH_MODEL_DIR
  NSString *src = [@(WORKBENCH_MODEL_DIR) stringByAppendingPathComponent:@"Catalog.xcdatamodeld"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:src]) return [NSURL fileURLWithPath:src];
  src = [@(WORKBENCH_MODEL_DIR) stringByAppendingPathComponent:@"../Catalog/Catalog.xcdatamodeld"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:src]) return [NSURL fileURLWithPath:src];
#endif
  return nil;
}

static NSArray *WorkbenchPresets(void)
{
  return @[
    @{ @"label": @"All products", @"entity": @"Product", @"predicate": @"", @"sort": @"name", @"asc": @YES, @"expand": @"", @"type": @"objects" },
    @{ @"label": @"Priced over 20", @"entity": @"Product", @"predicate": @"unitPrice > 20 AND discontinued == NO", @"sort": @"unitPrice", @"asc": @NO, @"expand": @"", @"type": @"objects" },
    @{ @"label": @"Beverages + category", @"entity": @"Product", @"predicate": @"category.name == \"Beverages\"", @"sort": @"name", @"asc": @YES, @"expand": @"category", @"type": @"objects" },
    @{ @"label": @"Top 5 dictionary", @"entity": @"Product", @"predicate": @"", @"sort": @"unitPrice", @"asc": @NO, @"limit": @"5", @"expand": @"", @"type": @"dictionary" },
    @{ @"label": @"Count discontinued", @"entity": @"Product", @"predicate": @"discontinued == YES", @"sort": @"id", @"asc": @YES, @"expand": @"", @"type": @"count" },
    @{ @"label": @"Name begins with C", @"entity": @"Product", @"predicate": @"name BEGINSWITH[cd] \"c\"", @"sort": @"name", @"asc": @YES, @"expand": @"", @"type": @"objects" },
    @{ @"label": @"UK suppliers", @"entity": @"Supplier", @"predicate": @"country == \"UK\"", @"sort": @"companyName", @"asc": @YES, @"expand": @"products", @"type": @"objects" },
    @{ @"label": @"Stock on hand", @"entity": @"Stock", @"predicate": @"quantity > 10", @"sort": @"quantity", @"asc": @NO, @"expand": @"location", @"type": @"objects" },
  ];
}

@implementation WorkbenchController {
  NSWindow *_window;
  NSPopUpButton *_presets;
  NSPopUpButton *_entity;
  NSPopUpButton *_resultType;
  NSPopUpButton *_sort;
  NSPopUpButton *_dir;
  NSPopUpButton *_expand;
  NSTextField *_limit;
  NSTextView *_predicate;
  NSButton *_faults;
  NSTextField *_wireURL;
  NSTextField *_status;
  NSTableView *_table;
  NSTextView *_logView;
  NSTextView *_inspector;
  NSManagedObjectContext *_context;
  NSManagedObjectModel *_model;
  WorkbenchEngine *_engine;
  NSURL *_serviceRoot;
  NSArray *_rows;
  NSString *_insertName;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _serviceRoot = [NSURL URLWithString:@"http://workbench.local/odata/"];
  _insertName = @"New Blend";
  _rows = @[];
  [self openStore];
  [self buildWindow];
  [self refreshTranslation];
  return self;
}

- (void)openStore
{
  [ODataIncrementalStore registerStore];
  NSURL *modelURL = WorkbenchModelURL();
  _model = modelURL ? [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL] : nil;
  if (!_model) {
    NSLog(@"Workbench: Catalog.xcdatamodeld not found");
    return;
  }
  _engine = [[WorkbenchEngine alloc] initWithServiceRoot:_serviceRoot];
  __weak WorkbenchController *weak = self;
  _engine.didHandle = ^(WorkbenchLogEntry *entry) {
    [weak appendLog:entry];
  };
  NSPersistentStoreCoordinator *psc =
      [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_model];
  NSError *error = nil;
  [psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                    configuration:nil
                              URL:_serviceRoot
                          options:@{ ODataIncrementalStoreTransportOption: _engine }
                            error:&error];
  if (error) NSLog(@"Workbench: %@", error);
  _context = [[NSManagedObjectContext alloc] init];
  _context.persistentStoreCoordinator = psc;
}

- (NSArray *)entityNames
{
  NSMutableArray *names = [NSMutableArray array];
  for (NSEntityDescription *e in _model.entities) {
    if (e.name) [names addObject:e.name];
  }
  return [names sortedArrayUsingSelector:@selector(compare:)];
}

- (NSEntityDescription *)currentEntity
{
  return _model.entitiesByName[[self currentEntityName]] ?: _model.entities.firstObject;
}

- (NSString *)currentEntityName
{
  return _entity.titleOfSelectedItem.length ? _entity.titleOfSelectedItem : @"Product";
}

- (NSFetchRequestResultType)currentResultType
{
  NSString *t = _resultType.titleOfSelectedItem;
  if ([t isEqualToString:@"count"]) return NSCountResultType;
  if ([t isEqualToString:@"dictionary"]) return NSDictionaryResultType;
  if ([t isEqualToString:@"object IDs"]) return NSManagedObjectIDResultType;
  return NSManagedObjectResultType;
}

- (NSArray *)attributeNames
{
  return [[[self currentEntity].attributesByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray *)relationshipNames
{
  return [[[self currentEntity].relationshipsByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
}

- (NSArray *)columnNames
{
  NSString *name = [self currentEntityName];
  if ([name isEqualToString:@"Product"]) return @[ @"id", @"name", @"unitPrice", @"discontinued" ];
  if ([name isEqualToString:@"Supplier"]) return @[ @"id", @"companyName", @"city", @"country" ];
  if ([name isEqualToString:@"Location"]) return @[ @"id", @"name", @"city", @"country" ];
  if ([name isEqualToString:@"Stock"]) return @[ @"id", @"quantity" ];
  if ([name isEqualToString:@"Category"]) return @[ @"id", @"name" ];
  return [self attributeNames];
}

#pragma mark - Window

- (void)buildWindow
{
  NSUInteger style =
#if defined(__APPLE__)
      NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
#else
      NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask;
#endif
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(40, 40, 1120, 720)
                                        styleMask:style
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.title = @"OIS Workbench";
  NSView *c = _window.contentView;

  CGFloat y = 688;
  [c addSubview:[self label:@"Presets" frame:NSMakeRect(16, y, 60, 18)]];
  _presets = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(80, y - 4, 280, 24) pullsDown:NO];
  for (NSDictionary *p in WorkbenchPresets()) {
    [_presets addItemWithTitle:p[@"label"]];
  }
  _presets.target = self;
  _presets.action = @selector(applyPreset:);
  [c addSubview:_presets];

  NSButton *reset = [[NSButton alloc] initWithFrame:NSMakeRect(1020, y - 4, 80, 24)];
  reset.title = @"Reset";
  reset.target = self;
  reset.action = @selector(resetStore:);
  [c addSubview:reset];

  y = 652;
  [c addSubview:[self label:@"Entity" frame:NSMakeRect(16, y, 80, 16)]];
  _entity = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16, y - 24, 150, 24) pullsDown:NO];
  [_entity addItemsWithTitles:[self entityNames]];
  [_entity selectItemWithTitle:@"Product"];
  _entity.target = self;
  _entity.action = @selector(entityChanged:);
  [c addSubview:_entity];

  [c addSubview:[self label:@"Result" frame:NSMakeRect(176, y, 80, 16)]];
  _resultType = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(176, y - 24, 150, 24) pullsDown:NO];
  [_resultType addItemsWithTitles:@[ @"objects", @"object IDs", @"dictionary", @"count" ]];
  _resultType.target = self;
  _resultType.action = @selector(refreshTranslation);
  [c addSubview:_resultType];

  [c addSubview:[self label:@"Sort" frame:NSMakeRect(336, y, 80, 16)]];
  _sort = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(336, y - 24, 130, 24) pullsDown:NO];
  _sort.target = self;
  _sort.action = @selector(refreshTranslation);
  [c addSubview:_sort];

  _dir = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(472, y - 24, 110, 24) pullsDown:NO];
  [_dir addItemsWithTitles:@[ @"ascending", @"descending" ]];
  _dir.target = self;
  _dir.action = @selector(refreshTranslation);
  [c addSubview:_dir];

  [c addSubview:[self label:@"$top" frame:NSMakeRect(592, y, 40, 16)]];
  _limit = [[NSTextField alloc] initWithFrame:NSMakeRect(592, y - 24, 60, 22)];
  _limit.placeholderString = @"∞";
  _limit.delegate = (id)self;
  [c addSubview:_limit];

  [c addSubview:[self label:@"$expand" frame:NSMakeRect(662, y, 70, 16)]];
  _expand = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(662, y - 24, 140, 24) pullsDown:NO];
  _expand.target = self;
  _expand.action = @selector(refreshTranslation);
  [c addSubview:_expand];

  _faults = [[NSButton alloc] initWithFrame:NSMakeRect(812, y - 24, 140, 24)];
#if defined(__APPLE__)
  [_faults setButtonType:NSButtonTypeSwitch];
#else
  [_faults setButtonType:NSSwitchButton];
#endif
  _faults.title = @"return as faults";
  _faults.state = NSOnState;
  _faults.target = self;
  _faults.action = @selector(refreshTranslation);
  [c addSubview:_faults];

  NSButton *go = [[NSButton alloc] initWithFrame:NSMakeRect(960, y - 28, 140, 32)];
  go.title = @"Execute";
  go.target = self;
  go.action = @selector(runFetch:);
  go.keyEquivalent = @"\r";
  [c addSubview:go];

  [c addSubview:[self label:@"NSPredicate" frame:NSMakeRect(16, 588, 120, 16)]];
  NSScrollView *predScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 548, 1084, 38)];
  predScroll.hasVerticalScroller = YES;
  predScroll.borderType = NSBezelBorder;
  _predicate = [[NSTextView alloc] initWithFrame:predScroll.bounds];
  _predicate.font = [NSFont userFixedPitchFontOfSize:12];
  _predicate.string = @"unitPrice > 20 AND discontinued == NO";
  [_predicate setRichText:NO];
  predScroll.documentView = _predicate;
  [c addSubview:predScroll];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(refreshTranslation)
                                               name:NSTextDidChangeNotification
                                             object:_predicate];

  _wireURL = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 520, 1084, 22)];
  _wireURL.bezeled = NO;
  _wireURL.drawsBackground = NO;
  _wireURL.editable = NO;
  _wireURL.font = [NSFont userFixedPitchFontOfSize:11];
  [c addSubview:_wireURL];

  NSScrollView *tableScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 176, 700, 336)];
  tableScroll.hasVerticalScroller = YES;
  tableScroll.borderType = NSBezelBorder;
  _table = [[NSTableView alloc] initWithFrame:tableScroll.bounds];
  _table.dataSource = self;
  _table.delegate = self;
  tableScroll.documentView = _table;
  [c addSubview:tableScroll];

  NSScrollView *logScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(728, 176, 372, 336)];
  logScroll.hasVerticalScroller = YES;
  logScroll.borderType = NSBezelBorder;
  _logView = [[NSTextView alloc] initWithFrame:logScroll.bounds];
  _logView.editable = NO;
  _logView.font = [NSFont userFixedPitchFontOfSize:10];
  _logView.string = @"Wire log — HTTP the store actually sent. No socket.";
  logScroll.documentView = _logView;
  [c addSubview:logScroll];

  NSScrollView *insScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 40, 700, 124)];
  insScroll.hasVerticalScroller = YES;
  insScroll.borderType = NSBezelBorder;
  _inspector = [[NSTextView alloc] initWithFrame:insScroll.bounds];
  _inspector.editable = NO;
  _inspector.font = [NSFont userFixedPitchFontOfSize:11];
  _inspector.string = @"Select a row to fault to-one / to-many. PATCH / POST / DELETE use the real store.";
  insScroll.documentView = _inspector;
  [c addSubview:insScroll];

  NSButton *bump = [[NSButton alloc] initWithFrame:NSMakeRect(728, 132, 120, 28)];
  bump.title = @"Price +1";
  bump.target = self;
  bump.action = @selector(bumpPrice:);
  [c addSubview:bump];
  NSButton *ins = [[NSButton alloc] initWithFrame:NSMakeRect(856, 132, 120, 28)];
  ins.title = @"Insert product";
  ins.target = self;
  ins.action = @selector(insertProduct:);
  [c addSubview:ins];
  NSButton *del = [[NSButton alloc] initWithFrame:NSMakeRect(984, 132, 116, 28)];
  del.title = @"Delete";
  del.target = self;
  del.action = @selector(deleteSelected:);
  [c addSubview:del];

  NSButton *faultBtn = [[NSButton alloc] initWithFrame:NSMakeRect(728, 96, 180, 28)];
  faultBtn.title = @"Fulfill fault";
  faultBtn.target = self;
  faultBtn.action = @selector(fulfillFault:);
  [c addSubview:faultBtn];
  NSButton *relBtn = [[NSButton alloc] initWithFrame:NSMakeRect(916, 96, 184, 28)];
  relBtn.title = @"Fire relationships";
  relBtn.target = self;
  relBtn.action = @selector(fireRelationships:);
  [c addSubview:relBtn];

  _status = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 1084, 20)];
  _status.bezeled = NO;
  _status.drawsBackground = NO;
  _status.editable = NO;
  _status.stringValue = @"In-memory OData v4 behind ODataTransport. Catalog.xcdatamodeld. Real NSIncrementalStore.";
  [c addSubview:_status];

  [self rebuildPopups];
  [self rebuildColumns];
}

- (NSTextField *)label:(NSString *)title frame:(NSRect)frame
{
  NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
  f.stringValue = title;
  f.bezeled = NO;
  f.drawsBackground = NO;
  f.editable = NO;
  f.font = [NSFont systemFontOfSize:10];
  return f;
}

- (void)rebuildPopups
{
  NSString *sortWas = _sort.titleOfSelectedItem;
  NSString *expWas = _expand.titleOfSelectedItem;
  [_sort removeAllItems];
  [_sort addItemsWithTitles:[self attributeNames]];
  if (sortWas && [_sort itemWithTitle:sortWas]) [_sort selectItemWithTitle:sortWas];
  else if ([_sort itemWithTitle:@"name"]) [_sort selectItemWithTitle:@"name"];
  else if ([_sort itemWithTitle:@"companyName"]) [_sort selectItemWithTitle:@"companyName"];
  [_expand removeAllItems];
  [_expand addItemWithTitle:@"(none)"];
  [_expand addItemsWithTitles:[self relationshipNames]];
  if (expWas && [_expand itemWithTitle:expWas]) [_expand selectItemWithTitle:expWas];
}

- (void)rebuildColumns
{
  NSArray *existing = [_table.tableColumns copy];
  for (NSTableColumn *col in existing) [_table removeTableColumn:col];
  if ([self currentResultType] == NSCountResultType) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"count"];
    col.title = @"count";
    col.width = 120;
    [_table addTableColumn:col];
    return;
  }
  for (NSString *ident in [self columnNames]) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = ident;
    col.width = ident.length > 6 ? 160 : 90;
    [_table addTableColumn:col];
  }
}

- (void)showWindow
{
  [_window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  (void)sender;
  return YES;
}

#pragma mark - Translation / fetch

- (NSFetchRequest *)buildRequestError:(NSError **)error
{
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:[self currentEntityName]];
  NSString *format = [[_predicate.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
  if (format.length) {
    @try {
      request.predicate = [NSPredicate predicateWithFormat:format];
    } @catch (NSException *ex) {
      if (error) {
        *error = [NSError errorWithDomain:@"Workbench" code:1
                                 userInfo:@{ NSLocalizedDescriptionKey: ex.reason ?: @"bad predicate" }];
      }
      return nil;
    }
  }
  NSString *sortKey = _sort.titleOfSelectedItem;
  if (sortKey.length) {
    BOOL asc = [_dir.titleOfSelectedItem isEqualToString:@"ascending"];
    request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:sortKey ascending:asc] ];
  }
  if (_limit.stringValue.length) request.fetchLimit = (NSUInteger)[_limit.stringValue integerValue];
  NSString *exp = _expand.titleOfSelectedItem;
  if (exp.length && ![exp isEqualToString:@"(none)"]) {
    request.relationshipKeyPathsForPrefetching = @[ exp ];
  }
  request.resultType = [self currentResultType];
  request.returnsObjectsAsFaults = (_faults.state == NSOnState);
  if (request.resultType == NSDictionaryResultType) {
    NSMutableArray *props = [NSMutableArray array];
    NSDictionary *attrs = [self currentEntity].attributesByName;
    for (NSString *n in @[ @"name", @"companyName", @"unitPrice", @"quantity", @"id" ]) {
      if (attrs[n]) [props addObject:n];
    }
    if (props.count) request.propertiesToFetch = props;
  }
  return request;
}

- (void)refreshTranslation
{
  if (!_model) return;
  NSError *error = nil;
  NSFetchRequest *request = [self buildRequestError:&error];
  if (!request) {
    _wireURL.stringValue = error.localizedDescription ?: @"bad predicate";
    return;
  }
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  ODataQueryBuilder *builder = [[ODataQueryBuilder alloc] initWithMapper:mapper serviceRoot:_serviceRoot];
  NSURL *url = [builder URLForFetch:request entity:[self currentEntity] error:&error];
  _wireURL.stringValue = url.absoluteString ?: (error.localizedDescription ?: @"");
}

- (void)controlTextDidChange:(NSNotification *)n
{
  (void)n;
  [self refreshTranslation];
}

- (IBAction)entityChanged:(id)sender
{
  (void)sender;
  [self rebuildPopups];
  [self rebuildColumns];
  _rows = @[];
  [_table reloadData];
  [self refreshTranslation];
}

- (IBAction)applyPreset:(id)sender
{
  (void)sender;
  NSArray *presets = WorkbenchPresets();
  NSInteger idx = _presets.indexOfSelectedItem;
  if (idx < 0 || idx >= (NSInteger)presets.count) return;
  NSDictionary *p = presets[(NSUInteger)idx];
  [_entity selectItemWithTitle:p[@"entity"]];
  [self rebuildPopups];
  _predicate.string = p[@"predicate"] ?: @"";
  if (p[@"sort"] && [_sort itemWithTitle:p[@"sort"]]) [_sort selectItemWithTitle:p[@"sort"]];
  [_dir selectItemWithTitle:[p[@"asc"] boolValue] ? @"ascending" : @"descending"];
  _limit.stringValue = p[@"limit"] ?: @"";
  NSString *exp = p[@"expand"];
  if (exp.length && [_expand itemWithTitle:exp]) [_expand selectItemWithTitle:exp];
  else [_expand selectItemWithTitle:@"(none)"];
  NSString *type = p[@"type"];
  if ([type isEqualToString:@"count"]) [_resultType selectItemWithTitle:@"count"];
  else if ([type isEqualToString:@"dictionary"]) [_resultType selectItemWithTitle:@"dictionary"];
  else [_resultType selectItemWithTitle:@"objects"];
  [self rebuildColumns];
  [self refreshTranslation];
}

- (IBAction)runFetch:(id)sender
{
  (void)sender;
  if (!_context) {
    _status.stringValue = @"No model / store.";
    return;
  }
  NSError *error = nil;
  NSFetchRequest *request = [self buildRequestError:&error];
  if (!request) {
    _status.stringValue = error.localizedDescription;
    return;
  }
  [self refreshTranslation];
  id result = [_context executeFetchRequest:request error:&error];
  if (error) {
    _status.stringValue = error.localizedDescription;
    _rows = @[];
  } else if ([self currentResultType] == NSCountResultType) {
    _rows = [result isKindOfClass:[NSArray class]] ? result : @[ result ?: @0 ];
    _status.stringValue = [NSString stringWithFormat:@"count = %@", _rows.firstObject];
  } else {
    _rows = result ?: @[];
    _status.stringValue = [NSString stringWithFormat:@"%lu %@  (real executeRequest:withContext:error:)",
                           (unsigned long)_rows.count, [self currentEntityName]];
  }
  [self rebuildColumns];
  [_table reloadData];
  [self inspectSelection];
}

- (IBAction)resetStore:(id)sender
{
  (void)sender;
  _logView.string = @"";
  [self openStore];
  _rows = @[];
  [_table reloadData];
  _status.stringValue = @"Store reset. In-memory service reseeded.";
  [self refreshTranslation];
}

- (void)appendLog:(WorkbenchLogEntry *)entry
{
  NSMutableString *s = [_logView.string mutableCopy] ?: [NSMutableString string];
  NSMutableString *block = [NSMutableString stringWithFormat:@"%@ %ld  %@\n  %@\n",
                            entry.method, (long)entry.status, entry.storeHint, entry.URL];
  if (entry.requestBody.length) {
    NSString *req = entry.requestBody;
    if (req.length > 240) req = [[req substringToIndex:240] stringByAppendingString:@"…"];
    [block appendFormat:@"  → %@\n", req];
  }
  NSString *resp = entry.responseBody ?: @"";
  if (resp.length > 400) resp = [[resp substringToIndex:400] stringByAppendingString:@"…"];
  [block appendFormat:@"%@\n\n", resp];
  [s insertString:block atIndex:0];
  if (s.length > 20000) [s deleteCharactersInRange:NSMakeRange(20000, s.length - 20000)];
  _logView.string = s;
}

#pragma mark - Table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  (void)table;
  return (NSInteger)_rows.count;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  (void)table;
  if (row < 0 || (NSUInteger)row >= _rows.count) return nil;
  id obj = _rows[(NSUInteger)row];
  if ([obj isKindOfClass:[NSNumber class]]) return obj;
  if ([obj isKindOfClass:[NSDictionary class]]) return obj[column.identifier] ?: obj[@"name"];
  if ([obj isKindOfClass:[NSManagedObjectID class]]) return [obj URIRepresentation];
  if ([obj isKindOfClass:[NSManagedObject class]]) {
    @try {
      return [obj valueForKey:column.identifier];
    } @catch (NSException *ex) {
      return ex.reason;
    }
  }
  return [obj description];
}

- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  (void)table;
  if (row < 0 || (NSUInteger)row >= _rows.count) return;
  id obj = _rows[(NSUInteger)row];
  if (![obj isKindOfClass:[NSManagedObject class]]) return;
  if ([column.identifier isEqualToString:@"id"]) return;
  [obj setValue:value forKey:column.identifier];
}

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
  (void)n;
  [self inspectSelection];
}

- (NSManagedObject *)selectedObject
{
  NSInteger row = _table.selectedRow;
  if (row < 0 || (NSUInteger)row >= _rows.count) return nil;
  id obj = _rows[(NSUInteger)row];
  if ([obj isKindOfClass:[NSManagedObject class]]) return obj;
  if ([obj isKindOfClass:[NSManagedObjectID class]]) return [_context objectWithID:obj];
  return nil;
}

- (void)inspectSelection
{
  NSManagedObject *object = [self selectedObject];
  if (!object) {
    _inspector.string = @"Select a row.";
    return;
  }
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@\n", object.entity.name, object.objectID];
  NSArray *attrs = [[object.entity.attributesByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in attrs) {
    @try {
      [text appendFormat:@"  %@ = %@\n", name, [object valueForKey:name] ?: @"nil"];
    } @catch (NSException *ex) {
      [text appendFormat:@"  %@ fault failed (%@)\n", name, ex.reason];
    }
  }
  _inspector.string = text;
}

- (IBAction)fulfillFault:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object) return;
  for (NSString *name in object.entity.attributesByName) {
    (void)[object valueForKey:name];
  }
  [self inspectSelection];
  [_table reloadData];
}

- (IBAction)fireRelationships:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object) return;
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ relationships\n", object.entity.name];
  NSArray *names = [[object.entity.relationshipsByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSRelationshipDescription *rel = object.entity.relationshipsByName[name];
    @try {
      id value = [object valueForKey:name];
      if (rel.isToMany) {
        [text appendFormat:@"\n%@ (to-many, %lu)\n", name, (unsigned long)[value count]];
        for (NSManagedObject *m in value) {
          id title = nil;
          if (m.entity.attributesByName[@"name"]) title = [m valueForKey:@"name"];
          else if (m.entity.attributesByName[@"companyName"]) title = [m valueForKey:@"companyName"];
          [text appendFormat:@"  • %@ %@\n", m.entity.name, title ?: [m valueForKey:@"id"]];
        }
      } else {
        NSManagedObject *one = value;
        [text appendFormat:@"\n%@ (to-one) → %@\n", name, one ? one.entity.name : @"nil"];
        if (one && one.entity.attributesByName[@"name"]) {
          [text appendFormat:@"  %@\n", [one valueForKey:@"name"]];
        }
      }
    } @catch (NSException *ex) {
      [text appendFormat:@"\n%@: %@\n", name, ex.reason];
    }
  }
  _inspector.string = text;
}

- (IBAction)bumpPrice:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object || !object.entity.attributesByName[@"unitPrice"]) {
    _status.stringValue = @"Select a Product.";
    return;
  }
  double price = [[object valueForKey:@"unitPrice"] doubleValue];
  [object setValue:@(price + 1) forKey:@"unitPrice"];
  NSError *error = nil;
  if ([_context save:&error]) {
    _status.stringValue = @"PATCH unitPrice+1";
    [_table reloadData];
    [self inspectSelection];
  } else {
    _status.stringValue = error.localizedDescription ?: @"save failed";
  }
}

- (IBAction)insertProduct:(id)sender
{
  (void)sender;
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:@"Product" inManagedObjectContext:_context];
  [object setValue:_insertName forKey:@"name"];
  [object setValue:@"12 - 100 g bags" forKey:@"quantityPerUnit"];
  [object setValue:@12.5 forKey:@"unitPrice"];
  [object setValue:@NO forKey:@"discontinued"];
  NSError *error = nil;
  if ([_context save:&error]) {
    _status.stringValue = @"POST Product";
    [self runFetch:nil];
  } else {
    _status.stringValue = error.localizedDescription ?: @"insert failed";
  }
}

- (IBAction)deleteSelected:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object) return;
  [_context deleteObject:object];
  NSError *error = nil;
  if ([_context save:&error]) {
    _status.stringValue = @"DELETE";
    [self runFetch:nil];
  } else {
    _status.stringValue = error.localizedDescription ?: @"delete failed";
  }
}

- (void)dealloc
{
  _engine.didHandle = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
