// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataServerPipeline.h"
#import "ODataError.h"

// The rest of a pipeline from one stage on: what that stage's next is.
@interface OISPipelineRest : NSObject <ODataServerHandler>
@property (nonatomic, copy) NSArray<ODataServerStage *> *stages;
@property (nonatomic) NSUInteger index;
@property (nonatomic, strong, nullable) id<ODataServerHandler> handler;
@end

@implementation OISPipelineRest

- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  if (self.index < self.stages.count) {
    OISPipelineRest *rest = [[OISPipelineRest alloc] init];
    rest.stages = self.stages;
    rest.index = self.index + 1;
    rest.handler = self.handler;
    [self.stages[self.index] handleRequest:request reply:reply next:rest];
  } else if (self.handler) {
    [self.handler handleRequest:request reply:reply];
  } else {
    [reply failWithError:ODataServiceError(404, @"Nothing answers here")];
  }
}

@end

// A stage's way back: the reply it hands on is finished, so it sees the
// response, then the reply it was handed is.
@interface OISStageReturn : NSObject
@property (nonatomic, strong) ODataServerStage *stage;
@property (nonatomic, strong) ODataServerRequest *request;
@property (nonatomic, strong) ODataServerReply *reply;
@end

@implementation OISStageReturn

- (void)didFinish:(ODataServerReply *)inner
{
  ODataServerResponse *response = inner.response;
  [self.stage request:self.request willSendResponse:response];
  [self.reply finishWithResponse:response];
}

@end

@implementation ODataServerStage

- (BOOL)shouldPassRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  return YES;
}

- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response
{
}

- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply next:(id<ODataServerHandler>)next
{
  OISStageReturn *back = [[OISStageReturn alloc] init];
  back.stage = self;
  back.request = request;
  back.reply = reply;
  ODataServerReply *inner = [[ODataServerReply alloc] initWithTarget:back action:@selector(didFinish:)];
  if ([self shouldPassRequest:request reply:inner]) {
    if (!inner.finished) [next handleRequest:request reply:inner];
  } else if (!inner.finished) {
    [inner failWithError:ODataServiceError(500, [NSString stringWithFormat:@"%@ stopped the request without answering it",
                                                                           NSStringFromClass([self class])])];
  }
}

@end

@implementation ODataServerPipeline

- (instancetype)initWithStages:(NSArray<ODataServerStage *> *)stages handler:(id<ODataServerHandler>)handler
{
  self = [super init];
  if (!self) return nil;
  _stages = [stages copy] ?: @[];
  _handler = handler;
  return self;
}

- (instancetype)init
{
  return [self initWithStages:@[] handler:nil];
}

- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply
{
  OISPipelineRest *rest = [[OISPipelineRest alloc] init];
  @synchronized (self) {
    rest.stages = self.stages;
    rest.handler = self.handler;
  }
  @try {
    [rest handleRequest:request reply:reply];
  } @catch (NSException *exception) {
    NSLog(@"ODataServer: %@ %@ raised %@: %@", request.method, request.target, exception.name, exception.reason);
    [reply failWithError:ODataServiceError(500, @"The server could not answer the request")];
  }
}

- (void)addStage:(ODataServerStage *)stage
{
  @synchronized (self) {
    self.stages = [self.stages arrayByAddingObject:stage];
  }
}

- (NSUInteger)indexOfStageOfClass:(Class)cls
{
  NSUInteger i = 0;
  for (ODataServerStage *stage in self.stages) {
    if ([stage isKindOfClass:cls]) return i;
    i++;
  }
  return NSNotFound;
}

- (void)insertStage:(ODataServerStage *)stage beforeStageOfClass:(Class)cls
{
  @synchronized (self) {
    NSMutableArray *stages = [self.stages mutableCopy];
    NSUInteger i = [self indexOfStageOfClass:cls];
    [stages insertObject:stage atIndex:i == NSNotFound ? stages.count : i];
    self.stages = stages;
  }
}

- (void)insertStage:(ODataServerStage *)stage afterStageOfClass:(Class)cls
{
  @synchronized (self) {
    NSMutableArray *stages = [self.stages mutableCopy];
    NSUInteger i = [self indexOfStageOfClass:cls];
    [stages insertObject:stage atIndex:i == NSNotFound ? stages.count : i + 1];
    self.stages = stages;
  }
}

- (void)removeStagesOfClass:(Class)cls
{
  @synchronized (self) {
    NSMutableArray *kept = [NSMutableArray array];
    for (ODataServerStage *stage in self.stages) {
      if (![stage isKindOfClass:cls]) [kept addObject:stage];
    }
    self.stages = kept;
  }
}

- (void)replaceStageOfClass:(Class)cls withStage:(ODataServerStage *)stage
{
  @synchronized (self) {
    NSMutableArray *stages = [self.stages mutableCopy];
    NSUInteger i = [self indexOfStageOfClass:cls];
    if (i == NSNotFound) {
      [stages addObject:stage];
    } else {
      stages[i] = stage;
    }
    self.stages = stages;
  }
}

- (ODataServerStage *)stageOfClass:(Class)cls
{
  NSUInteger i = [self indexOfStageOfClass:cls];
  return i == NSNotFound ? nil : self.stages[i];
}

- (NSString *)description
{
  NSMutableString *text = [NSMutableString stringWithString:@"<ODataServerPipeline"];
  for (ODataServerStage *stage in self.stages) [text appendFormat:@"\n  %@", stage];
  [text appendFormat:@"\n  -> %@>", self.handler ?: @"(nothing)"];
  return text;
}

@end
