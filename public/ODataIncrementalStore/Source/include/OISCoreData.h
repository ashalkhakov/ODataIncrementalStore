// ODataIncrementalStore — Core Data import switch.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Apple:          <CoreData/CoreData.h>
// GNUstep:        FreeCoreData (https://github.com/ashalkhakov/FreeCoreData)
//                 installs the same umbrella after `make install`
// Last resort:    OISCoreDataStub.h  (translator / ois-filter only)
//                 compile with -DOIS_FORCE_STUB_COREDATA

#pragma once

#import "OISRuntime.h"

#if defined(OIS_FORCE_STUB_COREDATA)
#import "OISCoreDataStub.h"
#elif __has_include(<CoreData/CoreData.h>)
#import <CoreData/CoreData.h>
#else
#import "OISCoreDataStub.h"
#endif

#ifndef NSUUIDAttributeType
#define NSUUIDAttributeType ((NSAttributeType)2400)
#endif

#ifndef NSCountResultType
#define NSCountResultType ((NSFetchRequestResultType)0x04)
#endif

#ifndef NSManagedObjectConstraintMergeError
#define NSManagedObjectConstraintMergeError 1570
#endif
