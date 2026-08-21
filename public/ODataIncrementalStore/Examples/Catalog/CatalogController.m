// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "CatalogController.h"
#import "ODataIncrementalStore.h"

static NSArray *CatalogEntityNames(void)
{
  return @[ @"Product", @"Supplier", @"Location", @"Stock", @"Category" ];
}

static NSArray *CatalogColumnsForEntity(NSString *name)
{
  if ([name isEqualToString:@"Product"]) return @[ @"id", @"name", @"unitPrice", @"discontinued" ];
  if ([name isEqualToString:@"Supplier"]) return @[ @"id", @"companyName", @"city", @"country" ];
  if ([name isEqualToString:@"Location"]) return @[ @"id", @"name", @"city", @"country" ];
  if ([name isEqualToString:@"Stock"]) return @[ @"id", @"quantity" ];
  if ([name isEqualToString:@"Category"]) return @[ @"id", @"name" ];
  return @[ @"id" ];
}

static NSArray *CatalogPrefetchForEntity(NSString *name)
{
  if ([name isEqualToString:@"Product"]) return @[ @"category", @"suppliers", @"stocks", @"stocks.location" ];
  if ([name isEqualToString:@"Supplier"]) return @[ @"products" ];
  if ([name isEqualToString:@"Location"]) return @[ @"stocks", @"stocks.product" ];
  if ([name isEqualToString:@"Stock"]) return @[ @"product", @"location" ];
  if ([name isEqualToString:@"Category"]) return @[ @"products" ];
  return @[];
}

static NSString *CatalogPlaceholderForEntity(NSString *name)
{
  if ([name isEqualToString:@"Product"]) return @"unitPrice > 20 AND discontinued == NO";
  if ([name isEqualToString:@"Supplier"]) return @"city == \"London\"";
  if ([name isEqualToString:@"Location"]) return @"country == \"USA\"";
  if ([name isEqualToString:@"Stock"]) return @"quantity > 0";
  if ([name isEqualToString:@"Category"]) return @"name CONTAINS[c] \"bev\"";
  return @"";
}

static NSString *CatalogLabel(NSManagedObject *object)
{
  if (!object) return @"(nil)";
  NSString *entity = object.entity.name ?: @"Object";
  id ident = [object valueForKey:@"id"];
  for (NSString *key in @[ @"name", @"companyName" ]) {
    if (object.entity.attributesByName[key]) {
      id title = [object valueForKey:key];
      if (title) return [NSString stringWithFormat:@"%@ #%@ %@", entity, ident ?: @"?", title];
    }
  }
  if (object.entity.attributesByName[@"quantity"]) {
    return [NSString stringWithFormat:@"%@ #%@ qty %@", entity, ident ?: @"?", [object valueForKey:@"quantity"] ?: @"?"];
  }
  return [NSString stringWithFormat:@"%@ #%@", entity, ident ?: @"?"];
}

static NSURL *CatalogModelURL(void)
{
  NSBundle *bundle = [NSBundle mainBundle];
  for (NSString *ext in @[ @"momd", @"xcdatamodeld" ]) {
    NSURL *url = [bundle URLForResource:@"Catalog" withExtension:ext];
    if (url) return url;
  }
#ifdef CATALOG_MODEL_DIR
  NSString *src = [@(CATALOG_MODEL_DIR) stringByAppendingPathComponent:@"Catalog.xcdatamodeld"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:src]) {
    return [NSURL fileURLWithPath:src];
  }
#endif
  NSString *here = [[NSBundle mainBundle] bundlePath];
  NSString *fallback = [here stringByAppendingPathComponent:@"../Catalog.xcdatamodeld"];
  if ([[NSFileManager defaultManager] fileExistsAtPath:fallback]) {
    return [NSURL fileURLWithPath:fallback];
  }
  return nil;
}

@implementation CatalogController {
  NSWindow *_window;
  NSPopUpButton *_entity;
  NSTableView *_table;
  NSTextField *_search;
  NSTextField *_status;
  NSTextView *_inspector;
  NSManagedObjectContext *_context;
  NSArray *_rows;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  [self openStore];
  [self buildWindow];
  return self;
}

- (void)openStore
{
  [ODataIncrementalStore registerStore];
  NSURL *modelURL = CatalogModelURL();
  NSManagedObjectModel *model = modelURL ? [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL] : nil;
  if (!model) {
    NSLog(@"Catalog: could not load Catalog.xcdatamodeld from %@", modelURL);
    return;
  }
  NSPersistentStoreCoordinator *psc =
      [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSString *env = NSProcessInfo.processInfo.environment[@"OIS_SERVICE_URL"];
  NSString *abs = env.length ? env : @"https://services.odata.org/V4/Northwind/Northwind.svc/";
  NSURL *url = [NSURL URLWithString:abs];
  NSError *error = nil;
  [psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                    configuration:nil
                              URL:url
                          options:nil
                            error:&error];
  if (error) {
    NSLog(@"Catalog: %@", error);
  }
  _context = [[NSManagedObjectContext alloc] init];
  _context.persistentStoreCoordinator = psc;
  _rows = @[];
}

- (void)buildWindow
{
  NSUInteger style =
#if defined(__APPLE__)
      NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable;
#else
      NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask;
#endif
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 880, 560)
                                        styleMask:style
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.title = @"OIS Catalog";
  NSView *content = _window.contentView;

  _entity = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(16, 524, 140, 24) pullsDown:NO];
  [_entity addItemsWithTitles:CatalogEntityNames()];
  _entity.target = self;
  _entity.action = @selector(entityChanged:);
  [content addSubview:_entity];

  _search = [[NSTextField alloc] initWithFrame:NSMakeRect(168, 524, 420, 22)];
  _search.placeholderString = CatalogPlaceholderForEntity(@"Product");
  _search.target = self;
  _search.action = @selector(runFetch:);
  [content addSubview:_search];

  NSButton *go = [[NSButton alloc] initWithFrame:NSMakeRect(600, 520, 80, 28)];
  go.title = @"Fetch";
  go.target = self;
  go.action = @selector(runFetch:);
  [content addSubview:go];

  NSButton *save = [[NSButton alloc] initWithFrame:NSMakeRect(688, 520, 80, 28)];
  save.title = @"Save";
  save.target = self;
  save.action = @selector(save:);
  [content addSubview:save];

  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 176, 848, 332)];
  scroll.hasVerticalScroller = YES;
  _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
  _table.dataSource = self;
  _table.delegate = self;
  [self rebuildColumns];
  scroll.documentView = _table;
  [content addSubview:scroll];

  NSScrollView *inspectScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 40, 848, 124)];
  inspectScroll.hasVerticalScroller = YES;
  inspectScroll.borderType = NSBezelBorder;
  _inspector = [[NSTextView alloc] initWithFrame:inspectScroll.bounds];
  _inspector.editable = NO;
  _inspector.font = [NSFont userFixedPitchFontOfSize:11];
  _inspector.string = @"Select a row. To-one and to-many faults fire through the store ($expand / navigation GET).";
  inspectScroll.documentView = _inspector;
  [content addSubview:inspectScroll];

  _status = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 848, 20)];
  _status.bezeled = NO;
  _status.drawsBackground = NO;
  _status.editable = NO;
  _status.stringValue = @"Model is Catalog.xcdatamodeld. Fetch an entity to talk to the store.";
  [content addSubview:_status];
}

- (NSString *)currentEntityName
{
  NSString *title = _entity.titleOfSelectedItem;
  return title.length ? title : @"Product";
}

- (void)rebuildColumns
{
  NSArray *existing = [_table.tableColumns copy];
  for (NSTableColumn *col in existing) {
    [_table removeTableColumn:col];
  }
  for (NSString *ident in CatalogColumnsForEntity([self currentEntityName])) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = ident;
    col.width = ident.length > 6 ? 180 : 90;
    [_table addTableColumn:col];
  }
}

- (IBAction)entityChanged:(id)sender
{
  (void)sender;
  _search.placeholderString = CatalogPlaceholderForEntity([self currentEntityName]);
  _search.stringValue = @"";
  _rows = @[];
  [self rebuildColumns];
  [_table reloadData];
  [self inspectSelection];
}

- (void)showWindow
{
  [_window makeKeyAndOrderFront:nil];
}

- (IBAction)runFetch:(id)sender
{
  (void)sender;
  if (!_context) {
    _status.stringValue = @"No model / store.";
    return;
  }
  NSString *entity = [self currentEntityName];
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entity];
  NSString *format = _search.stringValue;
  if (format.length) {
    @try {
      request.predicate = [NSPredicate predicateWithFormat:format];
    } @catch (NSException *ex) {
      _status.stringValue = [NSString stringWithFormat:@"Bad predicate: %@", ex.reason];
      return;
    }
  }
  NSString *sortKey = [CatalogColumnsForEntity(entity) containsObject:@"name"] ? @"name"
                      : ([CatalogColumnsForEntity(entity) containsObject:@"companyName"] ? @"companyName" : @"id");
  request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:sortKey ascending:YES] ];
  request.fetchLimit = 50;
  request.relationshipKeyPathsForPrefetching = CatalogPrefetchForEntity(entity);
  NSError *error = nil;
  _rows = [_context executeFetchRequest:request error:&error] ?: @[];
  if (error) {
    _status.stringValue = error.localizedDescription;
  } else {
    _status.stringValue = [NSString stringWithFormat:@"%lu %@  ($expand %@)",
                           (unsigned long)_rows.count, entity,
                           [CatalogPrefetchForEntity(entity) componentsJoinedByString:@", "]];
  }
  [_table reloadData];
  [self inspectSelection];
}

- (IBAction)save:(id)sender
{
  (void)sender;
  NSError *error = nil;
  if ([_context save:&error]) {
    _status.stringValue = @"Saved (PATCH/POST/DELETE).";
  } else {
    _status.stringValue = error.localizedDescription ?: @"Save failed";
  }
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  (void)table;
  return (NSInteger)_rows.count;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  (void)table;
  if (row < 0 || (NSUInteger)row >= _rows.count) return nil;
  NSManagedObject *object = _rows[(NSUInteger)row];
  return [object valueForKey:column.identifier];
}

- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  (void)table;
  if (row < 0 || (NSUInteger)row >= _rows.count) return;
  if ([column.identifier isEqualToString:@"id"]) return;
  NSManagedObject *object = _rows[(NSUInteger)row];
  [object setValue:value forKey:column.identifier];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification
{
  (void)notification;
  [self inspectSelection];
}

- (void)inspectSelection
{
  NSInteger row = _table.selectedRow;
  if (row < 0 || (NSUInteger)row >= _rows.count) {
    _inspector.string = @"Select a row to fault to-one / to-many relationships.";
    return;
  }
  NSManagedObject *object = _rows[(NSUInteger)row];
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@\n", CatalogLabel(object)];
  NSDictionary *rels = object.entity.relationshipsByName;
  NSArray *names = [[rels allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in names) {
    NSRelationshipDescription *rel = rels[name];
    BOOL toMany = rel.isToMany;
    @try {
      id value = [object valueForKey:name];
      if (toMany) {
        NSArray *members = [[(NSSet *)value allObjects] sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
          return [CatalogLabel(a) compare:CatalogLabel(b)];
        }];
        [text appendFormat:@"\n%@ (to-many, %lu)\n", name, (unsigned long)members.count];
        for (NSManagedObject *member in members) {
          [text appendFormat:@"  • %@\n", CatalogLabel(member)];
          if (member.entity.relationshipsByName[@"location"]) {
            NSManagedObject *loc = [member valueForKey:@"location"];
            if (loc) [text appendFormat:@"      location (to-one) → %@\n", CatalogLabel(loc)];
          }
          if (member.entity.relationshipsByName[@"product"]) {
            NSManagedObject *prod = [member valueForKey:@"product"];
            if (prod) [text appendFormat:@"      product (to-one) → %@\n", CatalogLabel(prod)];
          }
        }
      } else {
        [text appendFormat:@"\n%@ (to-one) → %@\n", name, CatalogLabel(value)];
      }
    } @catch (NSException *ex) {
      [text appendFormat:@"\n%@: fault failed (%@)\n", name, ex.reason];
    }
  }
  _inspector.string = text;
}

@end
