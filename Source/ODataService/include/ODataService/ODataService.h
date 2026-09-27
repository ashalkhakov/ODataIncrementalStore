// ODataIncrementalStore — a Core Data model served over OData.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// ODataService is the server's core: it takes an OData request and answers
// it from a Core Data store, and never sees a socket (docs/server-design.md).
// It is an ODataTransport, so an ODataIncrementalStore can be handed one
// and talk to a Core Data store through OData in-process; the HTTP adapter
// (ODataHTTPServer) hands it requests from the network the same way.
//
// What it serves, read from the model through ODataPropertyMapper:
//   - the service document and $metadata (ODataMetadataWriter);
//   - entity sets, entities by key (Products(1), and Products/1), their
//     properties and raw values ($value), navigation (Categories(1)/Products),
//     and /$count;
//   - $filter, $orderby, $top, $skip, $count, $select, $expand with its
//     own options, $skiptoken for server-driven paging, parameter aliases;
//   - POST, PATCH, PUT, DELETE, with @odata.bind for relationships, ETags
//     and If-Match, Prefer return=minimal|representation;
//   - OData 4.01, and 4.0 for a client that asks for no more
//     (OData-MaxVersion).
// Every failure is an OData error body with its status: 400 for a request
// that does not parse or does not fit the model, 404, 405, 412, and 501 for
// what is not supported yet.
//
// An application changes what an entity set does with an
// ODataEntitySetHandler, adds actions and functions by declaring them in
// protocols (below), and answers through an ODataReply.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataTransport.h>
#import <ODataKit/ODataExpression.h>
#import <ODataKit/ODataPropertyMapper.h>

NS_ASSUME_NONNULL_BEGIN

@class ODataService, ODataRequest, ODataPrincipal;
@protocol ODataAuthenticator;

// userInfo on an Integer attribute: the entity's version, sent as its ETag
// and incremented by every update. Without one, an entity's ETag is a hash
// of its values.
FOUNDATION_EXPORT NSString * const ODataUserInfoETag;  // @"OData.etag"

// How a handler answers. The service is the only caller of a handler's
// methods, and the reply is its end of the call. A method that can answer
// at once returns its result, or calls -failWithError: and returns nil. A
// method that has to wait for something calls -defer, returns (what it
// returns is then ignored), and later, on any thread, calls
// -finishWithResult: or -failWithError:. Whatever it does with the
// request's context after returning goes through -performBlock:. A
// deferred reply that is not answered within the service's replyTimeout
// is answered 504 for it, and a later answer is ignored.
@interface ODataReply : NSObject
- (instancetype)init NS_UNAVAILABLE;
- (void)defer;
- (void)finishWithResult:(nullable id)result;
- (void)failWithError:(NSError *)error;
@property (nonatomic, readonly, getter=isDeferred) BOOL deferred;
@property (nonatomic, readonly, getter=isFinished) BOOL finished;
@property (nonatomic, readonly, strong, nullable) id result;
@property (nonatomic, readonly, strong, nullable) NSError *error;
// The request being answered: its context, its headers, and for an
// operation bound to a collection, the collection.
@property (nonatomic, readonly, weak, nullable) ODataRequest *request;
@end

// Operations. Objective-C has no annotations, so a protocol declares them:
// one that inherits ODataFunctions declares functions (no side effects,
// called with GET), one that inherits ODataActions actions (POST). Every
// method takes an ODataReply as its last parameter.
//
//   @protocol ProductFunctions <ODataFunctions>
//   - (NSDecimalNumber *)discountedPriceByPercent:(double)percent reply:(ODataReply *)reply;
//   + (NSArray *)pricierThanPrice:(double)price reply:(ODataReply *)reply;
//   @end
//   @interface Product : NSManagedObject <ProductFunctions>
//
// An instance method of an entity's managed object class is bound to the
// entity (Products(1)/Default.DiscountedPriceByPercent(Percent=10)), a class
// method to its collection (Products/Default.PricierThanPrice(Price=20)),
// and a method of the service's serviceOperations object is unbound,
// reached through an import (CountProducts()). Only protocols a class
// adopts itself count, not those it inherits.
//
// Names come from the selector, by the mapper's naming: the first keyword
// up to "With" names the operation and the rest the first parameter
// (shareTripWithUserName:tripId:reply: is ShareTrip(UserName, TripId));
// without "With", the whole keyword names the operation and its last word
// the parameter (pricierThanPrice: is PricierThanPrice(Price)). Types come
// from the protocol's extended type encodings, which name each object
// parameter's class: int32_t is Edm.Int32, int64_t Edm.Int64, int16_t
// Edm.Int16, double Edm.Double, float Edm.Single, BOOL Edm.Boolean,
// NSString Edm.String, NSDate Edm.DateTimeOffset, NSDecimalNumber
// Edm.Decimal, NSUUID Edm.Guid, NSData Edm.Binary, a managed object class
// its entity type. What the runtime cannot see, a collection's element type
// or which number an NSNumber is, the class says in a class method, and it
// can rename what the rules get wrong:
//
//   + (NSDictionary *)ODataOperationTypes
//   { return @{ @"pricierThanPrice:reply:": @"Collection(Default.Product)",
//               @"countWithLimit:reply:.limit": @"Edm.Int32" }; }
//   + (NSDictionary *)ODataOperationNames
//   { return @{ @"pricierThanPrice:reply:": @"MorePricey",
//               @"pricierThanPrice:reply:.price": @"Floor" }; }
//
// A declaration the service cannot type is listed in operationProblems and
// left out; ois-serve refuses to start with any.
@protocol ODataFunctions
@end
@protocol ODataActions
@end

// A request as the service read it.
@interface ODataRequest : NSObject
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly, weak) ODataService *service;
@property (nonatomic, readonly) NSURLRequest *URLRequest;
@property (nonatomic, readonly, copy) NSString *method;
// Header names are case-insensitive.
- (nullable NSString *)valueForHeader:(NSString *)name;
@property (nonatomic, readonly, strong) ODataResourcePath *path;
@property (nonatomic, readonly, strong) ODataQueryOptions *options;
// The entity the request is about: its entity set's, or the type an
// inserted entity's @odata.type names.
@property (nonatomic, readonly, strong, nullable) NSEntityDescription *entity;
// For an operation bound to a collection: the collection's rows, as a fetch
// request (its navigation, and what the set lets the caller see).
@property (nonatomic, readonly, strong, nullable) NSFetchRequest *collectionFetchRequest;
// The request's own private-queue context. Handler methods run inside its
// -performBlockAndWait:.
@property (nonatomic, readonly, strong) NSManagedObjectContext *context;
// The OData-Version the response is in: 4.0 or 4.01.
@property (nonatomic, readonly, copy) NSString *version;
// Prefer, by preference name in lower case: return, odata.maxpagesize, ...
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *preferences;
// The application's own, for the length of the request.
@property (nonatomic, readonly, strong) NSMutableDictionary *userInfo;
// Who is asking, as the service's authenticator found them; nil without
// one, or for an anonymous request it allows (ODataAuthentication.h).
@property (nonatomic, readonly, strong, nullable) ODataPrincipal *principal;
// Something to tell the client alongside the answer (Core.Messages): a
// price rounded, a property ignored. Written into the response's JSON
// body, unless the client's Prefer: odata.include-annotations leaves
// Core.Messages out; a response without a body (204) has none to carry
// it. Severity: success, info, warning or error. From any thread.
- (void)addMessage:(NSString *)message code:(NSString *)code severity:(NSString *)severity target:(nullable NSString *)target;
@property (nonatomic, readonly, copy) NSArray<ODataMessage *> *messages;
@end

// What an entity set does. The default does everything over the request's
// context; a subclass overrides what it needs to and is registered with
// -[ODataService setHandler:forEntitySet:]. Values are keyed by Core Data
// property name: attributes hold Core Data values, relationships managed
// objects (a set of them for a to-many relationship). The service saves
// after insert, update and delete, and reports a failed save.
@interface ODataEntitySetHandler : NSObject

- (instancetype)initWithEntity:(NSEntityDescription *)entity NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property (nonatomic, readonly) NSEntityDescription *entity;
@property (nonatomic, readonly, weak, nullable) ODataService *service;

// What the set allows. A method it does not is answered with 405.
@property (nonatomic) BOOL allowsInsert;
@property (nonatomic) BOOL allowsUpdate;
@property (nonatomic) BOOL allowsDelete;
// Properties (wire names) of the set's entities that $filter, and
// $orderby, may not use: answered 400, and said in $metadata
// (Capabilities.FilterRestrictions, SortRestrictions). Empty by default.
@property (nonatomic, copy) NSSet<NSString *> *nonFilterableProperties;
@property (nonatomic, copy) NSSet<NSString *> *nonSortableProperties;
// What $search looks in (Part 2 section 5.1.7): these properties (wire
// names), each a string; a word or "phrase" matches a row where one of
// them holds it, regardless of case and diacritics. nil, the default:
// every string property. Empty: the set cannot be searched (501), as
// $metadata says (Capabilities.SearchRestrictions).
@property (nonatomic, copy, nullable) NSSet<NSString *> *searchableProperties;
// Whether a read of the set may ask to follow its changes (Prefer:
// odata.track-changes, Part 1 section 11.3): a delta link, answered from
// the store's persistent history. Also needs every store to keep history
// (NSPersistentHistoryTrackingKey) and the set's key attributes to be kept
// in a deletion's tombstone (preservesValueInHistoryOnDeletion); $metadata
// says which sets can (Capabilities.ChangeTracking). YES by default; a
// handler whose rows are not the store's says NO.
@property (nonatomic) BOOL tracksChanges;

// The rows the caller may see at all, however they are reached: fetched,
// by key, through navigation or $expand. nil: every row.
- (nullable NSPredicate *)predicateForVisibleObjectsInRequest:(ODataRequest *)request;

// The rows of a request, already filtered, sorted and paged, with
// -predicateForVisibleObjectsInRequest: in its predicate.
- (nullable NSArray<NSManagedObject *> *)objectsForFetchRequest:(NSFetchRequest *)fetchRequest
                                                        request:(ODataRequest *)request
                                                          reply:(ODataReply *)reply;
// How many rows the same request has, without paging; an NSNumber.
- (nullable NSNumber *)countForFetchRequest:(NSFetchRequest *)fetchRequest
                                    request:(ODataRequest *)request
                                      reply:(ODataReply *)reply;
// The row with this key (by Core Data attribute name), among the visible
// ones; nil when there is none (404).
- (nullable NSManagedObject *)objectWithKey:(NSDictionary<NSString *, id> *)key
                                    request:(ODataRequest *)request
                                      reply:(ODataReply *)reply;
- (nullable NSManagedObject *)insertObjectWithValues:(NSDictionary<NSString *, id> *)values
                                             request:(ODataRequest *)request
                                               reply:(ODataReply *)reply;
- (nullable NSManagedObject *)updateObject:(NSManagedObject *)object
                                    values:(NSDictionary<NSString *, id> *)values
                                   request:(ODataRequest *)request
                                     reply:(ODataReply *)reply;
// Finishes with no result.
- (void)deleteObject:(NSManagedObject *)object request:(ODataRequest *)request reply:(ODataReply *)reply;

@end

@interface ODataService : NSObject <ODataTransport>

// A service over a coordinator's stores, answering requests under this
// root: its path is where the service is (http://example.com/odata/), and
// the whole URL is what the service's own links begin with, so behind a
// reverse proxy it is the public one.
- (instancetype)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator
                                       serviceRoot:(NSURL *)serviceRoot NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSPersistentStoreCoordinator *coordinator;
@property (nonatomic, readonly) NSManagedObjectModel *model;
@property (nonatomic, readonly, copy) NSURL *serviceRoot;
// Names, keys and types. Set this, and the next two, before the first
// request: the service's $metadata is written from them then.
@property (nonatomic, strong) ODataPropertyMapper *mapper;
@property (nonatomic, copy) NSString *namespaceName;  // Default: Default
@property (nonatomic, copy) NSString *containerName;  // Default: Container
// The newest version the service speaks: 4.01 (the default) or 4.0.
@property (nonatomic, copy) NSString *maxVersion;
// Server-driven paging: at most this many rows a response, with a next
// link for the rest. 0, the default: as many as the client asks for
// (Prefer: odata.maxpagesize), else all of them.
@property (nonatomic) NSUInteger maxPageSize;
// How long a deferred reply may take before the request is answered 504
// Gateway Timeout. 0: no limit. Default: 60 seconds.
@property (nonatomic) NSTimeInterval replyTimeout;
// Repeatable requests (OData Repeatable Requests 1.0; the Repeatability
// vocabulary): a request that changes something and carries
// Repeatability-Request-ID and Repeatability-First-Sent is answered once,
// and its answer remembered this long; the same request again is given
// the same answer, with Repeatability-Result: accepted. One first sent
// longer ago than that, or an ID given to another request, is answered
// 400, Repeatability-Result: rejected. An answer 5xx is not remembered.
// 0 turns it off. Default: 3600 seconds.
@property (nonatomic) NSTimeInterval repeatabilityDuration;
// Asynchronous requests (Part 1 sections 8.2.8.8 and 11.6). A request that
// prefers respond-async and is not answered at once (a handler or the
// authenticator defers, for longer than Prefer: wait=N allows) is answered
// 202 Accepted with a status monitor, $async/<id>, in Location. A GET of
// the monitor is 202 while the request is under way, then 200 with its
// answer as application/http; DELETE forgets it. Only who sent the request
// may ask. An answer is kept this long after it is ready. 0: respond-async
// is not applied. Default: 600 seconds.
@property (nonatomic) NSTimeInterval asyncResultDuration;
// Who each request is from (ODataAuthentication.h). A request that names
// no one is answered 401, unless allowsAnonymousRequests; without an
// authenticator (the default) every request is anonymous and answered.
@property (nonatomic, strong, nullable) id<ODataAuthenticator> authenticator;
@property (nonatomic) BOOL allowsAnonymousRequests;
// The service document and $metadata to anyone, as a client needs them
// to learn how to sign in (the Authorization vocabulary in $metadata).
// Default: NO.
@property (nonatomic) BOOL allowsAnonymousMetadata;
// Annotations of the entity container in $metadata, by term
// (Core.Description, Authorization.Authorizations, or qualified), valued
// as JSON CSDL has them (ODataSchema.h). Set before the first request.
// Entities and properties are annotated from the model (see
// ODataMetadataWriter.h), how to sign in from the authenticator.
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *containerAnnotations;
// The object whose methods are the service's unbound operations; see
// ODataFunctions. Set it before the first request.
@property (nonatomic, strong, nullable) id serviceOperations;
// The operations that could not be declared, one sentence each, naming the
// selector.
@property (nonatomic, readonly) NSArray<NSString *> *operationProblems;

- (void)setHandler:(ODataEntitySetHandler *)handler forEntitySet:(NSString *)entitySet;
- (nullable ODataEntitySetHandler *)handlerForEntitySet:(NSString *)entitySet;
@property (nonatomic, readonly) NSArray<NSString *> *entitySets;

// $metadata, in the CSDL of 4.0 or 4.01.
- (NSString *)metadataXMLForVersion:(NSString *)version;
// What $metadata had to leave out of the model, one sentence each.
@property (nonatomic, readonly) NSArray<NSString *> *metadataProblems;

// ODataTransport: answers the exchange's request. A request whose handlers
// answer at once is finished before this returns.
- (void)startExchange:(ODataExchange *)exchange;

@end

NS_ASSUME_NONNULL_END

// The rest of the server library, for those who import it by this name.
#import "ODataAuthentication.h"
#import "ODataPredicateBuilder.h"
#import "ODataMetadataWriter.h"
