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

// The services the popup offers, in its order.
typedef NS_ENUM(NSInteger, WBService) {
  WBServiceBuiltIn = 0,
  WBServiceNorthwind,
  WBServiceTripPin,
  WBServiceOther
};

static NSString * const WBBuiltInRoot = @"http://workbench.local/odata/";
static NSString * const WBNorthwindRoot = @"https://services.odata.org/V4/Northwind/Northwind.svc/";
static NSString * const WBTripPinRoot = @"https://services.odata.org/V4/TripPinServiceRW/";

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

// TripPin keeps what a client writes in a session of its own, named in
// the URL; a new one starts from TripPin's sample data.
static NSURL *WBTripPinSession(void)
{
  NSMutableString *key = [NSMutableString stringWithString:@"oiswb"];
  const char *alphabet = "abcdefghijklmnopqrstuvwxyz012345";
  while (key.length < 24) [key appendFormat:@"%c", alphabet[arc4random_uniform(32)]];
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://services.odata.org/V4/(S(%@))/TripPinServiceRW/", key]];
}

// Presets: entity, predicate, sort key, ascending, $expand, result type,
// and a limit.
static NSDictionary *WBPreset(NSString *label, NSString *entity, NSString *predicate, NSString *sort, BOOL asc,
                              NSString *expand, NSString *type, NSString *limit)
{
  return @{ @"label": label, @"entity": entity, @"predicate": predicate ?: @"", @"sort": sort ?: @"", @"asc": @(asc),
            @"expand": expand ?: @"", @"type": type ?: @"objects", @"limit": limit ?: @"" };
}

static NSArray *WorkbenchPresets(WBService service)
{
  switch (service) {
    case WBServiceBuiltIn:
      return @[
        WBPreset(@"All products", @"Product", nil, @"name", YES, nil, nil, nil),
        WBPreset(@"Priced over 20", @"Product", @"unitPrice > 20 AND discontinued == NO", @"unitPrice", NO, nil, nil, nil),
        WBPreset(@"Beverages + category", @"Product", @"category.name == \"Beverages\"", @"name", YES, @"category", nil, nil),
        WBPreset(@"Top 5 dictionary", @"Product", nil, @"unitPrice", NO, nil, @"dictionary", @"5"),
        WBPreset(@"Count discontinued", @"Product", @"discontinued == YES", @"id", YES, nil, @"count", nil),
        WBPreset(@"Name begins with C", @"Product", @"name BEGINSWITH[cd] \"c\"", @"name", YES, nil, nil, nil),
        WBPreset(@"UK suppliers", @"Supplier", @"country == \"UK\"", @"companyName", YES, @"products", nil, nil),
        WBPreset(@"Stock on hand", @"Stock", @"quantity > 10", @"quantity", NO, @"location", nil, nil),
        WBPreset(@"Suppliers of pricey things (any)", @"Supplier", @"ANY products.unitPrice > 30", @"companyName", YES, nil, nil, nil),
        WBPreset(@"Stock in London (a path)", @"Stock", @"location.city == \"London\" AND product.discontinued == NO", @"quantity", NO, @"product", nil, nil),
        WBPreset(@"Chosen products (in)", @"Product", @"name IN {\"Chai\", \"Tofu\", \"Ikura\"}", @"name", YES, nil, nil, nil),
        WBPreset(@"By category, then price; nested prefetch", @"Product", nil, @"category.name, unitPrice desc", YES,
                 @"category, suppliers.products", nil, nil),
      ];
    case WBServiceNorthwind:
      return @[
        WBPreset(@"All products", @"Product", nil, @"productName", YES, nil, nil, nil),
        WBPreset(@"Priced over 20", @"Product", @"unitPrice > 20 AND discontinued == NO", @"unitPrice", NO, nil, nil, nil),
        WBPreset(@"Beverages + category", @"Product", @"category.categoryName == \"Beverages\"", @"productName", YES, @"category", nil, nil),
        WBPreset(@"Top 5 dictionary", @"Product", nil, @"unitPrice", NO, nil, @"dictionary", @"5"),
        WBPreset(@"Count discontinued", @"Product", @"discontinued == YES", @"productID", YES, nil, @"count", nil),
        WBPreset(@"Ordered 100 at once (any)", @"Product", @"ANY order_Details.quantity >= 100", @"productName", YES, nil, nil, nil),
        WBPreset(@"Orders of ALFKI", @"Order", @"customerID == \"ALFKI\"", @"orderDate", YES, @"customer", nil, nil),
        WBPreset(@"UK suppliers", @"Supplier", @"country == \"UK\"", @"companyName", YES, @"products", nil, nil),
        WBPreset(@"Latest orders, with lines and products", @"Order", nil, @"orderDate desc, orderID", YES,
                 @"customer, order_Details.product", nil, @"10"),
      ];
    case WBServiceTripPin:
      return @[
        WBPreset(@"All people", @"Person", nil, @"userName", YES, nil, nil, nil),
        WBPreset(@"Women (an enumeration)", @"Person", @"gender == \"Female\"", @"lastName", YES, nil, nil, nil),
        WBPreset(@"Lives in Boise (any, complex)", @"Person", @"ANY addressInfo.city.name == \"Boise\"", @"userName", YES, nil, nil, nil),
        WBPreset(@"E-mail at example.com", @"Person", @"ANY emails ENDSWITH \"example.com\"", @"userName", YES, nil, nil, nil),
        WBPreset(@"Airports in San Francisco", @"Airport", @"location.city.name == \"San Francisco\"", @"name", YES, nil, nil, nil),
        WBPreset(@"All airlines", @"Airline", nil, @"name", YES, nil, nil, nil),
        WBPreset(@"Count people", @"Person", nil, @"userName", YES, nil, @"count", nil),
        WBPreset(@"Top 3 dictionary", @"Person", nil, @"lastName", YES, nil, @"dictionary", @"3"),
        WBPreset(@"People, their photos, their friends' photos", @"Person", nil, @"lastName, firstName", YES, @"photo, friends.photo", nil, nil),
      ];
    case WBServiceOther:
      return @[];
  }
  return @[];
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

// A value as one line of a table cell.
static id WBCellValue(id value)
{
  if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (id item in value) [parts addObject:[WBCellValue(item) description]];
    return [NSString stringWithFormat:@"[%@]", [parts componentsJoinedByString:@", "]];
  }
  if ([value isKindOfClass:[NSDictionary class]]) {
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *key in [[value allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      [parts addObject:[NSString stringWithFormat:@"%@: %@", key, WBCellValue(value[key])]];
    }
    return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@", "]];
  }
  if (value == [NSNull null]) return @"null";
  return value;
}

@implementation WorkbenchController {
  NSManagedObjectContext *_context;
  NSManagedObjectModel *_model;
  ODataIncrementalStore *_store;
  WorkbenchEngine *_engine;
  NSURL *_serviceRoot;
  WBService _service;
  NSArray *_presets;
  NSArray *_rows;
  BOOL _connecting;
  NSString *_lastError;  // the last fetch's, for the self-test
  // The query panel: sort keys (key, descending), prefetch key paths, and
  // properties for dictionary results; the lists that show them.
  NSMutableArray *_sorts;
  NSMutableSet *_prefetch;
  NSMutableSet *_select;
  NSMutableDictionary *_pathItems;  // key path -> the one string the outline knows it by
  NSTableView *_sortTable;
  NSOutlineView *_expandOutline;
  NSTableView *_selectTable;
  // The wire log, newest first, and the window that shows one exchange.
  NSMutableArray *_log;
  NSTableView *_logTable;
  NSWindow *_exchangeWindow;
  NSTextView *_requestView;
  NSTextView *_responseView;
}

- (instancetype)init
{
  self = [super init];
  if (!self) return nil;
  _rows = @[];
  _service = WBServiceBuiltIn;
  [ODataIncrementalStore registerStore];
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
  self.skipField.delegate = (id)self;
  self.batchSizeField.delegate = (id)self;
  _sorts = [NSMutableArray array];
  _prefetch = [NSMutableSet set];
  _select = [NSMutableSet set];
  _pathItems = [NSMutableDictionary dictionary];
  [self buildQueryPanel];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(refreshTranslation)
                                               name:NSTextDidChangeNotification
                                             object:self.predicateView];
  // The xib leaves the text views' colours to the platform, and GNUstep
  // draws them black on black.
  _log = [NSMutableArray array];
  [self buildLogTable];
  for (NSTextView *view in @[ self.predicateView, self.inspectorView ]) {
    view.drawsBackground = YES;
    view.backgroundColor = [NSColor textBackgroundColor];
    view.textColor = [NSColor textColor];
    view.insertionPointColor = [NSColor textColor];
    [self makeScrollable:view];
  }
  [self.servicePopup selectItemAtIndex:WBServiceBuiltIn];
  [self serviceChanged:nil];
}

// The xib's text views are the size of their scroll views and stay so:
// with nothing beyond the visible part there is nothing to scroll. They
// grow with their text instead, as wide as the scroll view.
- (void)makeScrollable:(NSTextView *)view
{
  NSScrollView *scrollView = view.enclosingScrollView;
  NSSize size = scrollView.contentSize;
  view.minSize = NSMakeSize(0, size.height);
  view.maxSize = NSMakeSize(1e7, 1e7);
  view.verticallyResizable = YES;
  view.horizontallyResizable = NO;
  view.autoresizingMask = NSViewWidthSizable;
  view.frame = NSMakeRect(0, 0, size.width, size.height);
  view.textContainer.containerSize = NSMakeSize(size.width, 1e7);
  view.textContainer.widthTracksTextView = YES;
  // Off and on again: GNUstep leaves a scroller it hid, while the text
  // fitted, out of the view, and setting YES again does not bring it back.
  scrollView.autohidesScrollers = NO;
  scrollView.hasVerticalScroller = NO;
  scrollView.hasVerticalScroller = YES;
  [scrollView tile];
}

// Text into a text view, which is resized to it (GNUstep does not do that
// on -setString:), and shown from the top.
- (void)show:(NSString *)text in:(NSTextView *)view
{
  view.string = text ?: @"";
  [view.layoutManager ensureLayoutForTextContainer:view.textContainer];  // Apple lays text out lazily
  [view sizeToFit];
  [view scrollRangeToVisible:NSMakeRange(0, 0)];
}

#pragma mark - Services

- (IBAction)serviceChanged:(id)sender
{
  (void)sender;
  _service = (WBService)MAX(0, self.servicePopup.indexOfSelectedItem);
  switch (_service) {
    case WBServiceBuiltIn: self.serviceURLField.stringValue = WBBuiltInRoot; break;
    case WBServiceNorthwind: self.serviceURLField.stringValue = WBNorthwindRoot; break;
    case WBServiceTripPin: self.serviceURLField.stringValue = WBTripPinRoot; break;
    case WBServiceOther:
      if ([@[ WBBuiltInRoot, WBNorthwindRoot, WBTripPinRoot ] containsObject:self.serviceURLField.stringValue]) {
        self.serviceURLField.stringValue = @"";
      }
      [self.window makeFirstResponder:self.serviceURLField];
      self.statusField.stringValue = @"Type the service root URL of an OData v4 service, then Connect.";
      return;
  }
  [self connect:nil];
}

- (IBAction)connect:(id)sender
{
  (void)sender;
  if (_connecting) return;
  if (sender == self.serviceURLField || sender == self.connectButton) {
    // A URL typed in is another service, unless it is one of ours.
    NSString *typed = [self.serviceURLField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray *known = @[ WBBuiltInRoot, WBNorthwindRoot, WBTripPinRoot ];
    NSUInteger index = [known indexOfObject:typed];
    _service = index == NSNotFound ? WBServiceOther : (WBService)index;
    [self.servicePopup selectItemAtIndex:_service];
  }
  [_log removeAllObjects];
  [_logTable reloadData];
  _rows = @[];
  [self.tableView reloadData];
  if (_service == WBServiceBuiltIn) {
    [self openBuiltIn];
    return;
  }
  NSString *typed = [self.serviceURLField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (typed.length && ![typed hasSuffix:@"/"]) typed = [typed stringByAppendingString:@"/"];
  NSURL *url = _service == WBServiceTripPin ? WBTripPinSession() : [NSURL URLWithString:typed];
  if (!url.scheme.length || !url.host.length) {
    self.statusField.stringValue = @"That is not a service root URL (https://host/path/).";
    return;
  }
  [self connectToURL:url];
}

- (void)openBuiltIn
{
  _serviceRoot = [NSURL URLWithString:WBBuiltInRoot];
  NSURL *modelURL = WorkbenchModelURL();
  NSManagedObjectModel *model = modelURL ? [[NSManagedObjectModel alloc] initWithContentsOfURL:modelURL] : nil;
  if (!model) {
    self.statusField.stringValue = @"Catalog.xcdatamodeld not found.";
    return;
  }
  _engine = [[WorkbenchEngine alloc] initWithServiceRoot:_serviceRoot];
  __weak WorkbenchController *weak = self;
  _engine.didHandle = ^(WorkbenchLogEntry *entry) {
    [weak appendLog:entry];
  };
  NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
  NSError *error = nil;
  NSDictionary *options = @{ ODataIncrementalStoreTransportOption: _engine, NSPersistentHistoryTrackingKey: @YES };
  ODataIncrementalStore *store = (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                                             configuration:nil URL:_serviceRoot options:options error:&error];
  [self useModel:model coordinator:psc store:store error:error];
}

// Connecting reads $metadata twice (for the model, then for the store), so
// it happens away from the main thread; the UI waits for it.
- (void)connectToURL:(NSURL *)url
{
  _connecting = YES;
  self.connectButton.enabled = NO;
  self.statusField.stringValue = [NSString stringWithFormat:@"Connecting to %@ …", url.absoluteString];
  WorkbenchNetworkTransport *transport = [[WorkbenchNetworkTransport alloc] init];
  __weak WorkbenchController *weak = self;
  transport.didHandle = ^(WorkbenchLogEntry *entry) {
    [weak appendLog:entry];
  };
  _engine = nil;
  [NSThread detachNewThreadSelector:@selector(connectInBackground:) toTarget:self withObject:@{ @"url": url, @"transport": transport }];
}

- (void)connectInBackground:(NSDictionary *)job
{
  @autoreleasepool {
    NSURL *url = job[@"url"];
    NSDictionary *options = @{ ODataIncrementalStoreTransportOption: job[@"transport"], NSPersistentHistoryTrackingKey: @YES };
    NSError *error = nil;
    NSMutableDictionary *result = [NSMutableDictionary dictionaryWithObject:url forKey:@"url"];
    NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:url options:options error:&error];
    if (model) {
      NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
      ODataIncrementalStore *store = (ODataIncrementalStore *)[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                                                                                 configuration:nil URL:url options:options error:&error];
      result[@"model"] = model;
      result[@"coordinator"] = psc;
      if (store) result[@"store"] = store;
    }
    if (error) result[@"error"] = error;
    [self performSelectorOnMainThread:@selector(connected:) withObject:result waitUntilDone:NO];
  }
}

- (void)connected:(NSDictionary *)result
{
  _connecting = NO;
  self.connectButton.enabled = YES;
  _serviceRoot = result[@"url"];
  [self useModel:result[@"model"] coordinator:result[@"coordinator"] store:result[@"store"] error:result[@"error"]];
}

- (void)useModel:(NSManagedObjectModel *)model coordinator:(NSPersistentStoreCoordinator *)psc
           store:(ODataIncrementalStore *)store error:(NSError *)error
{
  if (!store) {
    NSString *why = error.localizedDescription ?: @"the store could not be opened";
    NSError *cause = error.userInfo[NSUnderlyingErrorKey];
    if (cause.localizedDescription.length) why = [NSString stringWithFormat:@"%@ (%@)", why, cause.localizedDescription];
    self.statusField.stringValue = [NSString stringWithFormat:@"Could not connect: %@", why];
    return;
  }
  _model = model;
  _store = store;
  _context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
  _context.persistentStoreCoordinator = psc;
  _context.transactionAuthor = @"Workbench";

  [self.entityPopup removeAllItems];
  [self.entityPopup addItemsWithTitles:[self entityNames]];
  _presets = WorkbenchPresets(_service);
  if (!_presets.count) {
    // Another service: the first few entity sets, whole.
    NSMutableArray *generic = [NSMutableArray array];
    for (NSString *name in [self entityNames]) {
      NSEntityDescription *entity = _model.entitiesByName[name];
      if (entity.superentity || entity.isAbstract) continue;
      [generic addObject:WBPreset([NSString stringWithFormat:@"All %@", name], name, nil, [self columnNamesFor:entity].firstObject, YES, nil, nil, @"50")];
      if (generic.count == 12) break;
    }
    _presets = generic;
  }
  [self.presetsPopup removeAllItems];
  for (NSDictionary *preset in _presets) [self.presetsPopup addItemWithTitle:preset[@"label"]];
  [self showPending];

  NSUInteger operations = 0;
  for (NSArray *overloads in store.schema.operations.allValues) operations += overloads.count;
  NSMutableString *status = [NSMutableString stringWithFormat:@"%@: %lu entities, %lu operations, OData %@.",
                             _service == WBServiceBuiltIn ? @"Built-in in-memory service" : _serviceRoot.absoluteString,
                             (unsigned long)_model.entities.count, (unsigned long)operations, store.schema.version ?: @"4.0"];
  if (_service == WBServiceTripPin) [status appendString:@" A session of its own: write freely."];
  if (_service == WBServiceNorthwind) [status appendString:@" Read-only."];
  self.statusField.stringValue = status;
  if (_presets.count) {
    [self.presetsPopup selectItemAtIndex:0];
    [self applyPreset:nil];
    [self runFetch:nil];
    self.statusField.stringValue = [NSString stringWithFormat:@"%@  %@", status, self.statusField.stringValue];
  } else {
    [self entityChanged:nil];
  }
}

- (IBAction)resetStore:(id)sender
{
  (void)sender;
  // The built-in service is seeded again; TripPin gets a new session.
  [self connect:nil];
}

#pragma mark - The model

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
  return self.entityPopup.titleOfSelectedItem.length ? self.entityPopup.titleOfSelectedItem : [self entityNames].firstObject;
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

static BOOL WBIsKey(NSAttributeDescription *attr)
{
  id flag = attr.userInfo[ODataUserInfoKey];
  return [flag isEqual:@"YES"] || [flag isEqual:@YES];
}

// What to show of an entity: the Catalog's own choice, or its key and its
// other plain attributes (complex values and collections last), six at most.
- (NSArray *)columnNamesFor:(NSEntityDescription *)entity
{
  if (_service == WBServiceBuiltIn) {
    NSString *name = entity.name;
    if ([name isEqualToString:@"Product"]) return @[ @"id", @"name", @"unitPrice", @"discontinued" ];
    if ([name isEqualToString:@"Supplier"]) return @[ @"id", @"companyName", @"city", @"country" ];
    if ([name isEqualToString:@"Location"]) return @[ @"id", @"name", @"city", @"country" ];
    if ([name isEqualToString:@"Stock"]) return @[ @"id", @"quantity" ];
    if ([name isEqualToString:@"Category"]) return @[ @"id", @"name" ];
  }
  NSMutableArray *keys = [NSMutableArray array], *names = [NSMutableArray array], *plain = [NSMutableArray array];
  NSMutableArray *references = [NSMutableArray array], *rest = [NSMutableArray array];
  for (NSString *name in [entity.attributesByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSAttributeDescription *attr = entity.attributesByName[name];
    if (WBIsKey(attr)) [keys addObject:name];
    else if (attr.attributeType == NSTransformableAttributeType || attr.attributeType == NSBinaryDataAttributeType) [rest addObject:name];
    else if ([name isEqualToString:@"name"] || [name hasSuffix:@"Name"]) [names addObject:name];
    else if ([name hasSuffix:@"ID"] || [name hasSuffix:@"Id"]) [references addObject:name];  // most likely a foreign key
    else [plain addObject:name];
  }
  NSMutableArray *all = [keys mutableCopy];
  for (NSArray *group in @[ names, plain, references, rest ]) [all addObjectsFromArray:group];
  return all.count > 7 ? [all subarrayWithRange:NSMakeRange(0, 7)] : all;
}

- (NSArray *)columnNames
{
  if ([self currentResultType] == NSDictionaryResultType && _select.count) {
    return [_select.allObjects sortedArrayUsingSelector:@selector(compare:)];
  }
  return [self columnNamesFor:[self currentEntity]];
}

// sort keys go through to-one relationships to an attribute.
- (BOOL)keyPathLeadsToAnAttribute:(NSString *)keyPath
{
  NSEntityDescription *entity = [self currentEntity];
  NSArray *parts = [keyPath componentsSeparatedByString:@"."];
  for (NSUInteger i = 0; i < parts.count; i++) {
    if (i == parts.count - 1) return entity.attributesByName[parts[i]] != nil;
    NSRelationshipDescription *rel = entity.relationshipsByName[parts[i]];
    if (!rel || rel.isToMany) return NO;
    entity = rel.destinationEntity;
  }
  return NO;
}

// A few words that name an object: its name, if it has one.
- (NSString *)titleOf:(NSManagedObject *)object
{
  NSDictionary *attrs = object.entity.attributesByName;
  NSMutableArray *candidates = [@[ @"name", @"title", @"userName", @"productName", @"companyName", @"categoryName" ] mutableCopy];
  for (NSString *attr in [attrs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    if ([attr hasSuffix:@"Name"] && [attrs[attr] attributeType] == NSStringAttributeType) [candidates addObject:attr];
  }
  @try {
    for (NSString *candidate in candidates) {
      if (!attrs[candidate]) continue;
      id value = [object valueForKey:candidate];
      if (value) return [value description];
    }
    for (NSString *key in [self columnNamesFor:object.entity]) {
      id value = [object valueForKey:key];
      if (value) return [NSString stringWithFormat:@"%@ = %@", key, value];
    }
  } @catch (NSException *ex) {
    return ex.reason;
  }
  return object.objectID.URIRepresentation.lastPathComponent;
}

// A new entity's query: sorted by its first column, nothing prefetched,
// the usual properties.
- (void)resetQuery
{
  [_sorts removeAllObjects];
  NSString *first = [self columnNames].firstObject;
  if (first) [_sorts addObject:[@{ @"key": first, @"descending": @NO } mutableCopy]];
  [_prefetch removeAllObjects];
  [_select removeAllObjects];
  [_pathItems removeAllObjects];
  [self reloadQueryPanel];
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
    col.width = ident.length > 6 ? 150 : 90;
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

#pragma mark - Fetching

- (NSFetchRequest *)buildRequestError:(NSError **)error
{
  NSString *entityName = [self currentEntityName];
  if (!entityName) {
    if (error) *error = [NSError errorWithDomain:@"Workbench" code:2 userInfo:@{ NSLocalizedDescriptionKey: @"Not connected." }];
    return nil;
  }
  NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:entityName];
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
  NSMutableArray *sorts = [NSMutableArray array];
  for (NSDictionary *sort in _sorts) {
    NSString *key = [sort[@"key"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (!key.length) continue;
    if (![self keyPathLeadsToAnAttribute:key]) {
      if (error) *error = [NSError errorWithDomain:@"Workbench" code:3 userInfo:@{ NSLocalizedDescriptionKey:
          [NSString stringWithFormat:@"Cannot sort by %@: not an attribute, or through to-one relationships to one", key] }];
      return nil;
    }
    [sorts addObject:[NSSortDescriptor sortDescriptorWithKey:key ascending:![sort[@"descending"] boolValue]]];
  }
  request.sortDescriptors = sorts;
  if (self.limitField.stringValue.length) request.fetchLimit = (NSUInteger)[self.limitField.stringValue integerValue];
  if (self.skipField.stringValue.length) request.fetchOffset = (NSUInteger)[self.skipField.stringValue integerValue];
  if (self.batchSizeField.stringValue.length) request.fetchBatchSize = (NSUInteger)[self.batchSizeField.stringValue integerValue];
  request.includesSubentities = self.subentitiesButton.state == NSOnState;
  request.relationshipKeyPathsForPrefetching = [_prefetch.allObjects sortedArrayUsingSelector:@selector(compare:)];
  request.resultType = [self currentResultType];
  request.returnsObjectsAsFaults = (self.faultsButton.state == NSOnState);
  if (request.resultType == NSDictionaryResultType) request.propertiesToFetch = [self columnNames];
  return request;
}

// The GET the store would send, from the same schema and version it uses.
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
  mapper.schema = _store.schema;
  ODataQueryBuilder *builder = [[ODataQueryBuilder alloc] initWithMapper:mapper serviceRoot:_serviceRoot];
  ODataConfiguration *configuration = [[ODataConfiguration alloc] initWithURL:_serviceRoot options:nil];
  builder.version = [configuration versionForService:_store.schema.version];
  builder.keyAsSegment = _store.schema.keyAsSegmentSupported;
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
  [self resetQuery];
  [self rebuildColumns];
  _rows = @[];
  [self.tableView reloadData];
  [self rebuildOperations];
  [self refreshTranslation];
}

- (IBAction)applyPreset:(id)sender
{
  (void)sender;
  NSInteger idx = self.presetsPopup.indexOfSelectedItem;
  if (idx < 0 || idx >= (NSInteger)_presets.count) return;
  NSDictionary *p = _presets[(NSUInteger)idx];
  [self.entityPopup selectItemWithTitle:p[@"entity"]];
  [self resetQuery];
  self.predicateView.string = p[@"predicate"] ?: @"";
  [_sorts removeAllObjects];
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  for (NSString *item in [p[@"sort"] componentsSeparatedByString:@","]) {
    NSArray *words = [[item stringByTrimmingCharactersInSet:space] componentsSeparatedByString:@" "];
    if (![words.firstObject length]) continue;
    BOOL descending = words.count > 1 ? [words.lastObject isEqualToString:@"desc"] : ![p[@"asc"] boolValue];
    [_sorts addObject:[@{ @"key": words.firstObject, @"descending": @(descending) } mutableCopy]];
  }
  self.limitField.stringValue = p[@"limit"] ?: @"";
  self.skipField.stringValue = @"";
  for (NSString *path in [p[@"expand"] componentsSeparatedByString:@","]) {
    NSString *trimmed = [path stringByTrimmingCharactersInSet:space];
    if (trimmed.length) [_prefetch addObject:trimmed];
  }
  [self reloadQueryPanel];
  NSString *type = p[@"type"];
  if ([type isEqualToString:@"count"]) [self.resultTypePopup selectItemWithTitle:@"count"];
  else if ([type isEqualToString:@"dictionary"]) [self.resultTypePopup selectItemWithTitle:@"dictionary"];
  else [self.resultTypePopup selectItemWithTitle:@"objects"];
  [self rebuildColumns];
  [self rebuildOperations];
  [self refreshTranslation];
}

- (IBAction)runFetch:(id)sender
{
  (void)sender;
  if (!_context) {
    self.statusField.stringValue = @"Not connected.";
    return;
  }
  NSError *error = nil;
  NSFetchRequest *request = [self buildRequestError:&error];
  if (!request) {
    self.statusField.stringValue = error.localizedDescription;
    return;
  }
  [self refreshTranslation];
  // A count goes through -countForFetchRequest:error:, which reports a
  // failed request; -executeFetchRequest: on Apple makes it a count of 0.
  id result;
  if (request.resultType == NSCountResultType) {
    NSUInteger count = [_context countForFetchRequest:request error:&error];
    result = count == NSNotFound ? nil : @[ @(count) ];
  } else {
    result = [_context executeFetchRequest:request error:&error];
  }
  _lastError = error.localizedDescription;
  if (error) {
    self.statusField.stringValue = error.localizedDescription;
    _rows = @[];
  } else if ([self currentResultType] == NSCountResultType) {
    _rows = [result isKindOfClass:[NSArray class]] ? result : @[ result ?: @0 ];
    self.statusField.stringValue = [NSString stringWithFormat:@"count = %@", _rows.firstObject];
  } else {
    _rows = result ?: @[];
    self.statusField.stringValue = [NSString stringWithFormat:@"%lu %@", (unsigned long)_rows.count, [self currentEntityName]];
  }
  [self rebuildColumns];
  [self.tableView reloadData];
  [self inspectSelection];
}

- (void)appendLog:(WorkbenchLogEntry *)entry
{
  NSInteger selected = _logTable.selectedRow;
  WorkbenchLogEntry *shown = selected >= 0 && (NSUInteger)selected < _log.count ? _log[(NSUInteger)selected] : nil;
  [_log insertObject:entry atIndex:0];
  if (_log.count > 1000) [_log removeLastObject];
  [_logTable reloadData];
  NSUInteger again = shown ? [_log indexOfObjectIdenticalTo:shown] : NSNotFound;
  if (again != NSNotFound) [_logTable selectRowIndexes:[NSIndexSet indexSetWithIndex:again] byExtendingSelection:NO];
}

#pragma mark - The wire log

- (void)buildLogTable
{
  NSScrollView *scrollView = self.logScrollView;
  _logTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, scrollView.contentSize.width, scrollView.contentSize.height)];
  for (NSArray *spec in @[ @[ @"time", @"time", @86 ], @[ @"method", @"", @48 ], @[ @"status", @"", @32 ], @[ @"URL", @"request", @360 ] ]) {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
    column.title = spec[1];
    column.width = [spec[2] doubleValue];
    column.editable = NO;
    [_logTable addTableColumn:column];
  }
  _logTable.dataSource = self;
  _logTable.delegate = self;
  _logTable.target = self;
  _logTable.doubleAction = @selector(showExchange:);
  scrollView.documentView = _logTable;
  scrollView.autohidesScrollers = NO;
  scrollView.hasVerticalScroller = NO;  // off and on: see -makeScrollable:
  scrollView.hasVerticalScroller = YES;
  [scrollView tile];
}

- (id)logValueForColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (row < 0 || (NSUInteger)row >= _log.count) return nil;
  WorkbenchLogEntry *entry = _log[(NSUInteger)row];
  NSString *identifier = column.identifier;
  if ([identifier isEqualToString:@"time"]) {
    static NSDateFormatter *format;
    if (!format) {
      format = [[NSDateFormatter alloc] init];
      format.dateFormat = @"HH:mm:ss.SSS";
    }
    return entry.date ? [format stringFromDate:entry.date] : @"";
  }
  if ([identifier isEqualToString:@"method"]) return entry.method;
  if ([identifier isEqualToString:@"status"]) return entry.status ? [NSString stringWithFormat:@"%ld", (long)entry.status] : @"—";
  // The URL from the service root on, decoded to be read.
  NSString *url = entry.URL;
  NSString *root = _serviceRoot.absoluteString;
  if (root.length && [url hasPrefix:root]) url = [url substringFromIndex:root.length];
  return [url stringByRemovingPercentEncoding] ?: url;
}

// A body as it went: its text where it is UTF-8, else a hex dump.
static NSString *WBRawBody(NSData *data)
{
  if (!data.length) return @"";
  NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (text) return text;
  NSMutableString *dump = [NSMutableString stringWithFormat:@"(%lu bytes, not UTF-8 text)\n", (unsigned long)data.length];
  const unsigned char *bytes = data.bytes;
  for (NSUInteger offset = 0; offset < data.length; offset += 16) {
    NSMutableString *hex = [NSMutableString string], *ascii = [NSMutableString string];
    for (NSUInteger i = offset; i < offset + 16; i++) {
      if (i < data.length) {
        [hex appendFormat:@"%02x ", bytes[i]];
        [ascii appendFormat:@"%c", bytes[i] >= 32 && bytes[i] < 127 ? bytes[i] : '.'];
      } else {
        [hex appendString:@"   "];
      }
    }
    [dump appendFormat:@"%08lx  %@ |%@|\n", (unsigned long)offset, hex, ascii];
  }
  return dump;
}

static NSString *WBRawHeaders(NSDictionary *headers)
{
  NSMutableString *text = [NSMutableString string];
  for (NSString *name in [headers.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
    [text appendFormat:@"%@: %@\n", name, headers[name]];
  }
  return text;
}

- (NSString *)rawRequestOf:(WorkbenchLogEntry *)entry
{
  return [NSString stringWithFormat:@"%@ %@ HTTP/1.1\n%@\n%@", entry.method, entry.URL, WBRawHeaders(entry.requestHeaders),
                                    WBRawBody(entry.requestData)];
}

- (NSString *)rawResponseOf:(WorkbenchLogEntry *)entry
{
  if (!entry.status) return [NSString stringWithFormat:@"(no answer: %@)", entry.failure ?: @"the request failed"];
  // HTTP's own reason phrases: Foundation's localized ones say "no error".
  static NSDictionary *reasons;
  if (!reasons) {
    reasons = @{ @200: @"OK", @201: @"Created", @202: @"Accepted", @204: @"No Content", @302: @"Found", @304: @"Not Modified",
                 @400: @"Bad Request", @401: @"Unauthorized", @403: @"Forbidden", @404: @"Not Found", @405: @"Method Not Allowed",
                 @406: @"Not Acceptable", @409: @"Conflict", @412: @"Precondition Failed", @415: @"Unsupported Media Type",
                 @428: @"Precondition Required", @500: @"Internal Server Error", @501: @"Not Implemented", @503: @"Service Unavailable" };
  }
  NSString *reason = reasons[@(entry.status)] ?: [NSHTTPURLResponse localizedStringForStatusCode:entry.status].capitalizedString;
  return [NSString stringWithFormat:@"HTTP/1.1 %ld %@\n%@\n%@", (long)entry.status, reason ?: @"",
                                    WBRawHeaders(entry.responseHeaders), WBRawBody(entry.responseData)];
}

- (NSTextView *)exchangeTextViewIn:(NSSplitView *)split
{
  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, split.bounds.size.width, split.bounds.size.height / 2)];
  scrollView.borderType = NSBezelBorder;
  scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSTextView *view = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, scrollView.contentSize.width, scrollView.contentSize.height)];
  view.editable = NO;
  view.selectable = YES;
  view.richText = NO;
  view.font = [NSFont userFixedPitchFontOfSize:11];
  view.drawsBackground = YES;
  view.backgroundColor = [NSColor textBackgroundColor];
  view.textColor = [NSColor textColor];
  scrollView.documentView = view;
  [split addSubview:scrollView];
  [self makeScrollable:view];
  return view;
}

// One exchange, whole: the request above, the response below.
- (void)buildExchangeWindow
{
  _exchangeWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(120, 120, 860, 640)
                                                styleMask:NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask | NSMiniaturizableWindowMask
                                                  backing:NSBackingStoreBuffered defer:NO];
  _exchangeWindow.releasedWhenClosed = NO;
  NSView *content = _exchangeWindow.contentView;
  NSSplitView *split = [[NSSplitView alloc] initWithFrame:NSMakeRect(8, 30, content.bounds.size.width - 16, content.bounds.size.height - 38)];
  split.vertical = NO;
  split.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [content addSubview:split];
  _requestView = [self exchangeTextViewIn:split];
  _responseView = [self exchangeTextViewIn:split];
  [split adjustSubviews];
  NSTextField *note = WBLabel(@"As the store sent and received it. The URL loading system may add headers of its own (Host, "
                              @"Content-Length) and undoes compression.", NSMakeRect(8, 6, content.bounds.size.width - 16, 18));
  note.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [content addSubview:note];
}

- (IBAction)showExchange:(id)sender
{
  (void)sender;
  NSInteger row = _logTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _log.count) return;
  WorkbenchLogEntry *entry = _log[(NSUInteger)row];
  if (!_exchangeWindow) [self buildExchangeWindow];
  _exchangeWindow.title = [NSString stringWithFormat:@"%@ %@ — %@ (%.0f ms)", entry.method, [self logValueForColumn:[_logTable tableColumnWithIdentifier:@"URL"] row:row],
                                                     entry.status ? [NSString stringWithFormat:@"%ld", (long)entry.status] : @"no answer", entry.duration * 1000];
  [self show:[self rawRequestOf:entry] in:_requestView];
  [self show:[self rawResponseOf:entry] in:_responseView];
  [_exchangeWindow makeKeyAndOrderFront:nil];
}


#pragma mark - The table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)table
{
  if (table == _logTable) return (NSInteger)_log.count;
  if (table == _sortTable) return (NSInteger)_sorts.count;
  if (table == _selectTable) return (NSInteger)[self attributeNames].count;
  return (NSInteger)_rows.count;
}

- (id)tableView:(NSTableView *)table objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _logTable) return [self logValueForColumn:column row:row];
  if (table == _sortTable || table == _selectTable) return [self queryValueIn:table column:column row:row];
  if (row < 0 || (NSUInteger)row >= _rows.count) return nil;
  id obj = _rows[(NSUInteger)row];
  if ([obj isKindOfClass:[NSNumber class]]) return obj;
  if ([obj isKindOfClass:[NSDictionary class]]) return WBCellValue(obj[column.identifier]);
  if ([obj isKindOfClass:[NSManagedObjectID class]]) return [obj URIRepresentation];
  if ([obj isKindOfClass:[NSManagedObject class]]) {
    @try {
      id value = [obj valueForKey:column.identifier];
      if ([[obj entity].attributesByName[column.identifier] attributeType] == NSBooleanAttributeType && value) {
        return [value boolValue] ? @"true" : @"false";
      }
      return WBCellValue(value);
    } @catch (NSException *ex) {
      return ex.reason;
    }
  }
  return [obj description];
}

// An edit waits for Save, as a change to a managed object does. A key is
// the service's once the object is saved: only a new object's is edited.
- (void)tableView:(NSTableView *)table setObjectValue:(id)value forTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _sortTable || table == _selectTable) {
    [self setQueryValue:value in:table column:column row:row];
    return;
  }
  if (row < 0 || (NSUInteger)row >= _rows.count) return;
  id obj = _rows[(NSUInteger)row];
  if (![obj isKindOfClass:[NSManagedObject class]]) return;
  NSAttributeDescription *attr = [obj entity].attributesByName[column.identifier];
  BOOL isNew = [obj objectID].isTemporaryID;
  if (!attr || ((WBIsKey(attr) || [column.identifier isEqualToString:@"id"]) && !isNew)) {
    self.statusField.stringValue = attr ? @"A saved object's key is the service's: it cannot be changed." : @"Not an attribute.";
    return;
  }
  if (attr.attributeType == NSTransformableAttributeType || attr.attributeType == NSBinaryDataAttributeType) {
    self.statusField.stringValue = @"Complex values, collections and binary data are not edited here.";
    return;
  }
  id typed = value;
  switch (attr.attributeType) {
    case NSInteger16AttributeType:
    case NSInteger32AttributeType:
    case NSInteger64AttributeType: typed = @([value longLongValue]); break;
    case NSDoubleAttributeType:
    case NSFloatAttributeType: typed = @([value doubleValue]); break;
    case NSDecimalAttributeType: typed = [NSDecimalNumber decimalNumberWithString:[value description]]; break;
    case NSBooleanAttributeType: typed = @([value boolValue]); break;
    case NSStringAttributeType: typed = [value description]; break;
    default: break;
  }
  [obj setValue:typed forKey:column.identifier];
  [self showPending];
  [self.tableView reloadData];
  [self inspectSelection];
}

- (void)tableViewSelectionDidChange:(NSNotification *)n
{
  if (n.object == _logTable) {
    [self showExchange:nil];
    return;
  }
  if (n.object != self.tableView) return;
  [self inspectSelection];
  [self rebuildOperations];
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

// An object as the service addresses it: Airports('KLAX').
- (NSString *)addressOf:(NSManagedObject *)object
{
  NSPersistentStore *store = object.objectID.persistentStore;
  if (object.objectID.isTemporaryID || ![store isKindOfClass:[NSIncrementalStore class]]) return @"(not saved)";
  id reference = [(NSIncrementalStore *)store referenceObjectForObjectID:object.objectID];
  return [ODataResourceIdentifier identifierFromReference:reference].path ?: [reference description];
}

- (NSString *)describe:(NSManagedObject *)object
{
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@\n", object.entity.name, [self addressOf:object]];
  NSArray *attrs = [[object.entity.attributesByName allKeys] sortedArrayUsingSelector:@selector(compare:)];
  for (NSString *name in attrs) {
    @try {
      [text appendFormat:@"  %@ = %@\n", name, WBCellValue([object valueForKey:name]) ?: @"nil"];
    } @catch (NSException *ex) {
      [text appendFormat:@"  %@ fault failed (%@)\n", name, ex.reason];
    }
  }
  return text;
}

- (void)inspectSelection
{
  NSManagedObject *object = [self selectedObject];
  [self show:object ? [self describe:object] : @"Select a row." in:self.inspectorView];
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
        for (NSManagedObject *m in value) [text appendFormat:@"  • %@ %@\n", m.entity.name, [self titleOf:m]];
      } else {
        NSManagedObject *one = value;
        [text appendFormat:@"\n%@ (to-one) → %@\n", name, one ? one.entity.name : @"nil"];
        if (one) [text appendFormat:@"  %@\n", [self titleOf:one]];
      }
    } @catch (NSException *ex) {
      [text appendFormat:@"\n%@: %@\n", name, ex.reason];
    }
  }
  [self show:text in:self.inspectorView];
}

#pragma mark - The query panel

static NSTextField *WBLabel(NSString *text, NSRect frame)
{
  NSTextField *label = [[NSTextField alloc] initWithFrame:frame];
  label.stringValue = text;
  label.editable = NO;
  label.selectable = NO;
  label.bordered = NO;
  label.bezeled = NO;
  label.drawsBackground = NO;
  label.autoresizingMask = NSViewMinYMargin;
  return label;
}

// A list in a scroll view: columns of (identifier, title, width, a
// checkbox?); an outline view's first text column is its outline column.
- (id)addList:(Class)class frame:(NSRect)frame columns:(NSArray *)columns
{
  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:frame];
  scrollView.borderType = NSBezelBorder;
  scrollView.hasVerticalScroller = YES;
  scrollView.autoresizingMask = NSViewMinYMargin;
  NSTableView *list = [[class alloc] initWithFrame:NSMakeRect(0, 0, scrollView.contentSize.width, scrollView.contentSize.height)];
  for (NSArray *spec in columns) {
    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
    column.title = spec[1];
    column.width = [spec[2] doubleValue];
    column.editable = YES;
    if ([spec[3] boolValue]) {
      NSButtonCell *box = [[NSButtonCell alloc] init];
      [box setButtonType:NSSwitchButton];
      box.title = @"";
      column.dataCell = box;
    }
    [list addTableColumn:column];
    if ([list isKindOfClass:[NSOutlineView class]] && ![spec[3] boolValue] && !((NSOutlineView *)list).outlineTableColumn) {
      ((NSOutlineView *)list).outlineTableColumn = column;
    }
  }
  list.dataSource = (id)self;
  list.delegate = (id)self;
  scrollView.documentView = list;
  [self.window.contentView addSubview:scrollView];
  return list;
}

- (NSButton *)addButton:(NSString *)title frame:(NSRect)frame action:(SEL)action
{
  NSButton *button = [[NSButton alloc] initWithFrame:frame];
  button.title = title;
  button.bezelStyle = NSRoundedBezelStyle;
  button.target = self;
  button.action = action;
  button.autoresizingMask = NSViewMinYMargin;
  [self.window.contentView addSubview:button];
  return button;
}

// Everything a fetch request can ask of the store, as lists: sort keys
// ($orderby, through to-one relationships), relationships to prefetch
// ($expand, nested as deep as you open them), and properties ($select,
// for dictionary results).
- (void)buildQueryPanel
{
  NSView *content = self.window.contentView;
  // Frames as laid out for the xib's 860-point-high window, from its top:
  // a window the screen made shorter has already moved the xib's views.
  CGFloat dy = content.bounds.size.height - 860;
  [content addSubview:WBLabel(@"Sort ($orderby): key paths, first first", NSMakeRect(16, 664 + dy, 300, 16))];
  _sortTable = [self addList:[NSTableView class] frame:NSMakeRect(16, 548 + dy, 300, 114)
                     columns:@[ @[ @"key", @"key path", @220, @NO ], @[ @"descending", @"desc", @50, @YES ] ]];
  [self addButton:@"+" frame:NSMakeRect(320, 632 + dy, 32, 28) action:@selector(addSort:)];
  [self addButton:@"-" frame:NSMakeRect(320, 600 + dy, 32, 28) action:@selector(removeSort:)];
  [content addSubview:WBLabel(@"Prefetch ($expand): open to nest", NSMakeRect(362, 664 + dy, 360, 16))];
  _expandOutline = [self addList:[NSOutlineView class] frame:NSMakeRect(362, 548 + dy, 360, 114)
                         columns:@[ @[ @"include", @"", @24, @YES ], @[ @"relationship", @"relationship", @300, @NO ] ]];
  [content addSubview:WBLabel(@"Properties ($select, dictionary results)", NSMakeRect(734, 664 + dy, 366, 16))];
  _selectTable = [self addList:[NSTableView class] frame:NSMakeRect(734, 548 + dy, 366, 114)
                       columns:@[ @[ @"include", @"", @24, @YES ], @[ @"property", @"property", @300, @NO ] ]];
}

- (void)reloadQueryPanel
{
  [_sortTable reloadData];
  [_expandOutline reloadData];
  [_selectTable reloadData];
}

- (IBAction)addSort:(id)sender
{
  (void)sender;
  NSMutableSet *used = [NSMutableSet setWithArray:[_sorts valueForKey:@"key"]];
  NSString *next = @"";
  for (NSString *name in [self columnNames]) {
    if (![used containsObject:name]) {
      next = name;
      break;
    }
  }
  [_sorts addObject:[@{ @"key": next, @"descending": @NO } mutableCopy]];
  [_sortTable reloadData];
  [_sortTable selectRowIndexes:[NSIndexSet indexSetWithIndex:_sorts.count - 1] byExtendingSelection:NO];
  [self refreshTranslation];
}

- (IBAction)removeSort:(id)sender
{
  (void)sender;
  NSInteger row = _sortTable.selectedRow;
  if (row < 0 || (NSUInteger)row >= _sorts.count) row = (NSInteger)_sorts.count - 1;
  if (row < 0) return;
  [_sorts removeObjectAtIndex:(NSUInteger)row];
  [_sortTable reloadData];
  [self refreshTranslation];
}

- (id)queryValueIn:(NSTableView *)table column:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _sortTable) {
    if (row < 0 || (NSUInteger)row >= _sorts.count) return nil;
    return _sorts[(NSUInteger)row][column.identifier];
  }
  NSArray *names = [self attributeNames];
  if (row < 0 || (NSUInteger)row >= names.count) return nil;
  if ([column.identifier isEqualToString:@"include"]) return @([_select containsObject:names[(NSUInteger)row]]);
  return names[(NSUInteger)row];
}

- (void)setQueryValue:(id)value in:(NSTableView *)table column:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _sortTable) {
    if (row < 0 || (NSUInteger)row >= _sorts.count) return;
    _sorts[(NSUInteger)row][column.identifier] = [column.identifier isEqualToString:@"descending"] ? @([value boolValue]) : [value description];
  } else if ([column.identifier isEqualToString:@"include"]) {
    NSArray *names = [self attributeNames];
    if (row < 0 || (NSUInteger)row >= names.count) return;
    if ([value boolValue]) [_select addObject:names[(NSUInteger)row]];
    else [_select removeObject:names[(NSUInteger)row]];
    if ([self currentResultType] == NSDictionaryResultType) {
      _rows = @[];
      [self rebuildColumns];
      [self.tableView reloadData];
    }
  }
  [table reloadData];
  [self refreshTranslation];
}

// The outline's items are key paths from the current entity, one string
// per path, so the outline can tell them apart.
- (NSString *)itemForPath:(NSString *)path
{
  NSString *item = _pathItems[path];
  if (!item) _pathItems[path] = item = [path copy];
  return item;
}

- (NSEntityDescription *)entityAtPath:(NSString *)path
{
  NSEntityDescription *entity = [self currentEntity];
  for (NSString *part in path.length ? [path componentsSeparatedByString:@"."] : @[]) {
    NSRelationshipDescription *rel = entity.relationshipsByName[part];  // gnustep-base: no generics to type the subscript
    entity = rel.destinationEntity;
  }
  return entity;
}

- (NSArray *)childPathsOf:(NSString *)path
{
  if ([path componentsSeparatedByString:@"."].count >= 4) return @[];  // deep enough to see the point
  NSEntityDescription *entity = [self entityAtPath:path];
  NSMutableArray *children = [NSMutableArray array];
  for (NSString *name in [entity.relationshipsByName.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    [children addObject:[self itemForPath:path.length ? [NSString stringWithFormat:@"%@.%@", path, name] : name]];
  }
  return children;
}

- (NSInteger)outlineView:(NSOutlineView *)outline numberOfChildrenOfItem:(id)item
{
  return _model ? (NSInteger)[self childPathsOf:item ?: @""].count : 0;
}

- (id)outlineView:(NSOutlineView *)outline child:(NSInteger)index ofItem:(id)item
{
  return [self childPathsOf:item ?: @""][(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outline isItemExpandable:(id)item
{
  return [self childPathsOf:item].count > 0;
}

- (id)outlineView:(NSOutlineView *)outline objectValueForTableColumn:(NSTableColumn *)column byItem:(id)item
{
  if ([column.identifier isEqualToString:@"include"]) return @([_prefetch containsObject:item]);
  NSString *name = [[item componentsSeparatedByString:@"."] lastObject];
  NSRange dot = [item rangeOfString:@"." options:NSBackwardsSearch];
  NSEntityDescription *owner = [self entityAtPath:dot.location == NSNotFound ? @"" : [item substringToIndex:dot.location]];
  NSRelationshipDescription *rel = owner.relationshipsByName[name];
  return [NSString stringWithFormat:@"%@ → %@%@", name, rel.destinationEntity.name, rel.isToMany ? @" (many)" : @""];
}

- (void)outlineView:(NSOutlineView *)outline setObjectValue:(id)value forTableColumn:(NSTableColumn *)column byItem:(id)item
{
  if (![column.identifier isEqualToString:@"include"]) return;
  if ([value boolValue]) {
    [_prefetch addObject:item];
  } else {
    // Its nested prefetches go with it.
    for (NSString *path in [_prefetch allObjects]) {
      if ([path isEqualToString:item] || [path hasPrefix:[item stringByAppendingString:@"."]]) [_prefetch removeObject:path];
    }
  }
  [outline reloadData];
  [self refreshTranslation];
}

- (BOOL)outlineView:(NSOutlineView *)outline shouldEditTableColumn:(NSTableColumn *)column item:(id)item
{
  return [column.identifier isEqualToString:@"include"];
}

- (BOOL)tableView:(NSTableView *)table shouldEditTableColumn:(NSTableColumn *)column row:(NSInteger)row
{
  if (table == _logTable) return NO;
  if (table == _selectTable) return [column.identifier isEqualToString:@"include"];
  return YES;
}

#pragma mark - Writing

// What a new object is given, so Core Data lets it be saved: each required
// attribute without a default gets an empty value of its type (an
// enumeration its first member). Relationships are left to you.
- (void)fillRequiredValuesOf:(NSManagedObject *)object
{
  for (NSAttributeDescription *attr in object.entity.attributesByName.allValues) {
    if (attr.isOptional || attr.defaultValue || [object valueForKey:attr.name]) continue;
    id value = nil;
    switch (attr.attributeType) {
      case NSStringAttributeType: {
        NSString *type = attr.userInfo[ODataUserInfoType];
        ODataSchemaEnumType *enumeration = [type isKindOfClass:[NSString class]] ? [_store.schema enumTypeNamed:type] : nil;
        value = enumeration.memberNames.firstObject ?: @"";
        break;
      }
      case NSInteger16AttributeType:
      case NSInteger32AttributeType:
      case NSInteger64AttributeType:
      case NSDoubleAttributeType:
      case NSFloatAttributeType: value = @0; break;
      case NSDecimalAttributeType: value = [NSDecimalNumber zero]; break;
      case NSBooleanAttributeType: value = @NO; break;
      case NSDateAttributeType: value = [NSDate date]; break;
      case NSBinaryDataAttributeType: value = [NSData data]; break;
      default:
        if (attr.attributeType == NSUUIDAttributeType) value = [NSUUID UUID];
        else if ([attr.attributeValueClassName isEqualToString:@"NSArray"]) value = @[];
        else if ([attr.attributeValueClassName isEqualToString:@"NSDictionary"]) value = @{};
        break;
    }
    if (value) [object setValue:value forKey:attr.name];
  }
}

// The changes waiting for Save, in the status line and the buttons.
- (NSUInteger)pendingCount
{
  return _context.insertedObjects.count + _context.updatedObjects.count + _context.deletedObjects.count;
}

- (void)showPending
{
  NSUInteger pending = [self pendingCount];
  self.saveButton.enabled = pending > 0;
  self.revertButton.enabled = pending > 0;
  if (!pending) return;
  self.statusField.stringValue = [NSString stringWithFormat:@"Unsaved: %lu new, %lu changed, %lu deleted. Save sends them; Revert drops them.",
                                  (unsigned long)_context.insertedObjects.count, (unsigned long)_context.updatedObjects.count,
                                  (unsigned long)_context.deletedObjects.count];
}

- (IBAction)insertObject:(id)sender
{
  (void)sender;
  NSEntityDescription *entity = [self currentEntity];
  if (!_context || !entity) return;
  if (entity.isAbstract) {
    self.statusField.stringValue = [NSString stringWithFormat:@"%@ is abstract: choose one of its sub-entities.", entity.name];
    return;
  }
  if ([self currentResultType] != NSManagedObjectResultType) {
    [self.resultTypePopup selectItemWithTitle:@"objects"];
    _rows = @[];
    [self rebuildColumns];
  }
  NSManagedObject *object = [NSEntityDescription insertNewObjectForEntityForName:entity.name inManagedObjectContext:_context];
  [self fillRequiredValuesOf:object];
  _rows = [@[ object ] arrayByAddingObjectsFromArray:_rows];
  [self.tableView reloadData];
  [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  [self inspectSelection];
  [self showPending];
}

- (IBAction)deleteSelected:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self selectedObject];
  if (!object) return;
  [_context deleteObject:object];
  NSMutableArray *rows = [_rows mutableCopy];
  [rows removeObject:object];
  _rows = rows;
  [self.tableView reloadData];
  [self inspectSelection];
  [self showPending];
}

- (IBAction)saveChanges:(id)sender
{
  (void)sender;
  if (![self pendingCount]) {
    self.statusField.stringValue = @"Nothing to save.";
    return;
  }
  NSUInteger inserted = _context.insertedObjects.count, updated = _context.updatedObjects.count, deleted = _context.deletedObjects.count;
  NSError *error = nil;
  if (![_context save:&error]) {
    // The changes stay, to be put right or reverted.
    NSArray *details = error.userInfo[NSDetailedErrorsKey];
    NSString *why = details.count ? [[details valueForKey:@"localizedDescription"] componentsJoinedByString:@"; "] : error.localizedDescription;
    self.statusField.stringValue = [NSString stringWithFormat:@"Could not save: %@", why ?: @"unknown error"];
    return;
  }
  [self runFetch:nil];
  self.statusField.stringValue = [NSString stringWithFormat:@"Saved: %lu inserted (POST), %lu updated (PATCH), %lu deleted (DELETE).",
                                  (unsigned long)inserted, (unsigned long)updated, (unsigned long)deleted];
  [self showPending];
}

- (IBAction)revertChanges:(id)sender
{
  (void)sender;
  [_context rollback];
  [self runFetch:nil];
  self.statusField.stringValue = @"Reverted: the unsaved changes are gone.";
  [self showPending];
}

#pragma mark - Actions and functions

static NSString *WBSignature(ODataSchemaOperation *operation)
{
  NSArray *names = [operation.callerParameters valueForKey:@"name"];
  return [NSString stringWithFormat:@"%@(%@)%@", operation.name, [names componentsJoinedByString:@", "],
                                    operation.isAction ? @"" : @" — function"];
}

// What can be called now: the selected object's methods, its entity's
// class methods, and the service's own operations.
- (void)rebuildOperations
{
  [self.operationPopup removeAllItems];
  ODataSchema *schema = _store.schema;
  NSManagedObject *object = [self selectedObject];
  ODataPropertyMapper *mapper = [[ODataPropertyMapper alloc] init];
  mapper.schema = schema;
  NSMutableArray *items = [NSMutableArray array];
  if (object) {
    ODataSchemaEntityType *type = [mapper entityTypeForEntity:object.entity];
    for (ODataSchemaOperation *operation in type ? [schema operationsBoundToEntityType:type collection:NO] : @[]) {
      [items addObject:@[ [NSString stringWithFormat:@"%@.%@", [self titleOf:object], WBSignature(operation)],
                          @{ @"kind": @"object", @"name": operation.qualifiedName } ]];
    }
  }
  NSEntityDescription *entity = [self currentEntity];
  ODataSchemaEntityType *entityType = entity ? [mapper entityTypeForEntity:entity] : nil;
  for (ODataSchemaOperation *operation in entityType ? [schema operationsBoundToEntityType:entityType collection:YES] : @[]) {
    [items addObject:@[ [NSString stringWithFormat:@"%@ (all).%@", entity.name, WBSignature(operation)],
                        @{ @"kind": @"entity", @"name": operation.qualifiedName, @"entity": entity.name } ]];
  }
  for (NSString *name in [schema.operationImports.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    ODataSchemaOperation *operation = [schema operationNamed:name boundToEntityType:nil collection:NO parameterNames:nil];
    if (!operation) continue;
    [items addObject:@[ [NSString stringWithFormat:@"service.%@", WBSignature(operation)], @{ @"kind": @"service", @"name": name } ]];
  }
  if (!items.count) {
    [self.operationPopup addItemWithTitle:object ? @"(no operations)" : @"(select a row for its operations)"];
    return;
  }
  for (NSArray *item in items) {
    [self.operationPopup addItemWithTitle:item[0]];
    self.operationPopup.lastItem.representedObject = item[1];
  }
}

// name=value, name=value: numbers as numbers, true and false, 'quoted'
// or bare text as strings. Each is written as its parameter's type says.
- (NSDictionary *)parsedParameters
{
  NSString *text = self.operationParametersField.stringValue;
  NSMutableDictionary *parameters = [NSMutableDictionary dictionary];
  NSString *separator = [text rangeOfString:@";"].location != NSNotFound ? @";" : @",";
  NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
  for (NSString *pair in [text componentsSeparatedByString:separator]) {
    NSRange equals = [pair rangeOfString:@"="];
    if (equals.location == NSNotFound) continue;
    NSString *name = [[pair substringToIndex:equals.location] stringByTrimmingCharactersInSet:space];
    NSString *raw = [[pair substringFromIndex:NSMaxRange(equals)] stringByTrimmingCharactersInSet:space];
    if (!name.length) continue;
    id value = raw;
    if (raw.length >= 2 && ([raw hasPrefix:@"'"] || [raw hasPrefix:@"\""])) {
      value = [raw substringWithRange:NSMakeRange(1, raw.length - 2)];
    } else if ([raw isEqualToString:@"true"] || [raw isEqualToString:@"false"]) {
      value = @([raw isEqualToString:@"true"]);
    } else {
      NSScanner *scanner = [NSScanner scannerWithString:raw];
      double number;
      if ([scanner scanDouble:&number] && scanner.isAtEnd) value = [raw rangeOfString:@"."].location == NSNotFound ? @((long long)number) : @(number);
    }
    parameters[name] = value;
  }
  return parameters;
}

- (IBAction)invokeOperation:(id)sender
{
  (void)sender;
  NSDictionary *what = self.operationPopup.selectedItem.representedObject;
  if (!what || !_context) {
    self.statusField.stringValue = @"Choose an operation.";
    return;
  }
  ODataOperationCall *call;
  if ([what[@"kind"] isEqual:@"object"]) {
    NSManagedObject *object = [self selectedObject];
    if (!object) return;
    call = [ODataOperationCall callOfOperation:what[@"name"] onObject:object];
  } else if ([what[@"kind"] isEqual:@"entity"]) {
    call = [ODataOperationCall callOfOperation:what[@"name"] onEntity:what[@"entity"] inContext:_context];
  } else {
    call = [ODataOperationCall callOfOperation:what[@"name"] inContext:_context];
  }
  call.parameters = [self parsedParameters];
  NSError *error = nil;
  id result = [call invoke:&error];
  if (!result) {
    self.statusField.stringValue = [NSString stringWithFormat:@"%@: %@", what[@"name"], error.localizedDescription ?: @"failed"];
    return;
  }
  NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@\n\n", call.operation.isAction ? @"Action" : @"Function",
                                                            call.operation.qualifiedName];
  if (result == [NSNull null]) {
    [text appendString:@"(returned nothing)\n"];
  } else if ([result isKindOfClass:[NSManagedObject class]]) {
    [text appendString:[self describe:result]];
  } else if ([result isKindOfClass:[NSArray class]] && [[result firstObject] isKindOfClass:[NSManagedObject class]]) {
    [text appendFormat:@"%lu objects\n", (unsigned long)[result count]];
    for (NSManagedObject *m in result) [text appendFormat:@"  • %@ %@\n", m.entity.name, [self titleOf:m]];
  } else {
    [text appendFormat:@"%@\n", WBCellValue(result)];
  }
  [self show:text in:self.inspectorView];
  self.statusField.stringValue = [NSString stringWithFormat:@"%@ %@", call.operation.isAction ? @"POST" : @"GET", call.operation.name];
}

#pragma mark - Changes at the service

- (IBAction)fetchRemoteChanges:(id)sender
{
  (void)sender;
  if (!_store) return;
  NSError *error = nil;
  NSNotification *changes = [_store fetchRemoteChanges:&error];
  if (!changes) {
    self.statusField.stringValue = error.localizedDescription ?: @"could not read the changes";
    return;
  }
  NSDictionary *info = changes.userInfo;
  if (!info.count) {
    self.statusField.stringValue = @"No changes since the last look (the first look starts tracking; write with another client, then look again).";
    return;
  }
  [_context mergeChangesFromContextDidSaveNotification:changes];
  self.statusField.stringValue = [NSString stringWithFormat:@"Changes at the service: %lu inserted, %lu updated, %lu deleted (a history transaction).",
                                  (unsigned long)[info[NSInsertedObjectIDsKey] count], (unsigned long)[info[NSUpdatedObjectIDsKey] count],
                                  (unsigned long)[info[NSDeletedObjectIDsKey] count]];
  [self runFetch:nil];
}

#pragma mark - Self-test

// Workbench --self-test: the window driven as a person would drive it,
// against each service in turn; a line per check, and the exit status the
// number of failures. With WORKBENCH_SHOTS set, a PNG of the window per
// service goes there.
- (void)waitWhileConnecting
{
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:120];
  while (_connecting && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  // Let the log's queued reports arrive.
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
}

- (void)shoot:(NSString *)name
{
  [self shoot:name window:self.window];
}

- (void)shoot:(NSString *)name window:(NSWindow *)window
{
  NSString *directory = [NSProcessInfo processInfo].environment[@"WORKBENCH_SHOTS"];
  if (!directory.length) return;
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
#if defined(__APPLE__)
  // Light, so dark mode's white labels do not vanish on the PDF's white.
  window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
#endif
  NSView *view = window.contentView;
  [view display];
  // As a PDF: a bitmap cache of the view leaves some controls blank.
  NSData *pdf = [view dataWithPDFInsideRect:view.bounds];
  [pdf writeToFile:[directory stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"pdf"]] atomically:YES];
}

static int WBChecks, WBFailures;

static void WBCheck(BOOL ok, NSString *what, NSString *detail)
{
  WBChecks++;
  if (!ok) WBFailures++;
  fprintf(stderr, "%s  %s%s%s\n", ok ? "PASS" : "FAIL", what.UTF8String, detail.length ? " — " : "", detail.UTF8String ?: "");
}

- (void)editColumn:(NSString *)identifier row:(NSUInteger)row value:(id)value
{
  NSUInteger column = [[self.tableView.tableColumns valueForKey:@"identifier"] indexOfObject:identifier];
  if (row == NSNotFound || column == NSNotFound) return;
  [self tableView:self.tableView setObjectValue:value forTableColumn:self.tableView.tableColumns[column] row:(NSInteger)row];
}

// Insert, fill in, Save (a POST); find it; Delete, Save (a DELETE); gone.
- (void)checkInsertAndDeleteWithKey:(NSString *)key value:(NSString *)value fields:(NSDictionary *)fields
{
  NSString *entity = [self currentEntityName];
  [self insertObject:nil];
  [self editColumn:key row:0 value:value];
  for (NSString *field in fields) [self editColumn:field row:0 value:fields[field]];
  [self saveChanges:nil];
  WBCheck([self.statusField.stringValue hasPrefix:@"Saved: 1 inserted (POST)"], [NSString stringWithFormat:@"Insert a %@, Save (POST)", entity],
          self.statusField.stringValue);
  NSUInteger found = [[_rows valueForKey:key] indexOfObject:value];
  WBCheck(found != NSNotFound, [NSString stringWithFormat:@"the new %@ is read back", entity], self.statusField.stringValue);
  if (found == NSNotFound) return;
  [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:found] byExtendingSelection:NO];
  [self deleteSelected:nil];
  [self saveChanges:nil];
  WBCheck([self.statusField.stringValue hasPrefix:@"Saved: 0 inserted (POST), 0 updated (PATCH), 1 deleted"] &&
          [[_rows valueForKey:key] indexOfObject:value] == NSNotFound,
          [NSString stringWithFormat:@"Delete it, Save (DELETE)"], self.statusField.stringValue);
}

// The panel, clicked as a person would: two relationships prefetched, one
// nested; a second sort key through a relationship; two properties for a
// dictionary result.
- (void)checkQueryPanel
{
  [self.entityPopup selectItemWithTitle:@"Product"];
  [self entityChanged:nil];
  NSTableColumn *include = [_expandOutline tableColumnWithIdentifier:@"include"];
  for (NSString *path in @[ @"category", @"suppliers", @"suppliers.products" ]) {
    [self outlineView:_expandOutline setObjectValue:@YES forTableColumn:include byItem:[self itemForPath:path]];
  }
  [self addSort:nil];
  [self setQueryValue:@"category.name" in:_sortTable column:[_sortTable tableColumnWithIdentifier:@"key"] row:(NSInteger)_sorts.count - 1];
  [self setQueryValue:@YES in:_sortTable column:[_sortTable tableColumnWithIdentifier:@"descending"] row:(NSInteger)_sorts.count - 1];
  [self runFetch:nil];
  NSString *wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  WBCheck(!_lastError && _rows.count && [wire rangeOfString:@"$expand=Category,Suppliers($expand=Products)"].location != NSNotFound &&
          [wire rangeOfString:@"$orderby=ProductID,Category/CategoryName desc"].location != NSNotFound,
          @"the query panel: nested prefetch, two sort keys", _lastError ?: wire);

  [self.resultTypePopup selectItemWithTitle:@"dictionary"];
  NSTableColumn *property = [_selectTable tableColumnWithIdentifier:@"include"];
  NSArray *names = [self attributeNames];
  for (NSString *name in @[ @"name", @"unitPrice" ]) {
    [self setQueryValue:@YES in:_selectTable column:property row:(NSInteger)[names indexOfObject:name]];
  }
  [self runFetch:nil];
  wire = [self.wireURLField.stringValue stringByRemovingPercentEncoding];
  WBCheck(!_lastError && _rows.count && [wire rangeOfString:@"$select=ProductName,UnitPrice"].location != NSNotFound &&
          [[_rows.firstObject allKeys] count] == 2,
          @"the query panel: $select from the checklist", _lastError ?: wire);
  [self.resultTypePopup selectItemWithTitle:@"objects"];
}

// The wire log lists the exchanges; choosing one shows it whole: the
// $metadata request, and its answer to the last byte.
- (void)checkExchangeLog
{
  [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
  NSUInteger metadata = NSNotFound;
  for (NSUInteger i = 0; i < _log.count; i++) {
    WorkbenchLogEntry *logged = _log[i];
    if ([logged.URL hasSuffix:@"$metadata"]) metadata = i;
  }
  WorkbenchLogEntry *entry = metadata != NSNotFound ? _log[metadata] : nil;
  if (entry) [_logTable selectRowIndexes:[NSIndexSet indexSetWithIndex:metadata] byExtendingSelection:NO];
  NSString *response = _responseView.string;
  NSString *body = [[NSString alloc] initWithData:entry.responseData ?: [NSData data] encoding:NSUTF8StringEncoding];
  WBCheck(entry && _exchangeWindow.isVisible && [_requestView.string hasPrefix:@"GET "] &&
          [_requestView.string rangeOfString:@"OData-MaxVersion: 4.01"].location != NSNotFound &&
          [response hasPrefix:@"HTTP/1.1 200"] && body.length > 1000 && [response hasSuffix:body] &&
          [response rangeOfString:@"</edmx:Edmx>"].location != NSNotFound,
          @"the wire log: an exchange, whole", [NSString stringWithFormat:@"%lu exchanges; $metadata answered with %lu bytes, shown %lu characters",
                                                 (unsigned long)_log.count, (unsigned long)entry.responseData.length, (unsigned long)response.length]);
  if ([entry.URL hasPrefix:@"https://services.odata.org/V4/Northwind"]) [self shoot:@"Exchange" window:_exchangeWindow];
  [_exchangeWindow orderOut:nil];
}

// The text views grow with their text, so there is something to scroll.
- (void)checkScrolling
{
  NSMutableString *long_ = [NSMutableString string];
  for (int i = 0; i < 200; i++) [long_ appendFormat:@"line %d\n", i];
  for (NSTextView *view in @[ self.inspectorView ]) {
    NSString *before = view.string;
    [self show:long_ in:view];
    NSScrollView *scrollView = view.enclosingScrollView;
    BOOL grew = view.frame.size.height > scrollView.contentSize.height;
    NSScroller *scroller = scrollView.verticalScroller;
    WBCheck(grew && scrollView.hasVerticalScroller && !scroller.isHidden && scroller.superview == scrollView,
            @"the inspector scrolls",
            [NSString stringWithFormat:@"text %.0f high in a view %.0f high", view.frame.size.height, scrollView.contentSize.height]);
    [self show:before in:view];
  }
}

- (BOOL)selectOperationContaining:(NSString *)text
{
  for (NSMenuItem *item in self.operationPopup.itemArray) {
    if ([item.title rangeOfString:text].location == NSNotFound) continue;
    [self.operationPopup selectItem:item];
    return YES;
  }
  return NO;
}

- (void)runSelfTest
{
  NSArray *names = @[ @"Built-in", @"Northwind", @"TripPin" ];
  for (NSInteger service = WBServiceBuiltIn; service <= WBServiceTripPin; service++) {
    fprintf(stderr, "== %s\n", [names[(NSUInteger)service] UTF8String]);
    [self.servicePopup selectItemAtIndex:service];
    [self serviceChanged:self.servicePopup];
    [self waitWhileConnecting];
    WBCheck(_store != nil, @"connect", self.statusField.stringValue);
    if (!_store) continue;
    WBCheck(_store.schema != nil && !_store.metadataProblems.count, @"$metadata read, and the model agrees with it",
            [_store.metadataProblems componentsJoinedByString:@"; "]);
    [self checkExchangeLog];
    for (NSUInteger i = 0; i < _presets.count; i++) {
      [self.presetsPopup selectItemAtIndex:(NSInteger)i];
      [self applyPreset:self.presetsPopup];
      [self runFetch:nil];
      NSString *label = _presets[i][@"label"];
      BOOL counted = ![_presets[i][@"type"] isEqual:@"count"] || [_rows.firstObject integerValue] > 0;
      WBCheck(!_lastError && _rows.count > 0 && counted, [NSString stringWithFormat:@"preset \"%@\"", label],
              _lastError ?: [NSString stringWithFormat:@"%@  %@", self.statusField.stringValue, self.wireURLField.stringValue]);
      if (i == 0) [self shoot:names[(NSUInteger)service]];
    }
    if (service == WBServiceBuiltIn) {
      [self.presetsPopup selectItemAtIndex:0];
      [self applyPreset:self.presetsPopup];
      [self runFetch:nil];
      [self checkInsertAndDeleteWithKey:@"name" value:@"Workbench Blend" fields:@{ @"quantityPerUnit": @"12 bags", @"unitPrice": @"9.5" }];
      NSString *first = [_rows.firstObject valueForKey:@"name"];
      [self editColumn:@"name" row:0 value:@"Changed my mind"];
      [self revertChanges:nil];
      WBCheck([[_rows.firstObject valueForKey:@"name"] isEqual:first] && ![self pendingCount], @"Revert drops an edit",
              self.statusField.stringValue);
      [self checkScrolling];
      [self checkQueryPanel];
    }
    if (service != WBServiceTripPin) continue;

    // TripPin: an instance function, a service function, an edit, the changes.
    [self.presetsPopup selectItemAtIndex:0];
    [self applyPreset:self.presetsPopup];
    [self runFetch:nil];
    NSUInteger russell = [[_rows valueForKey:@"userName"] indexOfObject:@"russellwhyte"];
    if (russell != NSNotFound) {
      [self.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:russell] byExtendingSelection:NO];
      [self rebuildOperations];
    }
    BOOL found = [self selectOperationContaining:@"GetFavoriteAirline"];
    if (found) [self invokeOperation:nil];
    WBCheck(found && [self.inspectorView.string rangeOfString:@"American Airlines"].location != NSNotFound,
            @"an instance function: russellwhyte.GetFavoriteAirline()", found ? self.statusField.stringValue : @"not in the operations menu");
    found = [self selectOperationContaining:@"GetNearestAirport"];
    self.operationParametersField.stringValue = @"lat=33.94, lon=-118.4";
    if (found) [self invokeOperation:nil];
    WBCheck(found && [self.inspectorView.string rangeOfString:@"KLAX"].location != NSNotFound,
            @"a service function with parameters: GetNearestAirport(lat, lon)", found ? self.statusField.stringValue : @"not in the operations menu");
    [self shoot:@"TripPin-operation"];

    [self editColumn:@"firstName" row:russell value:@"Rusty"];
    WBCheck([self.statusField.stringValue hasPrefix:@"Unsaved: 0 new, 1 changed"], @"an edit waits for Save", self.statusField.stringValue);
    [self saveChanges:nil];
    WBCheck([self.statusField.stringValue hasPrefix:@"Saved: 0 inserted (POST), 1 updated"], @"Save sends it (PATCH)", self.statusField.stringValue);
    [self checkInsertAndDeleteWithKey:@"userName" value:@"oiswbnew" fields:@{ @"firstName": @"New", @"lastName": @"Person" }];

    [self fetchRemoteChanges:nil];
    WBCheck([self.statusField.stringValue hasPrefix:@"No changes"], @"start tracking the service's changes", self.statusField.stringValue);
    [self fetchRemoteChanges:nil];
    WBCheck(![self.statusField.stringValue hasPrefix:@"Could"] && self.statusField.stringValue.length, @"look again for changes",
            self.statusField.stringValue);
  }
  fprintf(stderr, "%s: %d checks, %d failed\n", WBFailures ? "Workbench self-test: FAILED" : "Workbench self-test: passed", WBChecks, WBFailures);
  exit(WBFailures ? 1 : 0);
}

- (void)dealloc
{
  _engine.didHandle = nil;
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
