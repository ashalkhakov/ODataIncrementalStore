// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "CatalogController.h"
#import "CatalogModel.h"
#import "ODataIncrementalStore.h"

@implementation CatalogController {
  NSWindow *_window;
  NSTableView *_table;
  NSTextField *_search;
  NSTextField *_status;
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
  NSManagedObjectModel *model = CatalogModel();
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
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(80, 80, 720, 480)
                                        styleMask:style
                                          backing:NSBackingStoreBuffered
                                            defer:NO];
  _window.title = @"OIS Catalog";
  NSView *content = _window.contentView;

  _search = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 444, 420, 22)];
  _search.placeholderString = @"unitPrice > 20 AND discontinued == NO";
  _search.target = self;
  _search.action = @selector(runFetch:);
  [content addSubview:_search];

  NSButton *go = [[NSButton alloc] initWithFrame:NSMakeRect(448, 440, 80, 28)];
  go.title = @"Fetch";
  go.target = self;
  go.action = @selector(runFetch:);
  [content addSubview:go];

  NSButton *save = [[NSButton alloc] initWithFrame:NSMakeRect(536, 440, 80, 28)];
  save.title = @"Save";
  save.target = self;
  save.action = @selector(save:);
  [content addSubview:save];

  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(16, 40, 688, 390)];
  scroll.hasVerticalScroller = YES;
  _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
  _table.dataSource = self;
  _table.delegate = self;
  NSArray *cols = @[ @"id", @"name", @"unitPrice", @"discontinued" ];
  for (NSString *ident in cols) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = ident;
    col.width = ident.length > 4 ? 200 : 80;
    [_table addTableColumn:col];
  }
  scroll.documentView = _table;
  [content addSubview:scroll];

  _status = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 12, 688, 20)];
  _status.bezeled = NO;
  _status.drawsBackground = NO;
  _status.editable = NO;
  _status.stringValue = @"NSFetchRequest → $filter. No rows until you fetch.";
  [content addSubview:_status];
}

- (void)showWindow
{
  [_window makeKeyAndOrderFront:nil];
}

- (IBAction)runFetch:(id)sender
{
  (void)sender;
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
  NSString *format = _search.stringValue;
  if (format.length) {
    @try {
      request.predicate = [NSPredicate predicateWithFormat:format];
    } @catch (NSException *ex) {
      _status.stringValue = [NSString stringWithFormat:@"Bad predicate: %@", ex.reason];
      return;
    }
  }
  request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
  request.fetchLimit = 50;
  NSError *error = nil;
  _rows = [_context executeFetchRequest:request error:&error] ?: @[];
  if (error) {
    _status.stringValue = error.localizedDescription;
  } else {
    _status.stringValue = [NSString stringWithFormat:@"%lu products", (unsigned long)_rows.count];
  }
  [_table reloadData];
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

@end
