// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#import "ODataError.h"

NSErrorDomain const ODataIncrementalStoreErrorDomain = @"org.gnu.ois.ODataIncrementalStore";

NSError *OISError(ODataIncrementalStoreErrorCode code, NSString *message)
{
  return [NSError errorWithDomain:ODataIncrementalStoreErrorDomain
                             code:code
                         userInfo:@{ NSLocalizedDescriptionKey: message ?: @"" }];
}
