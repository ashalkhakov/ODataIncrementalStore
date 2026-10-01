// CatalogServer — an application of its own around the Catalog service: a
// route, and a stage, beside what ois-serve does.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
//   catalog-server -Config catalog.plist
//
// Every ois-serve setting works here too (ODataServerApplication.h); this
// adds:
//
//   GET /stats            how many rows each entity set has, for anyone
//                         signed in
//   X-Served-By           on every response, from a stage

#import "ODataService.h"
#import "ODataServer.h"

// GET /stats: a handler is any object that answers a request.
@interface CatalogStatsHandler : NSObject <ODataServerHandler>
@property (nonatomic, strong) ODataService *service;
@end

@implementation CatalogStatsHandler

- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSPrivateQueueConcurrencyType];
  context.persistentStoreCoordinator = self.service.coordinator;
  [context performBlock:^{
    NSMutableDictionary *counts = [NSMutableDictionary dictionary];
    for (NSEntityDescription *entity in self.service.coordinator.managedObjectModel.entities) {
      if (entity.superentity) continue;
      NSFetchRequest *fetch = [NSFetchRequest fetchRequestWithEntityName:entity.name];
      counts[entity.name] = @([context countForFetchRequest:fetch error:NULL]);
    }
    // Finished from the context's queue: a reply may be answered later,
    // from any thread.
    [reply finishWithResponse:[ODataServerResponse responseWithJSON:counts status:200]];
  }];
}

@end

// A stage: an object in the pipeline, here only on the way back.
@interface CatalogServedByStage : ODataServerStage
@end

@implementation CatalogServedByStage

- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response
{
  [response setValue:[NSProcessInfo processInfo].hostName forHeader:@"X-Served-By"];
}

@end

@interface CatalogServer : ODataServerApplication
@end

@implementation CatalogServer

- (void)configureRouter:(ODataServerRouter *)router
{
  CatalogStatsHandler *stats = [[CatalogStatsHandler alloc] init];
  stats.service = self.service;
  ODataServerRoute *route = [ODataServerRoute routeWithMethod:@"GET" path:@"/stats" handler:stats];
  route.requiresPrincipal = self.authenticator != nil;
  // Before the service's mount, which takes everything under its root.
  [router insertRoute:route atIndex:0];
}

- (void)configurePipeline:(ODataServerPipeline *)pipeline
{
  [pipeline insertStage:[[CatalogServedByStage alloc] init] beforeStageOfClass:[ODataAccessLogStage class]];
}

@end

int main(int argc, const char *argv[])
{
  return ODataServerMain(argc, argv, [CatalogServer class]);
}
