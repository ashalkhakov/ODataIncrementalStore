// Quick start: Core Data over a remote OData service, with no model of
// your own: the store builds one from the service's $metadata.
//
//   macOS:   clang -fobjc-arc -F <frameworks> -framework ODataIncrementalStore
//            -framework ODataKit -framework CoreData -framework Foundation northwind.m
//   GNUstep: clang $(gnustep-config --objc-flags) -fobjc-arc -fblocks northwind.m
//            -lODataIncrementalStore -lODataKit -lCoreData $(gnustep-config --base-libs)
#import <ODataIncrementalStore/ODataIncrementalStore.h>

int main(void)
{
  @autoreleasepool {
    [ODataIncrementalStore registerStore];
    NSURL *url = [NSURL URLWithString:@"https://services.odata.org/V4/Northwind/Northwind.svc/"];
    NSError *error = nil;

    NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:url options:nil error:&error];
    NSPersistentStoreCoordinator *coordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
    if (![coordinator addPersistentStoreWithType:[ODataIncrementalStore storeType] configuration:nil
                                              URL:url options:nil error:&error]) {
      NSLog(@"%@", error);
      return 1;
    }
    NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
    context.persistentStoreCoordinator = coordinator;

    [context performBlockAndWait:^{
      // GET Products?$filter=UnitPrice gt 50&$orderby=UnitPrice desc,ProductID&$expand=Category
      NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
      fetch.predicate = [NSPredicate predicateWithFormat:@"unitPrice > 50"];
      fetch.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"unitPrice" ascending:NO] ];
      fetch.relationshipKeyPathsForPrefetching = @[ @"category" ];
      NSError *fetchError = nil;
      for (NSManagedObject *product in [context executeFetchRequest:fetch error:&fetchError]) {
        printf("%-28s %8s  %s\n", [[product valueForKey:@"productName"] UTF8String],
               [[[product valueForKey:@"unitPrice"] description] UTF8String],
               [[product valueForKeyPath:@"category.categoryName"] UTF8String]);
      }
      if (fetchError) NSLog(@"%@", fetchError);
    }];
  }
  return 0;
}
