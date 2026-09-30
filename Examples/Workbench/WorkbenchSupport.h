// What the Workbench's parts share: values as a table shows them, dates,
// and what to show of an entity and its objects.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later

#pragma once
#import <Foundation/Foundation.h>
#import <ODataIncrementalStore/ODataIncrementalStore.h>

// A value as one line of a table cell.
id WBCellValue(id value);
// Whether an attribute is (part of) its entity's key.
BOOL WBIsKey(NSAttributeDescription *attribute);
// Whether it is an open type's property bag (OData.dynamicProperties).
BOOL WBIsDynamic(NSAttributeDescription *attribute);
// Dynamic properties as a cell shows and edits them:
// Nickname='Rusty'; Visits=3; Since=2020-01-02 -- text quoted, numbers,
// true and false, and dates as they are. From the text again, a value
// written as the old one is shows keeps it (a structure, a list); a name
// left out is removed.
NSString *WBDynamicText(NSDictionary *values);
NSDictionary *WBDynamicFromText(NSString *text, NSDictionary *old);
// A day (2024-10-01) or a moment (…T09:00:00Z), in UTC; nil for neither.
NSDate *WBDate(NSString *text);
NSError *WBError(NSInteger code, NSString *text);
// What to show of an entity: the Catalog's own choice (builtIn), or its key
// and its other plain attributes (complex values and collections last),
// seven at most.
NSArray<NSString *> *WBColumnNames(NSEntityDescription *entity, BOOL builtIn);
// A few words that name an object: its name, if it has one.
NSString *WBTitleOf(NSManagedObject *object, BOOL builtIn);
// An object as the service addresses it: Airports('KLAX').
NSString *WBAddressOf(NSManagedObject *object);
// An object's attributes, one to a line.
NSString *WBDescribe(NSManagedObject *object);
// Calls target's action with an argument: how the parts tell the window
// controller what happened.
void WBSend(id target, SEL action, id argument);
