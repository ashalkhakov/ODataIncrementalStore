// ODataIncrementalStore — $batch, served.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Private to ODataService. A $batch request (Part 1 section 11.7) in either
// format: multipart/mixed, with change sets, or 4.01's JSON, with
// atomicity groups. Each request in it is answered by the service as any
// other, in order. A change set's (an atomicity group's) requests share
// one context, which is saved when they have all succeeded; if one fails,
// or the save does, none of them takes effect, and the change set is
// answered with that failure. Content-ID ($1) names what an earlier
// request created, in a URL or in @odata.bind. The batch stops at the
// first failure unless the client prefers odata.continue-on-error.
//
// A request whose handler answers later does not hold the others up: the
// batch goes on when its exchange finishes, target-action, like any
// caller of a transport.

#pragma once
#import "ODataService.h"

NS_ASSUME_NONNULL_BEGIN

@interface ODataService (OISBatchSupport)
// An exchange answered in this context, which is saved only when saves is
// YES; nil: a context of its own, saved. authenticated: from principal
// (nil: anonymous), without asking the authenticator.
- (void)startExchange:(ODataExchange *)exchange inContext:(nullable NSManagedObjectContext *)context saves:(BOOL)saves
        authenticated:(BOOL)authenticated principal:(nullable ODataPrincipal *)principal;
@end

@interface OISBatchCall : NSObject
// The batch's requests are principal's: the batch was authenticated as a
// whole, and headers inside it do not change who is asking.
- (instancetype)initWithService:(ODataService *)service exchange:(ODataExchange *)exchange version:(NSString *)version
                      principal:(nullable ODataPrincipal *)principal;
// Reads the batch and answers its requests, then the exchange.
- (void)start;
@end

NS_ASSUME_NONNULL_END
