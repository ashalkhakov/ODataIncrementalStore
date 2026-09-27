// ODataKit — what an OData client and an OData service share.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// The core of the ODataKit libraries: a service's schema ($metadata,
// with its annotations), values in JSON and as literals, the mapping of a
// Core Data model to OData names and types, the URL expression parser,
// $batch bodies, and exchanges and transports. ODataIncrementalStore (the
// client, a Core Data store over a service) and ODataService (the server,
// a Core Data store served) build on it.

#pragma once
#import "OISRuntime.h"
#import "OISCoreData.h"
#import "ODataError.h"
#import "ODataSchema.h"
#import "ODataValue.h"
#import "ODataPropertyMapper.h"
#import "ODataExpression.h"
#import "ODataApply.h"
#import "ODataCSDL.h"
#import "ODataBatch.h"
#import "ODataTransport.h"
