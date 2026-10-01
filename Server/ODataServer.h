// ODataServer — an ODataService on the network, with the application's own
// routes and stages around it.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// One header for all of it:
//
//   ODataServerMessage.h      requests, responses, replies
//   ODataServerPipeline.h     handlers, stages, pipelines
//   ODataServerRouter.h       routes and the router
//   ODataServerHandlers.h     the service mounted, health, authentication,
//                             request ids, CORS, compression, the access log
//   ODataServerObservability.h  metrics, trace context, readiness
//   ODataHTTPServer.h         the listener
//   ODataServerApplication.h  settings, the application, ODataServerMain

#pragma once
#import "ODataServerMessage.h"
#import "ODataServerPipeline.h"
#import "ODataServerRouter.h"
#import "ODataServerHandlers.h"
#import "ODataServerObservability.h"
#import "ODataHTTPServer.h"
#import "ODataServerApplication.h"
