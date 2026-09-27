# The client: ODataIncrementalStore

An `NSIncrementalStore` whose rows live in a remote OData v4 service. A
context over it fetches, faults and saves as over any store; the store turns
each into requests. What each Core Data idea becomes on the wire, and what is
done where, is in [How it works](how-it-works.md); the protocol, item by item,
in [client conformance](odata-conformance.md).

## Opening a store

```objc
#import <ODataIncrementalStore/ODataIncrementalStore.h>

[ODataIncrementalStore registerStore];
NSURL *url = [NSURL URLWithString:@"https://services.odata.org/V4/Northwind/Northwind.svc/"];
NSPersistentStoreCoordinator *psc = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                  configuration:nil
                            URL:url
                        options:@{ ODataIncrementalStoreAccessTokenOption: token }
                          error:&error];
```

The options are in `ODataConfiguration.h`: credentials (a token, a user and
password, an API key, or a provider asked for them as `$metadata`'s
Authorization vocabulary says), the timeout, a transport of your own,
`$batch` for saves (on by default, JSON with a 4.01 service), repeatable
requests, `Prefer: respond-async`, where downloaded streams go, and which
entities to follow changes of.

```objc
NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
request.predicate = [NSPredicate predicateWithFormat:@"unitPrice > %d AND discontinued == NO", 20];
request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
request.fetchLimit = 25;
request.relationshipKeyPathsForPrefetching = @[ @"category" ];
NSArray *products = [context executeFetchRequest:request error:&error];
```

```
GET Products?$filter=(UnitPrice gt 20) and (Discontinued eq false)
           &$orderby=ProductName,ProductID
           &$top=25
           &$expand=Category
```

The key is added to `$orderby` as a tiebreaker, so pages split the same way
however many rows share a name, and every `@odata.nextLink` is followed until
the collection ends or `fetchLimit` is reached.

## The model

A model of your own names the service's sets, keys and wire names in
`userInfo` (the table is in [How it works](how-it-works.md#the-model)); the
store reads `$metadata` when it opens and fills in what the model leaves
unsaid (keys, sets, Edm types, enumerations, derived types), and lists where
the two disagree in `metadataProblems`
(`ODataIncrementalStoreRequireMatchingModelOption` makes that fail the open).

Or the service's schema is the model, two ways.

**At runtime**, for a client that knows nothing of the service in advance
(the Workbench connects to any service this way):

```objc
NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:url options:nil error:&error];
```

**Ahead of time**, for a client built on one service, with logic of its own:
`ois-model` writes the model as an `.xcdatamodeld`, which Xcode edits and
`momc` compiles like any other.

```sh
ois-model https://services.odata.org/V4/Northwind/Northwind.svc/ Northwind.xcdatamodeld
```

Entity types become entities (base types are super-entities), properties and
navigation properties become attributes and relationships in lower camel case
(`UserName` is `userName`), partners become inverses, and the OData names,
keys, sets and Edm types go into `userInfo`, so the model needs nothing else
at runtime. Complex values and collections become Transformable attributes;
spatial properties are not mapped, and `ois-model` lists them.

**A changed service is a new model version**, as in Core Data. Run `ois-model`
again: if the schema has changed, it adds a version to the package and makes
it current, keeping the old ones; if not, it writes nothing. A store opened
with a generated model checks it against the service's schema by version
hashes, and fails with `NSPersistentStoreIncompatibleVersionHashError` when
the service has moved on. To pick the version that matches:

```objc
NSDictionary *metadata = [ODataIncrementalStore metadataForServiceAtURL:url options:nil error:&error];
NSManagedObjectModel *model = [NSManagedObjectModel mergedModelFromBundles:nil forStoreMetadata:metadata];
```

## Saving

A save is POST, PATCH and DELETE, and `$ref` requests for relationships; two
or more are one `$batch` change set, so a save takes effect whole or not at
all. Every write carries the entity's ETag. A write the service refuses as
stale (`412`), or of an entity it no longer has (`404`), fails the save as
Core Data's own stores fail one: `NSPersistentStoreSaveConflictsError`, with
an `NSMergeConflict` per object holding what the service has now. A context
with a merge policy settles it and saves again by itself:

```objc
context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;   // my changes win, property by property
```

## Actions and functions

A service's actions and functions are its entities' methods over the network,
and are called that way: one bound to an entity type on an object, one bound
to a collection on an entity, an unbound one on the context.

```objc
NSManagedObject *airline = [russell invokeODataOperation:@"GetFavoriteAirline" parameters:nil error:&error];

ODataOperationCall *call = [ODataOperationCall callOfOperation:@"GetNearestAirport" inContext:context];
call.parameters = @{ @"lat": @33.94, @"lon": @-118.4 };
NSManagedObject *airport = [call invoke:&error];
```

Parameters are written as their declared types say. An entity comes back as a
managed object in the context, a collection of them as an array, anything else
as the store reads attributes. `-invokeWithTarget:action:` calls without
waiting. A function can also be filtered and sorted by
(`ODataFunctionExpression`, `ODataSortDescriptor`).

`ois-model --classes DIR` writes classes for the entities, with the operations
as methods:

```objc
Airline *airline = [russell getFavoriteAirline:&error];
Airport *airport = [TripPinService getNearestAirportInContext:context lat:@33.9 lon:@-118.4 error:&error];
```

Each entity gets `_Person`, written again with the model, and `Person`, written
once, for your own code.

## More than fetch and save

- **Search**: `ODataSearchPredicate` is `$search`, ANDed with the rest of a
  predicate.
- **Grouping**: a dictionary fetch with `propertiesToGroupBy` and aggregate
  expressions is `$apply`, where the service has it.
- **Computed values**: a dictionary fetch's non-aggregate expression
  descriptions (`unitPrice * 2`) are `$compute`, with a 4.01 service.
- **Application time**: `ODataTemporalPredicate` is `$at` or `$from`/`$to`;
  `-performTemporalAction:onEntityNamed:deltaTimeslices:context:error:` calls
  `Temporal.Update`, `Upsert` and `Delete`.
- **Streams**: `ODataStreamTransfer` downloads a media entity's or a stream
  property's content to a file, kept while its media ETag holds, and uploads
  one.
- **Changes at the service**: `-fetchRemoteChanges:` follows delta links (or
  reads the sets again and compares, where a service gives none) and answers a
  notification to merge; with `NSPersistentHistoryTrackingKey` the changes,
  and every save, are persistent history transactions.

```objc
NSNotification *changes = [store fetchRemoteChanges:&error];   // the first call starts tracking
[context mergeChangesFromContextDidSaveNotification:changes];
```

## Threading

`NSIncrementalStore` callbacks are synchronous. **Do not use this store on the
main queue**: use a private-queue context.

Requests go out through a transport and come back by target-action: an
`ODataExchange` carries the request, and `-finish` sends its action to its
target once the response (or an error) is in. `ODataClient` offers the same
(`-sendRequest:target:action:`), and its synchronous methods, which the store
uses, wait on a condition for the exchange to finish. A transport of your own
(`ODataIncrementalStoreTransportOption`) implements one method:

```objc
- (void)startExchange:(ODataExchange *)exchange
{
  // send exchange.request; then, now or later, on any thread:
  exchange.URLResponse = response;
  exchange.data = data;          // or exchange.error = error;
  [exchange finish];
}
```

It must not finish by waiting for the thread that started the exchange: that
thread is waiting for `-finish`, not running its run loop.

## Reading OData's URL syntax

`ODataExpression.h` is the other direction, for a service (and for tests): it
parses a resource path with its key predicates, and the system query options,
into a tree that describes itself back as canonical OData.

```objc
ODataQueryOptions *options = [ODataQueryOptions optionsWithQuery:@{ @"$filter": @"Products/any(p:p/UnitPrice gt 20)",
                                                                   @"$expand": @"Category($select=Name)" } error:&error];
```
