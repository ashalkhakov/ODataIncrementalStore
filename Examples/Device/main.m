// The Device app: the Workbench's Sync window on an iPhone, for ODataSync
// on a real device. It syncs over the network with a Workbench that serves
// its built-in service (Sync > Serve on the Network).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import <UIKit/UIKit.h>
#import "DVControllers.h"

static NSString * const DVTabKey = @"DVTab";

@interface DVAppDelegate : UIResponder <UIApplicationDelegate, UITabBarControllerDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) DVSession *session;
@end

@implementation DVAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options
{
  _session = [[DVSession alloc] init];
  NSArray<UIViewController *> *screens = @[
    [[DVDataController alloc] initWithSession:_session style:UITableViewStylePlain],
    [[DVListController alloc] initWithSession:_session kind:DVListWaiting],
    [[DVListController alloc] initWithSession:_session kind:DVListConflicts],
    [[DVListController alloc] initWithSession:_session kind:DVListRequests],
    [[DVSettingsController alloc] initWithSession:_session style:UITableViewStyleInsetGrouped] ];
  NSMutableArray *tabs = [NSMutableArray array];
  for (UIViewController *screen in screens) {
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:screen];
    navigation.tabBarItem = screen.tabBarItem;
    navigation.tabBarItem.title = screen.title;
    [tabs addObject:navigation];
  }
  UITabBarController *tabBar = [[UITabBarController alloc] init];
  tabBar.viewControllers = tabs;
  tabBar.delegate = self;
  // The tab last shown; with no Workbench yet, its address.
  NSInteger tab = [[NSUserDefaults standardUserDefaults] integerForKey:DVTabKey];
  tabBar.selectedIndex = _session.device ? (NSUInteger)MAX(0, MIN(tab, (NSInteger)tabs.count - 1)) : tabs.count - 1;
  _window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  _window.rootViewController = tabBar;
  [_window makeKeyAndVisible];
  return YES;
}

- (void)tabBarController:(UITabBarController *)tabBar didSelectViewController:(UIViewController *)controller
{
  [[NSUserDefaults standardUserDefaults] setInteger:(NSInteger)tabBar.selectedIndex forKey:DVTabKey];
}

// Opened, or back: the Workbench's changes met, what waits sent.
- (void)applicationDidBecomeActive:(UIApplication *)application
{
  WorkbenchDevice *device = _session.device;
  if (device && !device.offline && !device.busy) [device run:WBSyncActionSync];
}

@end

int main(int argc, char *argv[])
{
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([DVAppDelegate class]));
  }
}
