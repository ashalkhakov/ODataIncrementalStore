// HTTPServerKit — an HTTP server an application adds its APIs to: OData
// (ODataService's ODataServerApplication), its own routes, and later
// others, behind one pipeline of stages.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// One header for all of it:
//
//   HSMessage.h         requests, responses, replies; errors (problem+json)
//   HSLog.h             what the server says as it runs, as text or JSON
//   HSPipeline.h        handlers, stages, pipelines
//   HSRouter.h          routes, the router, the routing stage
//   HSStages.h          health, request ids, CORS, compression, the access
//                       log, authentication
//   HSAuthentication.h  who is asking: principals, authenticators (proxy
//                       headers, JWT, introspection)
//   HSObservability.h   metrics, trace context and the request's span,
//                       readiness
//
// Spans are OTelKit's (<OTelKit/OTelKit.h>), which this imports.
//   HSServer.h          the listener
//   HSApplication.h     settings, modules, the application, HSMain

#pragma once
#import <OTelKit/OTelKit.h>
#import "HSMessage.h"
#import "HSLog.h"
#import "HSPipeline.h"
#import "HSRouter.h"
#import "HSStages.h"
#import "HSAuthentication.h"
#import "HSObservability.h"
#import "HSServer.h"
#import "HSApplication.h"
