// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "WorkbenchController.h"
#import "WorkbenchEngine.h"
#if __has_include(<ODataIncrementalStore/ODataIncrementalStore.h>)
#import <ODataIncrementalStore/ODataIncrementalStore.h>
#else
#import "ODataIncrementalStore.h"
#import "ODataQueryBuilder.h"
#endif

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

static BOOL WorkbenchLoadNib(NSString *name, id owner)
{
#if defined(__APPLE__)
  NSArray *top = nil;
  return [[NSBundle mainBundle] loadNibNamed:name owner:owner topLevelObjects:&top];
#else
  return [NSBundle loadNibNamed:name owner:owner];
#endif
}

@implementation WorkbenchController {
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
  if (!WorkbenchLoadNib(@"WorkbenchWindow", self)) {
    NSLog(@"Workbench: failed to load WorkbenchWindow.xib");
  }
  return self;
}

- (void)awakeFromNib
{
  if (self.mainMenu) [NSApp setMainMenu:self.mainMenu];
  self.tableView.dataSource = self;
  self.tableView.delegate = self;
  self.limitField.delegate = (id)self;
  if (self.entityPopup.numberOfItems == 0) {
    [self.entityPopup addItemsWithTitles:[self entityNames]];
    [self.entityPopup selectItemWithTitle:@"Product"];
  }
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(refreshTranslation)
                                               name:NSTextDidChangeNotification
                                             object:self.predicateView];
  [self rebuildPopups];
  [self rebuildColumns];
  [self refreshTranslation];
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
  return self.entityPopup.titleOfSelectedItem.length ? self.entityPopup.titleOfSelectedItem : @"Product";
}

- (NSFetchRequestResultType)currentResultType
{
  NSString *t = self.resultTypePopup.titleOfSelectedItem;
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

- (void)rebuildPopups
{
  NSString *sortWas = self.sortPopup.titleOfSelectedItem;
  NSString *expWas = self.expandPopup.titleOfSelectedItem;
  [self.sortPopup removeAllItems];
  [self.sortPopup addItemsWithTitles:[self attributeNames]];
  if (sortWas && [self.sortPopup itemWithTitle:sortWas]) [self.sortPopup selectItemWithTitle:sortWas];
  else if ([self.sortPopup itemWithTitle:@"name"]) [self.sortPopup selectItemWithTitle:@"name"];
  else if ([self.sortPopup itemWithTitle:@"companyName"]) [self.sortPopup selectItemWithTitle:@"companyName"];
  [self.expandPopup removeAllItems];
  [self.expandPopup addItemWithTitle:@"(none)"];
  [self.expandPopup addItemsWithTitles:[self relationshipNames]];
  if (expWas && [self.expandPopup itemWithTitle:expWas]) [self.expandPopup selectItemWithTitle:expWas];
}

- (void)rebuildColumns
{
  NSArray *existing = [self.tableView.tableColumns copy];
  for (NSTableColumn *col in existing) [self.tableView removeTableColumn:col];
  if ([self currentResultType] == NSCountResultType) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"count"];
    col.title = @"count";
    col.width = 120;
    [self.tableView addTableColumn:col];
    return;
  }
  for (NSString *ident in [self columnNames]) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = ident;
    col.width = ident.length > 6 ? 160 : 90;
    [self.tableView addTableColumn:col];
  }
}

- (void)showWindow
{
  [self.window makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
  (void)sender;
  return YES;
}

- (NSFetchRequest *)buildRequestError:(NSError **)error
{
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:[self currentEntityName]];
  NSString *format = [[self.predicateView.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
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
  NSString *sortKey = self.sortPopup.titleOfSelectedItem;
  if (sortKey.length) {
    BOOL asc = [self.directionPopup.titleOfSelectedItem isEqualToString:@"ascending"];
    request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:sortKey ascending:asc] ];
  }
  if (self.limitField.stringValue.length) request.fetchLimit = (NSUInteger)[self.limitField.stringValue integerValue];
  NSString *exp = self.expandPopup.titleOfSelectedItem;
  if (exp.length && ![exp isEqualToString:@"(none)"]) {
    request.relationshipKeyPathsForPrefetching = @[ exp ];
  }
  request.resultType = [self currentResultType];
  request.returnsObjectsAsFaults = (self.faultsButton.state == NSOnState);
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
    self.wireURLField.stringValue = error.localizedDescription ?: @"bad predicate";
    return;
  }
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  ODataQueryBuilder *builder = [[ODataQueryBuilder alloc] initWithMapper:mapper serviceRoot:_serviceRoot];
  NSURL *url = [builder URLForFetch:request entity:[self currentEntity] error:&error];
  self.wireURLField.stringValue = url.absoluteString ?: (error.localizedDescription ?: @"");
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
  [self.tableView reloadData];
  [self refreshTranslation];
}

- (IBAction)applyPreset:(id)sender
{
  (void)sender;
  NSArray *presets = WorkbenchPresets();
  NSInteger idx = self.presetsPopup.indexOfSelectedItem;
  if (idx < 0 || idx >= (NSInteger)presets.count) return;
  NSDictionary *p = presets[(NSUInteger)idx];
  [self.entityPopup selectItemWithTitle:p[@"entity"]];
  [self rebuildPopups];
  self.predicateView.string = p[@"predicate"] ?: @"";
  if (p[@"sort"] && [self.sortPopup itemWithTitle:p[@"sort"]]) [self.sortPopup selectItemWithTitle:p[@"sort"]];
  [self.directionPopup selectItemWithTitle:[p[@"asc"] boolValue] ? @"ascending" : @"descending"];
  self.limitField.stringValue = p[@"limit"] ?: @"";
  NSString *exp = p[@"expand"];
  if (exp.length && [self.expandPopup itemWithTitle:exp]) [self.expandPopup selectItemWithTitle:exp];
  else [self.expandPopup selectItemWithTitle:@"(none)"];
  NSString *type = p[@"type"];
  if ([type isEqualToString:@"count"]) [self.resultTypePopup selectItemWithTitle:@"count"];
  else if ([type isEqualToString:@"dictionary"]) [self.resultTypePopup selectItemWithTitle:@"dictionary"];
  else [self.resultTypePopup selectItemWithTitle:@"objects"];
  [self rebuildColumns];
  [self refreshTranslation];
}

- (IBAction)runFetch:(id)sender
{
  (void)sender;
  if (!_context) {
    self.statusField.stringValue = @"No model / store.";
    return;
  }
  NSError *error = nil;
  NSFetchRequest *request = [self buildRequestError:&error];
  if (!request) {
    self.statusField.stringValue = error.localizedDescription;
    return;
  }
  [self refreshTranslation];
  id result = [_context executeFetchRequest:request error:&error];
  if (error) {
    self.statusField.stringValue = error.localizedDescription;
    _rows = @[];
  } else if ([self currentResultType] == NSCountResultType) {
    _rows = [result isKindOfClass:[NSArray class]] ? result : @[ result ?: @0 ];
    self.statusField.stringValue = [NSString stringWithFormat:@"count = %@", _rows.firstObject];
  } else {
    _rows = result ?: @[];
    self.statusField.stringValue = [NSString stringWithFormat:@"%lu %@  (real executeRequest:withContext:error:)",
                           (unsigned long)_rows.count, [self currentEntityName]];
  }
  [self rebuildColumns];
  [self.tableView reloadData];
  [self inspectSelection];
}

- (IBAction)resetStore:(id)sender
{
  (void)sender;
  self.logView.string = @"";
  [self openStore];
  _rows = @[];
  [self.tableView reloadData];
  self.statusField.stringValue = @"Store reset. In-memory service reseeded.";
  [self refreshTranslation];
}

- (void)appendLog:(WorkbenchLogEntry *)entry
{
  NSMutableString *s = [self.logView.string mutableCopy] ?: [NSMutableString string];
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
  self.logView.string = s;
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
  NSInteger row = self.tableView.selectedRow;
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
    self.inspectorView.string = @"Select a row.";
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
  self.inspectorView.string = text;
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
  [self.tableView reloadData];
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
  self.inspectorView.string = text;
}

- (IBAction)bumpPrice:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object || !object.entity.attributesByName[@"unitPrice"]) {
    self.statusField.stringValue = @"Select a Product.";
    return;
  }
  double price = [[object valueForKey:@"unitPrice"] doubleValue];
  [object setValue:@(price + 1) forKey:@"unitPrice"];
  NSError *error = nil;
  if ([_context save:&error]) {
    self.statusField.stringValue = @"PATCH unitPrice+1";
    [self.tableView reloadData];
    [self inspectSelection];
  } else {
    self.statusField.stringValue = error.localizedDescription ?: @"save failed";
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
    self.statusField.stringValue = @"POST Product";
    [self runFetch:nil];
  } else {
    self.statusField.stringValue = error.localizedDescription ?: @"insert failed";
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
    self.statusField.stringValue = @"DELETE";
    [self runFetch:nil];
  } else {
    self.statusField.stringValue = error.localizedDescription ?: @"delete failed";
  }
}

- (void)dealloc
{
  _engine.didHandle = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
