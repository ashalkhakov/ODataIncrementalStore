// ODataIncrementalStore — calling a service's actions and functions.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Actions and functions (Part 1 section 11.5) are the methods of a
// service's entities, over the network. One bound to an entity type is an
// instance method: it is called on an object. One bound to a collection
// of them is a class method: it is called on an entity. An unbound one is
// a function of the service, called by the name its entity container
// imports it under. A function has no side effects and is called with
// GET; an action may change things and is called with POST.
//
//   NSManagedObject *airline = [russell invokeODataOperation:@"GetFavoriteAirline" parameters:nil error:&error];
//
//   ODataOperationCall *call = [ODataOperationCall callOfOperation:@"CreateInvoice" inContext:context];
//   call.parameters = @{ @"customer": customer, @"lines": lines };
//   NSManagedObject *invoice = [call invoke:&error];
//
// The operation is found in the store's $metadata, by its simple or
// qualified name, among those bound to the object's entity type or a base
// of it; overloads are told apart by the parameters given. Parameters are
// written as their declared types say, as the store writes attributes: a
// date as a date, an enumeration by its member names, a complex value
// from an NSDictionary, a collection from an NSArray, an object as a
// reference to it. Their names are matched regardless of case.
//
// The result is what the operation returns: a managed object for an
// entity, in the call's context, already saved and its row kept, so
// firing it costs nothing; an NSArray of them for a collection of
// entities, every page of it; otherwise the value as the store reads
// attributes (an NSDictionary for a complex value, an NSArray for a
// collection). NSNull when the operation returns nothing or null.
//
// An action may change the object it is bound to; its kept row is
// discarded, so refreshing the object (refreshObject:mergeChanges:) reads
// it again.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataSchema.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataOperationCall : NSObject

// Bound to the object's entity type: an instance method. The object must
// be saved.
+ (instancetype)callOfOperation:(NSString *)name onObject:(NSManagedObject *)object;
// Bound to a collection of the entity's type: a class method.
+ (instancetype)callOfOperation:(NSString *)name onEntity:(NSString *)entityName inContext:(NSManagedObjectContext *)context;
// Unbound, by the name of its import (or its qualified name).
+ (instancetype)callOfOperation:(NSString *)name inContext:(NSManagedObjectContext *)context;

@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly, strong, nullable) NSManagedObject *object;
@property (nonatomic, readonly, copy, nullable) NSString *entityName;
@property (nonatomic, readonly, strong) NSManagedObjectContext *context;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, id> *parameters;

// Once invoked: the operation called, and how it went.
@property (nonatomic, readonly, strong, nullable) ODataSchemaOperation *operation;
@property (nonatomic, readonly, strong, nullable) id result;
@property (nonatomic, readonly, strong, nullable) NSError *error;

// Calls it and waits: the result, or nil and the error. Call it where the
// context may be used (in performBlock: for a queue context), as a fetch.
- (nullable id)invoke:(NSError **)error;

// Calls it without waiting; the action is sent to the target with the
// call as its argument, on the context's queue (the main thread for a
// confinement context), once the result or the error is in.
- (void)invokeWithTarget:(id)target action:(SEL)action;

@end

@interface NSManagedObject (ODataOperations)
// [ODataOperationCall callOfOperation:name onObject:self], invoked.
- (nullable id)invokeODataOperation:(NSString *)name
                         parameters:(nullable NSDictionary<NSString *, id> *)parameters
                              error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
