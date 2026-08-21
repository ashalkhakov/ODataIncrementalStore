// Shared Northwind-shaped model + snapshot directory.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#import "ODataIncrementalStore.h"

FOUNDATION_EXPORT NSString *OISSnapshotDirectory(void);
FOUNDATION_EXPORT NSURL *OISTestServiceRoot(void);
FOUNDATION_EXPORT NSAttributeDescription *OISAttr(NSString *name, NSString *wire, NSAttributeType type);
FOUNDATION_EXPORT NSEntityDescription *OISProductEntity(void);
FOUNDATION_EXPORT NSEntityDescription *OISCategoryEntity(void);
FOUNDATION_EXPORT NSManagedObjectModel *OISNorthwindModel(void);
FOUNDATION_EXPORT NSManagedObject *OISMakeObject(NSEntityDescription *entity, NSDictionary *values, BOOL inserted);
