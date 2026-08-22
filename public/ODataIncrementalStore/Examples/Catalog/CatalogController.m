// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "CatalogController.h"
#if __has_include(<ODataIncrementalStore/ODataIncrementalStore.h>)
#import <ODataIncrementalStore/ODataIncrementalStore.h>
#else
#import "ODataIncrementalStore.h"
#endif

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

static BOOL CatalogLoadNib(NSString *name, id owner)
{
#if defined(__APPLE__)
  NSArray *top = nil;
  return [[NSBundle mainBundle] loadNibNamed:name owner:owner topLevelObjects:&top];
#else
  return [NSBundle loadNibNamed:name owner:owner];
#endif
}

@implementation CatalogController {
  NSManagedObjectContext *_context;
  NSArray *_rows;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  [self openStore];
  if (!CatalogLoadNib(@"CatalogWindow", self)) {
    NSLog(@"Catalog: failed to load CatalogWindow.xib");
  }
  return self;
}

- (void)awakeFromNib
{
  if (self.mainMenu) [NSApp setMainMenu:self.mainMenu];
  if (self.entityPopup.numberOfItems == 0) {
    [self.entityPopup addItemsWithTitles:CatalogEntityNames()];
  }
  self.tableView.dataSource = self;
  self.tableView.delegate = self;
  [self rebuildColumns];
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

- (NSString *)currentEntityName
{
  NSString *title = self.entityPopup.titleOfSelectedItem;
  return title.length ? title : @"Product";
}

- (void)rebuildColumns
{
  NSArray *existing = [self.tableView.tableColumns copy];
  for (NSTableColumn *col in existing) {
    [self.tableView removeTableColumn:col];
  }
  for (NSString *ident in CatalogColumnsForEntity([self currentEntityName])) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = ident;
    col.width = ident.length > 6 ? 180 : 90;
    [self.tableView addTableColumn:col];
  }
}

- (IBAction)entityChanged:(id)sender
{
  (void)sender;
  self.searchField.placeholderString = CatalogPlaceholderForEntity([self currentEntityName]);
  self.searchField.stringValue = @"";
  _rows = @[];
  [self rebuildColumns];
  [self.tableView reloadData];
  [self inspectSelection];
}

- (void)showWindow
{
  [self.window makeKeyAndOrderFront:nil];
}

- (IBAction)runFetch:(id)sender
{
  (void)sender;
  if (!_context) {
    self.statusField.stringValue = @"No model / store.";
    return;
  }
  NSString *entity = [self currentEntityName];
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entity];
  NSString *format = self.searchField.stringValue;
  if (format.length) {
    @try {
      request.predicate = [NSPredicate predicateWithFormat:format];
    } @catch (NSException *ex) {
      self.statusField.stringValue = [NSString stringWithFormat:@"Bad predicate: %@", ex.reason];
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
    self.statusField.stringValue = error.localizedDescription;
  } else {
    self.statusField.stringValue = [NSString stringWithFormat:@"%lu %@  ($expand %@)",
                           (unsigned long)_rows.count, entity,
                           [CatalogPrefetchForEntity(entity) componentsJoinedByString:@", "]];
  }
  [self.tableView reloadData];
  [self inspectSelection];
}

- (IBAction)save:(id)sender
{
  (void)sender;
  NSError *error = nil;
  if ([_context save:&error]) {
    self.statusField.stringValue = @"Saved (PATCH/POST/DELETE).";
  } else {
    self.statusField.stringValue = error.localizedDescription ?: @"Save failed";
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
  NSInteger row = self.tableView.selectedRow;
  if (row < 0 || (NSUInteger)row >= _rows.count) {
    self.inspectorView.string = @"Select a row to fault to-one / to-many relationships.";
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
  self.inspectorView.string = text;
}

@end
