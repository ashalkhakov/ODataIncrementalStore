// ODataIncrementalStore — classes for a model built from $metadata.
// Copyright (C) 2026 OIS contributors
// SPDX-License-Identifier: LGPL-2.1-or-later
//
// A client built on one service gets classes for its entities, with the
// service's operations as their methods (see ODataOperationCall.h): an
// action or function bound to an entity type is an instance method, one
// bound to a collection of them a class method, and the unbound ones are
// class methods of a class for the service.
//
//   Airline *airline = [russell getFavoriteAirline:&error];
//   BOOL shared = [russell shareTripWithUserName:@"scottketchum" tripId:@0 error:&error];
//   Airport *airport = [TripPinService getNearestAirportInContext:context lat:@33.9 lon:@-118.4 error:&error];
//
// Each entity gets two classes, as mogenerator makes them: _Person, with
// its properties and methods, written again whenever the model is; and
// Person, a subclass of it written only when there is none, for the
// client's own logic. A sub-entity's classes derive from its
// super-entity's Person class. The service's class is made the same way
// (_TripPinService, TripPinService).
//
// Methods wait for the service, like -invokeODataOperation:...; each
// returns the result, or nil with the error set (nil with no error: the
// operation returned null). One that returns nothing returns BOOL.
// Parameters are all optional: nil ones are not sent.

#pragma once
#import <ODataKit/OISCoreData.h>
#import <ODataKit/ODataSchema.h>

NS_ASSUME_NONNULL_BEGIN

@interface ODataClassWriter : NSObject

// Writes the classes into directory, creating it, and names them in the
// model (each entity's managedObjectClassName), so a model written after
// this refers to them. Returns the paths of the files written.
+ (nullable NSArray<NSString *> *)writeClassesForModel:(NSManagedObjectModel *)model
                                                schema:(ODataSchema *)schema
                                           serviceName:(NSString *)serviceName
                                           toDirectory:(NSString *)directory
                                                 error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
