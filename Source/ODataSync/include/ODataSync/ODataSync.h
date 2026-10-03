// ODataSync — offline Core Data stores kept in sync with OData services
// (docs/offline-sync.md).
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import "ODataSyncEngine.h"
#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif
// The peer server and the service's part serve (ODataService,
// HTTPServerKit): not on iOS, where ODataSync is a client.
#if !(defined(__APPLE__) && TARGET_OS_IPHONE)
#import "ODataSyncPeerServer.h"
#import "ODataSyncService.h"
#endif
