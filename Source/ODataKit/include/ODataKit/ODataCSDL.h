// ODataKit — CSDL in JSON (OData CSDL JSON Format 4.01) and in XML.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// $metadata comes in two formats that say the same: CSDL XML, which the
// schema reader and the metadata writer speak, and CSDL JSON. These turn
// one into the other: entity, complex and enumeration types, type
// definitions, terms, actions and functions with their overloads, the
// entity container, references and includes, and annotations, inline and
// targeted, with constant and dynamic expressions. Two defaults differ
// between them, and are kept: $Nullable is false when absent in JSON (true
// in XML), and $Type is Edm.String.

#pragma once
#import "OISRuntime.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataCSDL : NSObject
+ (nullable NSData *)JSONDataForXMLData:(NSData *)xml error:(NSError **)error;
+ (nullable NSData *)XMLDataForJSONData:(NSData *)json error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
