// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: GPL-3.0-or-later

#import "ODataError.h"

NSErrorDomain const ODataIncrementalStoreErrorDomain = @"org.gnu.ois.ODataIncrementalStore";

NSError *OISError(ODataIncrementalStoreErrorCode code, NSString *message)
{
  return [NSError errorWithDomain:ODataIncrementalStoreErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}
