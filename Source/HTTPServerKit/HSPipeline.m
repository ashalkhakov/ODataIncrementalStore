// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "HSPipeline.h"

// The rest of a pipeline from one stage on: what that stage's next is.
@interface HSPipelineRest : NSObject <HSHandler>
@property (nonatomic, copy) NSArray<HSStage *> *stages;
@property (nonatomic) NSUInteger index;
@property (nonatomic, strong, nullable) id<HSHandler> handler;
@end

@implementation HSPipelineRest

- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  if (self.index < self.stages.count) {
    HSPipelineRest *rest = [[HSPipelineRest alloc] init];
    rest.stages = self.stages;
    rest.index = self.index + 1;
    rest.handler = self.handler;
    [self.stages[self.index] handleRequest:request reply:reply next:rest];
  } else if (self.handler) {
    [self.handler handleRequest:request reply:reply];
  } else {
    [reply failWithError:HSError(404, @"Nothing answers here")];
  }
}

@end

// A stage's way back: the reply it hands on is finished, so it sees the
// response, then the reply it was handed is.
@interface HSStageReturn : NSObject
@property (nonatomic, strong) HSStage *stage;
@property (nonatomic, strong) HSRequest *request;
@property (nonatomic, strong) HSReply *reply;
@end

@implementation HSStageReturn

- (void)didFinish:(HSReply *)inner
{
  HSResponse *response = inner.response;
  [self.stage request:self.request willSendResponse:response];
  [self.reply finishWithResponse:response];
}

@end

@implementation HSStage

- (BOOL)shouldPassRequest:(HSRequest *)request reply:(HSReply *)reply
{
  return YES;
}

- (void)request:(HSRequest *)request willSendResponse:(HSResponse *)response
{
}

- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply next:(id<HSHandler>)next
{
  HSStageReturn *back = [[HSStageReturn alloc] init];
  back.stage = self;
  back.request = request;
  back.reply = reply;
  HSReply *inner = [[HSReply alloc] initWithTarget:back action:@selector(didFinish:)];
  inner.request = request;
  if ([self shouldPassRequest:request reply:inner]) {
    if (!inner.finished) [next handleRequest:request reply:inner];
  } else if (!inner.finished) {
    [inner failWithError:HSError(500, [NSString stringWithFormat:@"%@ stopped the request without answering it",
                                                                           NSStringFromClass([self class])])];
  }
}

@end

@implementation HSPipeline

- (instancetype)initWithStages:(NSArray<HSStage *> *)stages handler:(id<HSHandler>)handler
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

- (void)handleRequest:(HSRequest *)request reply:(HSReply *)reply
{
  HSPipelineRest *rest = [[HSPipelineRest alloc] init];
  @synchronized (self) {
    rest.stages = self.stages;
    rest.handler = self.handler;
  }
  @try {
    [rest handleRequest:request reply:reply];
  } @catch (NSException *exception) {
    NSLog(@"HTTPServerKit: %@ %@ raised %@: %@", request.method, request.target, exception.name, exception.reason);
    [reply failWithError:HSError(500, @"The server could not answer the request")];
  }
}

- (void)addStage:(HSStage *)stage
{
  @synchronized (self) {
    self.stages = [self.stages arrayByAddingObject:stage];
  }
}

- (NSUInteger)indexOfStageOfClass:(Class)cls
{
  NSUInteger i = 0;
  for (HSStage *stage in self.stages) {
    if ([stage isKindOfClass:cls]) return i;
    i++;
  }
  return NSNotFound;
}

- (void)insertStage:(HSStage *)stage beforeStageOfClass:(Class)cls
{
  @synchronized (self) {
    NSMutableArray *stages = [self.stages mutableCopy];
    NSUInteger i = [self indexOfStageOfClass:cls];
    [stages insertObject:stage atIndex:i == NSNotFound ? stages.count : i];
    self.stages = stages;
  }
}

- (void)insertStage:(HSStage *)stage afterStageOfClass:(Class)cls
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
    for (HSStage *stage in self.stages) {
      if (![stage isKindOfClass:cls]) [kept addObject:stage];
    }
    self.stages = kept;
  }
}

- (void)replaceStageOfClass:(Class)cls withStage:(HSStage *)stage
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

- (HSStage *)stageOfClass:(Class)cls
{
  NSUInteger i = [self indexOfStageOfClass:cls];
  return i == NSNotFound ? nil : self.stages[i];
}

- (NSString *)description
{
  NSMutableString *text = [NSMutableString stringWithString:@"<HSPipeline"];
  for (HSStage *stage in self.stages) [text appendFormat:@"\n  %@", stage];
  [text appendFormat:@"\n  -> %@>", self.handler ? (id)self.handler : @"(nothing)"];
  return text;
}

@end
