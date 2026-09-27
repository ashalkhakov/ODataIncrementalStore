// ODataIncrementalStore — $search in a fetch request.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// $search (Part 2 section 5.1.7) is a service's own free-text search:
// words and "phrases", with AND, OR, NOT and parentheses. What a word
// matches is the service's to say; there is no predicate for it, so this
// is one. As the fetch's predicate, or ANDed at its top with others, it is
// sent as $search beside the $filter the rest makes:
//
//   // Products?$search=tea OR coffee&$filter=UnitPrice lt 20
//   fetch.predicate = [NSCompoundPredicate andPredicateWithSubpredicates:@[
//     [ODataSearchPredicate predicateWithSearch:@"tea OR coffee"],
//     [NSPredicate predicateWithFormat:@"unitPrice < 20"] ]];
//
// Anywhere else (under OR or NOT) it cannot be sent: the fetch fails with
// ODataIncrementalStoreErrorUnsupportedPredicate. A set whose
// Capabilities.SearchRestrictions says it is not searchable fails it with
// ODataIncrementalStoreErrorNotAllowedByService.
//
// Evaluated in memory it looks for each word or phrase in the object's
// string attributes, regardless of case and diacritics: what ODataService
// does, and a guess at what another service does.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataExpression.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataSearchPredicate : NSPredicate <NSSecureCoding>
// nil when the text is not a search expression.
+ (nullable instancetype)predicateWithSearch:(NSString *)search error:(NSError **)error;
// Raises NSInvalidArgumentException when it is not.
+ (instancetype)predicateWithSearch:(NSString *)search;
@property (nonatomic, readonly, strong) ODataSearchExpression *search;
@end

NS_ASSUME_NONNULL_END
