// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "DVControllers.h"
#import "WorkbenchSupport.h"

static NSString * const DVCell = @"cell";
static NSString * const DVEntityKey = @"DVEntity";

// A value as a row shows it: an object by its title, nothing as a dash.
static NSString *DVValueText(id value)
{
  if (!value || value == [NSNull null]) return @"–";
  if ([value isKindOfClass:[NSManagedObject class]]) return WBTitleOf(value, YES);
  return [WBCellValue(value) description];
}

static void DVAlert(UIViewController *controller, NSString *title, NSString *message)
{
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Lists over the session

// What happened last, in the navigation bar's prompt line: a toolbar
// would sit under the tab bar.
@implementation DVTableController

- (instancetype)initWithSession:(DVSession *)session style:(UITableViewStyle)style
{
  self = [super initWithStyle:style];
  if (!self) return nil;
  _session = session;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionChanged:) name:DVSessionDidChangeNotification object:session];
  return self;
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:DVCell];
}

- (void)viewWillAppear:(BOOL)animated
{
  [super viewWillAppear:animated];
  self.navigationItem.prompt = self.session.status;
  [self reload];
}

- (void)sessionChanged:(NSNotification *)notification
{
  [self updateBadge];
  if (!self.isViewLoaded) return;
  self.navigationItem.prompt = notification.userInfo[@"status"];
  [self reload];
}

- (void)updateBadge
{
}

- (void)reload
{
  [self.tableView reloadData];
}

@end

#pragma mark - The device's objects

@implementation DVDataController {
  NSString *_entity;
  NSArray<NSManagedObject *> *_objects;
  NSArray<NSString *> *_columns;
  UILabel *_rulesLabel;
  UIBarButtonItem *_entityItem;
  UIBarButtonItem *_addItem;
}

- (instancetype)initWithSession:(DVSession *)session style:(UITableViewStyle)style
{
  self = [super initWithSession:session style:style];
  if (!self) return nil;
  _entity = [[NSUserDefaults standardUserDefaults] stringForKey:DVEntityKey];
  if (![[WorkbenchDevice entityNames] containsObject:_entity]) _entity = @"Product";
  _objects = @[];
  self.title = @"Data";
  self.tabBarItem.image = [UIImage systemImageNamed:@"tablecells"];
  return self;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  __weak DVDataController *weak = self;
  UIMenu *more = [UIMenu menuWithTitle:@"" children:@[
    [UIAction actionWithTitle:@"Sync" image:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath"] identifier:nil handler:^(UIAction *action) {
      [weak run:WBSyncActionSync];
    }],
    [UIAction actionWithTitle:@"Download" image:[UIImage systemImageNamed:@"arrow.down"] identifier:nil handler:^(UIAction *action) {
      [weak run:WBSyncActionDownload];
    }],
    [UIAction actionWithTitle:@"Upload" image:[UIImage systemImageNamed:@"arrow.up"] identifier:nil handler:^(UIAction *action) {
      [weak run:WBSyncActionUpload];
    }],
    [UIAction actionWithTitle:@"Reconcile" image:[UIImage systemImageNamed:@"checklist"] identifier:nil handler:^(UIAction *action) {
      [weak run:WBSyncActionReconcile];
    }] ]];
  // A tap syncs; a long press offers the halves.
  UIAction *sync = [UIAction actionWithTitle:@"Sync" image:nil identifier:nil handler:^(UIAction *action) {
    [weak run:WBSyncActionSync];
  }];
  UIBarButtonItem *syncItem = [[UIBarButtonItem alloc] initWithPrimaryAction:sync];
  syncItem.menu = more;
  _addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(newObject:)];
  self.navigationItem.rightBarButtonItems = @[ syncItem, _addItem ];
  _entityItem = [[UIBarButtonItem alloc] initWithTitle:_entity menu:nil];
  self.navigationItem.leftBarButtonItem = _entityItem;
  self.refreshControl = [[UIRefreshControl alloc] init];
  [self.refreshControl addTarget:self action:@selector(pulled:) forControlEvents:UIControlEventValueChanged];
  _rulesLabel = [[UILabel alloc] init];
  _rulesLabel.numberOfLines = 0;
  _rulesLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
  _rulesLabel.textColor = UIColor.secondaryLabelColor;
}

// Which way the entity goes, above its rows, as tall as its text.
- (void)viewDidLayoutSubviews
{
  [super viewDidLayoutSubviews];
  CGFloat width = self.tableView.bounds.size.width;
  CGSize size = [_rulesLabel sizeThatFits:CGSizeMake(width - 32, CGFLOAT_MAX)];
  UIView *header = self.tableView.tableHeaderView;
  if (header && fabs(header.frame.size.height - (size.height + 16)) < 1 && fabs(header.frame.size.width - width) < 1) return;
  header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, size.height + 16)];
  _rulesLabel.frame = CGRectMake(16, 8, width - 32, size.height);
  [header addSubview:_rulesLabel];
  self.tableView.tableHeaderView = header;
}

- (void)updateEntityMenu
{
  WorkbenchDevice *device = self.session.device;
  NSMutableArray *choices = [NSMutableArray array];
  __weak DVDataController *weak = self;
  for (NSString *entity in [WorkbenchDevice entityNames]) {
    UIAction *choice = [UIAction actionWithTitle:device ? [device titleOfEntity:entity] : entity image:nil identifier:nil handler:^(UIAction *action) {
      [weak showEntity:entity];
    }];
    choice.state = [entity isEqualToString:_entity] ? UIMenuElementStateOn : UIMenuElementStateOff;
    [choices addObject:choice];
  }
  _entityItem.title = _entity;
  _entityItem.menu = [UIMenu menuWithTitle:@"Entity" children:choices];
}

- (void)showEntity:(NSString *)entity
{
  _entity = entity;
  [[NSUserDefaults standardUserDefaults] setObject:entity forKey:DVEntityKey];
  [self reload];
}

- (void)reload
{
  WorkbenchDevice *device = self.session.device;
  [self updateEntityMenu];
  if (!device.busy) [self.refreshControl endRefreshing];
  if (!device) {
    _objects = @[];
    _columns = @[];
    _rulesLabel.text = @"Set the Workbench's address in Settings: on the Mac, Sync > Serve on the Network shows it.";
    _addItem.enabled = NO;
  } else {
    _objects = [device objectsOfEntity:_entity];
    _columns = [device columnsOfEntity:_entity];
    _rulesLabel.text = [device rulesOfEntity:_entity];
    _addItem.enabled = [device entityIsEditable:_entity];
  }
  [self.view setNeedsLayout];
  [self.tableView reloadData];
}

- (void)run:(WBSyncAction)action
{
  if (![self.session.device run:action]) [self.refreshControl endRefreshing];
}

- (void)pulled:(id)sender
{
  (void)sender;
  if (!self.session.device) {
    [self.refreshControl endRefreshing];
    return;
  }
  [self run:WBSyncActionSync];
}

- (void)newObject:(id)sender
{
  (void)sender;
  [self.session.device newObjectOfEntity:_entity];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  return (NSInteger)_objects.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:DVCell forIndexPath:indexPath];
  NSManagedObject *object = _objects[(NSUInteger)indexPath.row];
  UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
  content.text = WBTitleOf(object, YES);
  // A few of its values: the key, then the others, the bookkeeping last.
  NSMutableArray *parts = [NSMutableArray array];
  for (NSString *column in _columns) {
    if ([column isEqualToString:@"name"] || [column isEqualToString:@"versions"]) continue;
    [parts addObject:[NSString stringWithFormat:@"%@ %@", column, DVValueText([object valueForKey:column])]];
  }
  content.secondaryText = [parts componentsJoinedByString:@" · "];
  content.secondaryTextProperties.numberOfLines = 2;
  content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
  cell.contentConfiguration = content;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
  NSManagedObject *object = _objects[(NSUInteger)indexPath.row];
  [self.navigationController pushViewController:[[DVObjectController alloc] initWithSession:self.session object:object.objectID entity:_entity]
                                       animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
  if (![self.session.device entityIsEditable:_entity]) return nil;
  NSManagedObject *object = _objects[(NSUInteger)indexPath.row];
  __weak DVDataController *weak = self;
  UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete"
                                                                     handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
    [weak.session.device deleteObject:object];
    done(YES);
  }];
  return [UISwipeActionsConfiguration configurationWithActions:@[ delete ]];
}

@end

#pragma mark - One object

@implementation DVObjectController {
  NSManagedObjectID *_objectID;
  NSString *_entity;
  // name, value as text, editable
  NSArray<NSArray *> *_rows;
}

- (instancetype)initWithSession:(DVSession *)session object:(NSManagedObjectID *)objectID entity:(NSString *)entity
{
  self = [super initWithSession:session style:UITableViewStyleInsetGrouped];
  if (!self) return nil;
  _objectID = objectID;
  _entity = [entity copy];
  _rows = @[];
  return self;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  if ([self.session.device entityIsEditable:_entity]) {
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self
                                                                                           action:@selector(deleteObject:)];
  }
}

// Fetched again each time: the list resets the context as it reads.
- (NSManagedObject *)object
{
  return [self.session.device.context existingObjectWithID:_objectID error:NULL];
}

- (void)reload
{
  WorkbenchDevice *device = self.session.device;
  NSManagedObject *object = [self object];
  NSMutableArray *rows = [NSMutableArray array];
  for (NSString *column in object ? [device columnsOfEntity:_entity] : @[]) {
    [rows addObject:@[ column, DVValueText([object valueForKey:column]), @([device column:column isEditableInEntity:_entity]) ]];
  }
  _rows = rows;
  self.title = object ? WBTitleOf(object, YES) : @"Deleted";
  [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  return (NSInteger)_rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
  if (!_rows.count) return @"Not on the device any more.";
  return [self.session.device entityIsEditable:_entity] ? @"Tap a value to change it. The key, the version, the stamp and the history are the "
                                                         @"service's and the sync engine's."
                                                       : [self.session.device rulesOfEntity:_entity];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:DVCell forIndexPath:indexPath];
  NSArray *row = _rows[(NSUInteger)indexPath.row];
  UIListContentConfiguration *content = [UIListContentConfiguration valueCellConfiguration];
  content.text = row[0];
  content.secondaryText = row[1];
  content.secondaryTextProperties.numberOfLines = 3;
  cell.contentConfiguration = content;
  cell.selectionStyle = [row[2] boolValue] ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
  cell.accessoryType = [row[2] boolValue] ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NSArray *row = _rows[(NSUInteger)indexPath.row];
  if (![row[2] boolValue]) return;
  NSString *name = row[0];
  id value = [[self object] valueForKey:name];
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:name message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
    field.text = value ? [value description] : @"";
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
  }];
  __weak DVObjectController *weak = self;
  __weak UIAlertController *weakAlert = alert;
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    NSManagedObject *object = [weak object];
    if (object) [weak.session.device setValue:weakAlert.textFields.firstObject.text ofAttribute:name object:object];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)deleteObject:(id)sender
{
  (void)sender;
  NSManagedObject *object = [self object];
  if (object) [self.session.device deleteObject:object];
  [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - What waits, the conflicts, the requests

@implementation DVListController {
  DVListKind _kind;
  NSArray *_items;
}

- (instancetype)initWithSession:(DVSession *)session kind:(DVListKind)kind
{
  self = [super initWithSession:session style:UITableViewStylePlain];
  if (!self) return nil;
  _kind = kind;
  _items = @[];
  self.title = @[ @"Waiting", @"Conflicts", @"Requests" ][(NSUInteger)kind];
  self.tabBarItem.image = [UIImage systemImageNamed:@[ @"tray.and.arrow.up", @"exclamationmark.triangle", @"network" ][(NSUInteger)kind]];
  if (kind == DVListRequests) {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(logged:) name:DVSessionDidLogNotification object:session];
  }
  return self;
}

- (void)logged:(NSNotification *)notification
{
  if (self.isViewLoaded) [self reload];
}

- (void)updateBadge
{
  if (_kind != DVListWaiting) return;
  NSUInteger count = [self.session.device pendingChanges].count;
  self.navigationController.tabBarItem.badgeValue = count ? [NSString stringWithFormat:@"%lu", (unsigned long)count] : nil;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  [self updateBadge];
}

- (void)reload
{
  WorkbenchDevice *device = self.session.device;
  switch (_kind) {
    case DVListWaiting: _items = [device pendingChanges] ?: @[]; break;
    case DVListConflicts: _items = [device conflicts] ?: @[]; break;
    case DVListRequests: _items = device.requests ?: @[]; break;
  }
  [self updateBadge];
  [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  return (NSInteger)_items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
  if (_items.count) {
    if (_kind == DVListWaiting) return @"Swipe a change set aside to retry it (a conflict's: the device's version over the service's) or discard it.";
    return nil;
  }
  switch (_kind) {
    case DVListWaiting: return @"Nothing waits to be sent.";
    case DVListConflicts: return @"No conflicts yet: change a product here and on the Mac (Change at the Service), then Sync. The rule in Settings settles it.";
    case DVListRequests: return @"No requests yet: Sync.";
  }
  return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:DVCell forIndexPath:indexPath];
  UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
  content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
  content.secondaryTextProperties.numberOfLines = 2;
  cell.accessoryType = UITableViewCellAccessoryNone;
  id item = _items[(NSUInteger)indexPath.row];
  if (_kind == DVListWaiting) {
    ODataSyncChange *change = item;
    content.text = [NSString stringWithFormat:@"%@ %@ · %@", change.entityName, WBKeyText(change.key), WBChangeText(change)];
    NSString *issue = WBIssueText(change);
    content.secondaryText = issue.length ? [NSString stringWithFormat:@"sent %lu · set aside: %@", (unsigned long)change.attempts, issue]
                                         : [NSString stringWithFormat:@"sent %lu", (unsigned long)change.attempts];
  } else if (_kind == DVListConflicts) {
    WBSyncConflict *met = item;
    content.text = [NSString stringWithFormat:@"%@ %@ · %@", met.conflict.entity.name, WBKeyText(met.conflict.key), WBOutcomeName(met.outcome)];
    content.secondaryText = [NSString stringWithFormat:@"%@ · device: %@ · service: %@", WBTimeText(met.date), WBConflictSideText(met, YES),
                                                       WBConflictSideText(met, NO)];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  } else {
    WorkbenchLogEntry *entry = item;
    content.text = [NSString stringWithFormat:@"%@ %@", entry.method, WBRequestPath(entry, self.session.device.serviceRoot)];
    content.textProperties.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    content.textProperties.numberOfLines = 2;
    NSString *outcome = entry.status ? [NSString stringWithFormat:@"%ld", (long)entry.status] : (entry.failure ?: @"no answer");
    content.secondaryText = [NSString stringWithFormat:@"%@ · %@ · %.0f ms", WBTimeText(entry.date), outcome, entry.duration * 1000];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  }
  cell.contentConfiguration = content;
  return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  id item = _items[(NSUInteger)indexPath.row];
  UIViewController *detail = nil;
  if (_kind == DVListConflicts) detail = [[DVTextController alloc] initWithTitle:@"Conflict" text:WBConflictText(item)];
  if (_kind == DVListRequests) detail = [[DVTextController alloc] initWithTitle:[item method] text:WBRequestText(item)];
  if (detail) [self.navigationController pushViewController:detail animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath
{
  if (_kind != DVListWaiting) return nil;
  id item = _items[(NSUInteger)indexPath.row];
  if (![item isKindOfClass:[ODataSyncIssue class]]) return nil;
  ODataSyncIssue *issue = item;
  __weak DVListController *weak = self;
  UIContextualAction *discard = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Discard"
                                                                      handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
    [weak.session.device discardIssue:issue];
    done(YES);
  }];
  UIContextualAction *retry = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Retry"
                                                                    handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
    [weak.session.device retryIssue:issue];
    done(YES);
  }];
  retry.backgroundColor = UIColor.systemBlueColor;
  return [UISwipeActionsConfiguration configurationWithActions:@[ discard, retry ]];
}

@end

#pragma mark - Text

@implementation DVTextController {
  NSString *_text;
}

- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text
{
  self = [super initWithNibName:nil bundle:nil];
  if (!self) return nil;
  self.title = title;
  _text = [text copy];
  return self;
}

- (void)loadView
{
  UITextView *view = [[UITextView alloc] init];
  view.editable = NO;
  view.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
  view.textContainerInset = UIEdgeInsetsMake(12, 8, 12, 8);
  view.alwaysBounceVertical = YES;
  view.text = _text;
  self.view = view;
}

@end

#pragma mark - Settings

typedef NS_ENUM(NSInteger, DVSettingsSection) {
  DVSettingsWorkbench = 0,
  DVSettingsRule,
  DVSettingsLine,
  DVSettingsDevice,
};

@implementation DVSettingsController {
  UITextField *_rootField;
}

- (instancetype)initWithSession:(DVSession *)session style:(UITableViewStyle)style
{
  self = [super initWithSession:session style:style];
  if (!self) return nil;
  self.title = @"Settings";
  self.tabBarItem.image = [UIImage systemImageNamed:@"gear"];
  return self;
}

- (void)viewDidLoad
{
  [super viewDidLoad];
  _rootField = [[UITextField alloc] init];
  _rootField.placeholder = @"http://192.168.1.10:8640/odata/";
  _rootField.keyboardType = UIKeyboardTypeURL;
  _rootField.autocorrectionType = UITextAutocorrectionTypeNo;
  _rootField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  _rootField.returnKeyType = UIReturnKeyGo;
  _rootField.clearButtonMode = UITextFieldViewModeWhileEditing;
  _rootField.delegate = self;
  _rootField.text = self.session.serviceRoot.absoluteString;
}

// Not the address while it is typed: the keyboard stays.
- (void)reload
{
  if (_rootField.isFirstResponder) {
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(DVSettingsRule, 3)] withRowAnimation:UITableViewRowAnimationNone];
    return;
  }
  _rootField.text = self.session.serviceRoot.absoluteString;
  [self.tableView reloadData];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field
{
  NSString *why = [self.session useServiceRoot:field.text];
  if (why) {
    DVAlert(self, @"The Workbench's address", why);
    return NO;
  }
  [field resignFirstResponder];
  [self reload];
  return YES;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView
{
  return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
  switch ((DVSettingsSection)section) {
    case DVSettingsWorkbench: return 1;
    case DVSettingsRule: return (NSInteger)WBSyncRuleTitles().count;
    case DVSettingsLine: return 2;
    case DVSettingsDevice: return 1;
  }
  return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section
{
  return @[ @"The Workbench", @"Conflicts", @"The line", @"The device" ][(NSUInteger)section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section
{
  switch ((DVSettingsSection)section) {
    case DVSettingsWorkbench:
      return @"On the Mac, in the Workbench: Sync > Serve on the Network. Its status line shows the address; the iPhone and the Mac on the "
             @"same network. A new address is a new device: what it holds is read again.";
    case DVSettingsRule: return @"How a change made on both sides is settled. Set aside: it waits under Waiting, to retry or discard.";
    case DVSettingsLine: return @"Offline, changes wait on the device, and go with the first sync back online.";
    case DVSettingsDevice: return @"Empties the device: Sync reads the Workbench's data again. What waits is lost.";
  }
  return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
  switch ((DVSettingsSection)indexPath.section) {
    case DVSettingsWorkbench: {
      _rootField.translatesAutoresizingMaskIntoConstraints = NO;
      [cell.contentView addSubview:_rootField];
      UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
      [NSLayoutConstraint activateConstraints:@[
        [_rootField.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_rootField.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_rootField.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [_rootField.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        [_rootField.heightAnchor constraintGreaterThanOrEqualToConstant:28] ]];
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      return cell;
    }
    case DVSettingsRule:
      content.text = WBSyncRuleTitles()[(NSUInteger)indexPath.row];
      cell.accessoryType = indexPath.row == self.session.rule ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
      break;
    case DVSettingsLine: {
      UISwitch *toggle = [[UISwitch alloc] init];
      BOOL offline = indexPath.row == 0;
      content.text = offline ? @"Offline" : @"Sync each change";
      toggle.on = offline ? self.session.offline : self.session.syncsEachChange;
      [toggle addTarget:self action:offline ? @selector(offlineChanged:) : @selector(syncsEachChangeChanged:) forControlEvents:UIControlEventValueChanged];
      cell.accessoryView = toggle;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      break;
    }
    case DVSettingsDevice:
      content.text = @"Reset Device";
      content.textProperties.color = UIColor.systemRedColor;
      break;
  }
  cell.contentConfiguration = content;
  return cell;
}

- (void)offlineChanged:(UISwitch *)toggle
{
  self.session.offline = toggle.on;
}

- (void)syncsEachChangeChanged:(UISwitch *)toggle
{
  self.session.syncsEachChange = toggle.on;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (indexPath.section == DVSettingsRule) {
    self.session.rule = (WBSyncRule)indexPath.row;
    return;
  }
  if (indexPath.section != DVSettingsDevice) return;
  if (!self.session.device) {
    DVAlert(self, @"No device yet", @"Set the Workbench's address first.");
    return;
  }
  UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Reset the device?"
                                                                   message:@"Its data and what waits to be sent are removed; Sync reads the Workbench's data again."
                                                            preferredStyle:UIAlertControllerStyleAlert];
  [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
  __weak DVSettingsController *weak = self;
  [confirm addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
    [weak.session resetDevice];
  }]];
  [self presentViewController:confirm animated:YES completion:nil];
}

@end
