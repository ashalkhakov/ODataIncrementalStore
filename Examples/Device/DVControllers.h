// The Device app's screens, made in code: what the Workbench's Sync window
// shows, a tab each.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <UIKit/UIKit.h>
#import "DVSession.h"

NS_ASSUME_NONNULL_BEGIN

// A list over the session: read again whenever the device changes, with
// what happened last above its title.
@interface DVTableController : UITableViewController
- (instancetype)initWithSession:(DVSession *)session style:(UITableViewStyle)style NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewStyle)style NS_UNAVAILABLE;
- (instancetype)initWithNibName:(nullable NSString *)name bundle:(nullable NSBundle *)bundle NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;
@property (nonatomic, readonly) DVSession *session;
// Read the device again (subclasses; the default reloads the table).
- (void)reload;
@end

// The device's objects, an entity at a time: which way it goes, its rows;
// Sync (pull, or the button's menu: Download, Upload, Reconcile); New,
// Delete (a swipe), and a row's values, edited.
@interface DVDataController : DVTableController
@end

// One object's values; the editable ones are changed by a tap.
@interface DVObjectController : DVTableController
- (instancetype)initWithSession:(DVSession *)session object:(NSManagedObjectID *)objectID entity:(NSString *)entity;
@end

typedef NS_ENUM(NSInteger, DVListKind) {
  DVListWaiting = 0,   // changes waiting to be sent; a set-aside one retried or discarded
  DVListConflicts,     // conflicts met, and how each was settled
  DVListRequests,      // the device's exchanges, newest first
};

@interface DVListController : DVTableController
- (instancetype)initWithSession:(DVSession *)session kind:(DVListKind)kind;
@end

// Text to read: a conflict's three versions, an exchange.
@interface DVTextController : UIViewController
- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text;
@end

// The Workbench's address, the conflict rule, the line, a new device.
@interface DVSettingsController : DVTableController <UITextFieldDelegate>
@end

NS_ASSUME_NONNULL_END
