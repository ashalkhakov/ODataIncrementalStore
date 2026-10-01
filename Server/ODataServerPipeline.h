// ODataServerPipeline — handlers, stages, and the pipeline of stages a request
// goes through on its way to a handler.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Everything that answers a request is an ODataServerHandler: an endpoint of
// the application's, a mounted ODataService (ODataServiceHandler), the
// router, a pipeline. So any of them can stand where another does: a
// route's handler can be a pipeline of its own.
//
// A request's life, through a pipeline:
//
//   1. Forward: each stage's -shouldPassRequest:reply:, in order. A stage
//      may answer the reply and return NO; the request goes no further.
//   2. The handler finishes the reply, now or later, on whatever thread its
//      work finished on.
//   3. Back: finishing the reply is when the response exists. In that same
//      call, on that same thread, each stage the request passed through is
//      sent -request:willSendResponse:, last first, and may still change
//      the status, headers and body.
//   4. Out: once the first stage's has returned, the response goes to
//      whoever started the request (the listener writes it).
//
// No thread is started for any of it. -request:willSendResponse: runs
// before anything is written, and must not wait: what has to take time
// after a response (shipping a log) is started there, not waited for.

#pragma once
#import <Foundation/Foundation.h>
#import "ODataServerMessage.h"

NS_ASSUME_NONNULL_BEGIN

@protocol ODataServerHandler <NSObject>
// Answer through the reply, now or later, from any thread: exactly once.
- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply;
@end

// A step every request through a pipeline takes. Subclass it and override
// what you need: most stages override one of the first two.
@interface ODataServerStage : NSObject
// Before: YES passes the request on. To stop it here, finish the reply
// (it still goes back through this stage's -request:willSendResponse:)
// and return NO. Default: YES.
- (BOOL)shouldPassRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply;
// After, on the way back, last stage first: change or note the response.
// Synchronous: the response is written once this returns. Default: none.
- (void)request:(ODataServerRequest *)request willSendResponse:(ODataServerResponse *)response;
// The whole step, for a stage that has to wait before passing a request
// on (asking someone else), or wrap what comes after it: pass it on with
// [next handleRequest:request reply:...] when ready, or answer the reply
// itself. Overriding this, the stage owns its step: the two methods above
// are not called unless it calls super. The default calls them.
- (void)handleRequest:(ODataServerRequest *)request reply:(ODataServerReply *)reply next:(id<ODataServerHandler>)next;
@end

// Stages in order, then a handler: itself a handler. The stages are an
// array to read, reorder or replace; a request in flight keeps the ones it
// started with. -description lists them.
@interface ODataServerPipeline : NSObject <ODataServerHandler>
- (instancetype)initWithStages:(NSArray<ODataServerStage *> *)stages handler:(nullable id<ODataServerHandler>)handler NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
@property (copy) NSArray<ODataServerStage *> *stages;
// What the stages lead to; none: 404.
@property (strong, nullable) id<ODataServerHandler> handler;
- (void)addStage:(ODataServerStage *)stage;
// Before the first stage of that class, or last when there is none.
- (void)insertStage:(ODataServerStage *)stage beforeStageOfClass:(Class)cls;
- (void)insertStage:(ODataServerStage *)stage afterStageOfClass:(Class)cls;
- (void)removeStagesOfClass:(Class)cls;
// In place of the first stage of that class, or last when there is none.
- (void)replaceStageOfClass:(Class)cls withStage:(ODataServerStage *)stage;
// The first stage of that class (or a subclass), or nil.
- (nullable __kindof ODataServerStage *)stageOfClass:(Class)cls;
@end

NS_ASSUME_NONNULL_END
