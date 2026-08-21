// Loads Examples/Catalog/Catalog.xcdatamodeld for the XCTest suite.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once
#import "ODataIncrementalStore.h"

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSURL *OISTestServiceRoot(void);
FOUNDATION_EXPORT NSString *OISSnapshotDirectory(void);
FOUNDATION_EXPORT NSURL * _Nullable OISCatalogModelURL(void);
FOUNDATION_EXPORT NSManagedObjectModel * _Nullable OISCatalogModel(void);
FOUNDATION_EXPORT NSEntityDescription * _Nullable OISCatalogEntity(NSString *name);

NS_ASSUME_NONNULL_END
