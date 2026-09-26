# OData server: design

**Status: milestones 1 to 4 are implemented** (see Milestones): the core
(`ODataService`, `ODataEntitySetHandler`, `ODataReply`), `$metadata` from
the model (`ODataMetadataWriter`), `$filter` to `NSPredicate`
(`ODataPredicateBuilder`), and the HTTP adapter with `ois-serve`
(`Server/`). Operations, `$batch` and the Workbench's move to the server
are next. Where the code went differently from the plan, the sections below
say so.

ODataIncrementalStore is a client: Core Data on one side, a remote OData v4
service on the other. The server is the same mapping run the other way: an
OData v4 service whose entity sets are a Core Data model, written in
Objective-C, built on modern GNUstep (clang, libobjc2, gnustep-base,
FreeCoreData) and on Cocoa, with no platform-specific code in its core.

## Goals

- Let an application serve its Core Data model as an OData 4.01 API
  (answering 4.0 clients too), with little code of its own. The workflow:
  1. Design the model in FreeCoreData's Model Builder (or Xcode).
  2. Add the OData mappings: set names, wire names, keys, vocabulary
     annotations. They go in `userInfo`, which Model Builder already edits.
  3. Implement the actions and functions.
  4. Where the default is not enough, override what an entity set does:
     get by key, fetch by predicate, insert, update, delete.
  5. Run it as a service behind a reverse proxy.
- Serve over OData JSON: the service document, `$metadata`, entity sets,
  single entities, navigation, create, update and delete, and
  operations.
- Any Core Data store behind it: SQLite, in-memory, and FreeCoreData's
  PostgreSQL and MySQL/MariaDB backends. Those are `NSIncrementalStore`s
  that register their own store type, so the service needs no code for
  them; the store type and URL are configuration.
- Cover at least everything the client sends. The client is the first
  consumer, and the snapshots in `Tests/Snapshots/` are the first
  specification.
- One core for both platforms, testable with no sockets.
- An embedded HTTP listener for development, tests and production behind
  the proxy. The proxy owns TLS, HTTP/2, compression, rate limiting and,
  at first, authentication. The listener binds to loopback by default.
- Runs as an OS service: a systemd unit on Linux, a launchd job on macOS.
  It logs to standard error and stops cleanly on `SIGTERM`.

## Non-goals, at first

- `$batch`, `$apply`, `$search`, delta links, async requests, streams and
  media entities.
- XML (Atom) payloads. JSON only, as the client speaks.
- Being a general-purpose web framework.

## Architecture

```
            reverse proxy (TLS, auth, limits)
                        │ HTTP/1.1
┌───────────────────────▼──────────────────────────┐
│ HTTP adapter          vendored GCDWebServer      │  thin, replaceable
├──────────────────────────────────────────────────┤
│ ODataService          request → response         │  no sockets
│   router  ·  query options  ·  serializer        │
├──────────────────────────────────────────────────┤
│ ODataEntitySetHandler  one per set               │  the default: Core Data;
│   fetch · by key · count · insert · update · del │  subclass to change it
├──────────────────────────────────────────────────┤
│ shared with the client                           │
│   ODataPropertyMapper · ODataResourceIdentifier  │
│   literals · $filter grammar · CSDL              │
└──────────────────────────────────────────────────┘
```

### The core takes a request and returns a response

`ODataService` takes an `NSURLRequest` (method, URL, headers, body) and
answers with a status, headers and body. It never sees a socket. It is an
`ODataTransport`: it takes an `ODataExchange`, fills in the response and
finishes it, target-action, as every transport does; an in-memory service
finishes before returning. So a service can be handed to
`ODataIncrementalStore` as its transport:

```objc
ODataService *service = [[ODataService alloc] initWithPersistentStoreCoordinator:coordinator
                                                                     serviceRoot:root];
// A Core Data store talking to a Core Data store through OData, in-process.
options = @{ ODataIncrementalStoreTransportOption: service };
```

This gives a full round-trip test with no network on both platforms
(`-[ODataServiceTests testIncrementalStoreOverTheService]`). It is also
what the Workbench example does today with `WorkbenchEngine`, which is
a hard-coded, dictionary-backed prototype of this core (routing, `$filter`,
`$orderby`, `$select` and `$expand` evaluated over the library's parser,
ETags, a hand-written `$metadata`). The server replaces it: Workbench
becomes an `ODataService` over an in-memory Core Data store, seeded with
the same rows.

### Handlers, not a data source

The plan had an `ODataDataSource` protocol under the service, with a Core
Data implementation, and handlers on top. In the code the handler is the
only seam: `ODataEntitySetHandler`'s default methods are the Core Data
implementation, and a set that is not Core Data would be a handler that
overrides all of them. One layer fewer, and nothing lost.

Each request gets its own private-queue context on the service's
coordinator, and all work runs inside `-performBlockAndWait:`, or
`-performBlock:` once a reply is deferred. On GNUstep that depends on
libdispatch having been built before gnustep-base, which
`build-gnustep.sh` in gnustep-patches already guarantees and verifies.

### What an application writes

The defaults serve the model as it is. An application adds to them in
two places, entity sets and operations, and both answer through a reply
(below). Neither needs a subclass of the service.

**Entity sets.** Each set is handled by an `ODataEntitySetHandler`. The
default one does everything over the data source:

| Method | Default |
|---|---|
| get by key | a fetch on the key attributes and the visible rows, limit 1 |
| fetch | the request's predicate, sort, limit, offset and prefetching |
| count | `countForFetchRequest:` |
| insert | a new object from the body's values; a missing integer key is one more than the largest, a string or UUID key a new UUID |
| update | the body's values set on the object (`If-Match` is checked first) |
| delete | `-deleteObject:` (`If-Match` is checked first) |

The service converts the body before a handler sees it: values arrive
keyed by Core Data property name, as Core Data values, with
`@odata.bind` resolved to managed objects. It saves after the handler
answers, and turns a failed validation into a `400` with a detail for each
property.

- A subclass overrides any of these for one set and is registered by
  set name (`-setHandler:forEntitySet:`). Typical uses:
  - fetch: add a predicate that scopes rows to the caller;
  - insert: fill in server-side values;
  - delete: refuse, or mark as deleted instead.
- `allowsInsert`, `allowsUpdate` and `allowsDelete` switch a method off;
  it then answers `405`. (Planned: the set's `Capabilities.*Restrictions`
  in `$metadata`, derived from these.)
- `-predicateForVisibleObjectsInRequest:` scopes the rows the caller may
  see however they are reached: fetched, by key, through navigation,
  through `$expand`, or named in `@odata.bind`. That is where per-caller
  rows belong, rather than in an overridden fetch, which `$expand` would
  go around.
- Each method runs inside the request's context's
  `-performBlockAndWait:`. It gets the parsed request, never the raw
  URL, so it cannot get the grammar wrong, and answers through its
  reply.

**Operations.** Objective-C has no annotations, and Core Data models
cannot declare operations. Protocols take their place: an application
declares its operations in a protocol and implements them as ordinary
methods. The framework reads the protocols at startup, then does the
rest:

- writes the operations into `$metadata`;
- routes a GET or a POST to the right selector;
- decodes the parameters with the value coder the client uses;
- calls the method through `NSInvocation`;
- encodes the result, or the error.

The application never touches the protocol itself. `NSXPCConnection`
works the same way, with a protocol as the whole contract for remote
calls.

```objc
@protocol PersonActions <ODataActions>
- (void)shareTripWithUserName:(NSString *)userName tripId:(int32_t)tripId reply:(ODataReply *)reply;
@end

@protocol PersonFunctions <ODataFunctions>
- (Airline *)getFavoriteAirline:(ODataReply *)reply;
+ (NSArray *)peopleNearAirport:(Airport *)airport reply:(ODataReply *)reply;
@end

@interface Person : NSManagedObject <PersonActions, PersonFunctions>
@end

@implementation Person
- (Airline *)getFavoriteAirline:(ODataReply *)reply
{
  return self.trips.lastObject.airline;
}
…
@end
```

This works because clang records extended type encodings for a
protocol's methods. They name each object parameter's class and
protocols, where a class's own methods record only `@`:

```
getFavoriteAirline:              @"Airline" … @
discountBy:forItems:tag:reply:   d … d @"NSArray" @"<Marker>" @
+countOlderThan:reply:           i … q @
```

Both runtimes give these the same, through `_protocol_getMethodTypeEncoding`;
this was checked on Apple's runtime and on libobjc2. Every fact about an
operation comes from something the language already has:

| OData needs | Read from |
|---|---|
| operation and parameter names | the selector. `shareTripWithUserName:tripId:reply:` is `ShareTrip(UserName, TripId)`, named by `ODataPropertyMapper`'s rules, as properties are. |
| parameter and return types | the extended encoding: `int32_t` is `Edm.Int32`, `int64_t` `Edm.Int64`, `double` `Edm.Double`, `BOOL` `Edm.Boolean`, `NSString *` `Edm.String`, `NSDate *` `Edm.DateTimeOffset`, `NSDecimalNumber *` `Edm.Decimal`, `NSUUID *` `Edm.Guid`, `NSData *` `Edm.Binary`, a managed object class its entity type |
| function or action | the protocol it inherits from: `<ODataFunctions>` or `<ODataActions>` |
| binding | an instance method of an entity's class is bound to the entity; a class method (`+`) is bound to its collection; a method of the service's delegate is unbound, reached through an import |
| nullability | a scalar is non-nullable; an object is nullable unless declared `nonnull` |

The runtime cannot see two things. Generics are erased, so
`NSArray<Person *> *` reads as `NSArray`. And an `NSNumber *` parameter,
which is how a nullable number is written, says nothing about which
number type it is. A class method supplies the rest, and renames what
the conventions get wrong:

```objc
+ (NSDictionary<NSString *, NSString *> *)ODataOperationTypes
{
  return @{ @"peopleNearAirport:reply:": @"Collection(Microsoft.OData.SampleService.Models.TripPin.Person)",
            @"shareTripWithUserName:tripId:reply:.tripId": @"Edm.Int32" };
}
```

A declaration the framework cannot type fully stops the service at
startup, naming the selector, rather than failing on the first call.
`ois-model --classes` already gives the client the same methods
(`-[Person getFavoriteAirline:]`); it will also write these protocols
from `$metadata`, so client and server can share one. Declarations in
CSDL, generating the protocol, can come later on top of this. The
protocol stays what the framework reads.

**Replies.** Every operation and every entity-set handler method takes
an `ODataReply` as its last parameter. The framework is the method's
only caller, and the reply is its end of the call. There are two ways to
answer:

- **At once.** Return the result. A method that fails calls
  `[reply failWithError:]` and returns. Most methods look like this, and
  never think about asynchrony.
- **Later.** Call `[reply defer]`, start the work, and return; whatever
  the method returns is then ignored. When the work ends, possibly on
  another thread, call `[reply finishWithResult:]` or
  `[reply failWithError:]`. Work that waits on something else is the
  reason for this: a payment provider, another service, a long query.

So only the code that actually waits is asynchronous, and there are no
blocks in the API. A deferred method runs its synchronous part inside
the request context's `-performBlockAndWait:` like any other. Whatever
it does with the context afterwards goes through `-performBlock:`. The
reply keeps the context alive until it is finished. (Planned: a reply
that is never finished is answered `504` after the request's timeout.
Today the request waits.)

The service's own steps continue through the same replies, target-action,
with no blocks: each step names the method its reply goes on in.

### Running it

`ois-serve` (`Server/ois-serve.m`) reads its settings from the property
list `-Config` names, and any of them from the command line, which wins
(`-Port 9000`): `Model`, `StoreType` (`SQLite`, `InMemory`, `XML`, or a
type a backend registers, such as `CDPostgreSQLStore`), `StoreURL`,
`StoreOptions`, `ServiceRoot` (the public URL, which `@odata.context` and
next links begin with), `Port`, `Localhost`, `MaxPageSize`, `MaxVersion`,
`Namespace`, `Container`, and `Bundles`. A bundle's principal class that
conforms to `ODataServiceConfiguring` is sent `+configureService:` before
the first request: that is where an application registers its handlers.
`-PrintMetadata YES` prints `$metadata` and exits.

It serves until `SIGINT` or `SIGTERM`, logs to standard error, and exits 0.
An application that would rather link the library runs the same
`ODataHTTPServer` from its own `main`. `Server/Examples/` has a
configuration for the Catalog model, a systemd unit, a launchd job, and
nginx and Caddy configurations.

### The HTTP adapter

This is the only part that touches sockets, and it should stay small
enough to replace. Its whole job is to turn bytes into an `NSURLRequest`,
call `ODataService`, and write the response back.

**Choice: GCDWebServer 3.5.4, vendored and ported.** Four candidates
were compared: the three first proposed, plus GCDWebServer, the project
OCFWebServer was forked from. All four were read, and the two GCD-based
ones were syntax-checked against gnustep-base (libobjc2, ARC):

| | GCDWebServer | OCFWebServer | Barista | ohttpd (CGIKit) |
|---|---|---|---|---|
| License | BSD-3 | BSD-3 | MIT | none ("All rights reserved") |
| Last change | 2020 (3.5.4) | 2013 | 2013 | 2013 |
| Size | 4.3K lines | 2.4K | 2.7K + 7.4K GCDAsyncSocket | 10K |
| I/O | GCD `dispatch_source`, `dispatch_io`, BSD sockets | the same (a 2013 fork of GCDWebServer) | GCDAsyncSocket (CFStream) | GCDAsyncSocket |
| HTTP parsing | `CFHTTPMessage` | `CFHTTPMessage` | `CFHTTPMessage`, whole message buffered | its own |
| IPv6 | yes | no | via the socket | via the socket |
| Chunked request bodies | yes | no | no | no |
| Streamed responses | yes | no | no | no |
| Keep-alive | no, `Connection: close` | no | no | no |
| Dependencies | none | none | JLRoutes, GRMustache (CocoaPods) | none |
| On GNUstep | 81 errors, nearly all `CFHTTPMessage`/`CFURL`/`CFUUID` | 154 errors: the same, plus IPv4-only BSD socket code (`sin_len`, `SO_NOSIGPIPE`) | CFStream under GCDAsyncSocket | not usable: no license |

OCFWebServer is on the list only as the fork: upstream kept going for
seven more years and fixed what matters here. Behind a proxy, chunked
request bodies matter because Caddy streams them; nginx buffers and
sends a length. Barista is a Sinatra-style framework over a large
socket library; the framework is the part we would throw away.

The port, kept as a patch over the pinned release so updates stay
possible:

- Replace `CFHTTPMessage` with a small request-head parser and
  response-head writer (request line, headers, `100-continue`). This is
  the bulk of the work, and the part the tests cover hardest.
- Replace `CFURL`/`CFUUID` with `NSURL`/`NSUUID`, and `st_mtimespec`
  with `st_mtim` on Linux.
- Drop Bonjour, NAT port mapping, digest authentication and iOS
  background suspension. Authentication belongs to the proxy or to the
  application's handlers.
- Add a size limit on request heads and bodies, and a read timeout.
- Keep-alive is not needed for a first version: nginx speaks HTTP/1.0 to
  upstreams by default. Add it later if Caddy's pooled connections show
  it is worth it.

It lives in `ThirdParty/GCDWebServer/` with its license; `PORTING.md`
there lists every change, and `upstream.diff` reapplies them to the
pristine release. It is built into `libODataHTTPServer` (`Server/`) only,
with `ODataHTTPServer`, which turns each request into an `ODataExchange`
for the service and the finished exchange back into a response. The
listener's own smoke test and `Server/Tests/ois-serve-check.m` run in CI on
both platforms.

Two things surfaced on the way. GCDWebServer's handler blocks capture a
block in another block, which libobjc2 leaked until
`libobjc2/stack-block-retain` in gnustep-patches; the port copies its
blocks itself, so it does not depend on the fix. And gnustep-base leaves
fast enumeration to `NSDictionary`'s subclasses, so the port's header
dictionary implements it.

## Mapping Core Data to OData

The server uses the same annotations the client reads, and the same
`ODataPropertyMapper`, so one model file describes both ends.

| Core Data | OData |
|---|---|
| `NSEntityDescription` | `EntityType` |
| `userInfo[@"OData.entitySet"]` | `EntitySet` name |
| attribute, via the mapper (`unitPrice` → `UnitPrice`) | `Property` |
| `userInfo[@"OData.property"]` | override a wire name |
| `userInfo[@"OData.key"]` | `Key` |
| `NSRelationshipDescription` | `NavigationProperty` |
| `userInfo[@"OData.etag"]` on an integer attribute: incremented by each update | `@odata.etag`, and `Core.OptimisticConcurrency` in `$metadata` |
| without one, a hash of the row's values | `@odata.etag` |

`$metadata` (CSDL XML) is generated from the model, not written by hand.

Requests map onto fetch requests, the reverse of `ODataQueryBuilder`:

| OData | Core Data |
|---|---|
| `$filter` | `NSPredicate` |
| `$orderby` | `sortDescriptors` |
| `$top`, `$skip` | `fetchLimit`, `fetchOffset` |
| `$select` | the properties written; the rows are fetched whole |
| `$expand` | `relationshipKeyPathsForPrefetching`, then inline, with its own options applied in memory |
| `$skiptoken` | the service's own: the offset of the next page |
| `Categories(1)/Products` | the destination's rows whose inverse leads to the parent's key: `category.id == 1`, `ANY suppliers.id == 1` |

Navigation compares keys, not objects. Every store compares attributes,
and a SQL store turns them into a plain `WHERE`; managed objects in a
predicate are harder on a store (FreeCoreData matched none of them in its
in-memory store, and raised when counting them, until FreeCoreData #41 and
gnustep-patches' `constant-expression-copy`).
| `/$count`, `$count=true` | `countForFetchRequest:` |
| `If-Match` | compare the ETag, `412 Precondition Failed` on mismatch |

### `$filter` to `NSPredicate`

The parsing exists: `ODataExpression.h` reads resource paths with their
key predicates and every system query option (`$filter` and `$orderby`
expressions with OData's precedence, lambdas, casts, function calls and
literals of every type; `$select`; `$expand` with options nested to any
depth), with a split lexer and a recursive descent parser, and describes
the tree back as canonical OData text. The client's tests already check
that every `$filter` the translator writes parses.

`ODataPredicateBuilder` builds the predicate from that tree, out of
`NSComparisonPredicate`, `NSCompoundPredicate` and `NSExpression` objects:
comparisons, `in`, `and`/`or`/`not`, arithmetic, `contains`,
`startswith`, `endswith`, `tolower`/`toupper`, `length`, `now`, `any` and
`all` (as `SUBQUERY`), `$count` of a to-many relationship, and parameter
aliases. `has`, casts, the date and math functions, and a service's own
functions answer `501`. Literals are typed by the attribute they meet.
`tolower(Name) eq 'abc'` becomes `name ==[c] 'abc'`, which a SQL store can
use without lowering every row. gnustep-base names its arithmetic
functions differently from Apple (`_add`, not `add:to:`) and has no
modulo, so `mod` is Apple only.
**It never builds a predicate by formatting a string for
`+predicateWithFormat:`**. The one exception is a key path off a lambda's
variable (`$v0.unitPrice`), which is made from a generated name and the
model's own property names, never from request text:

- A string built from request input is an injection vector.
- gnustep-base's predicate parser has quirks the client has already hit.
  It rewrites `BETWEEN` into `>=` / `<=` and wraps each bound in a second
  constant expression, so parsing is not a neutral step.

(Planned: the client's `ODataPredicateTranslator` and this builder tested
against each other: predicate → `$filter` → predicate, and `$filter` →
predicate → `$filter`, over the same table of cases.)

### Values are serialised by the model's types

Literal and JSON values are written according to the attribute's
`attributeType`, never by inspecting the `NSNumber`:

- On gnustep-base a BOOL is an `NSBoolNumber` with type code `C`. On Apple
  it is `c`. The client's BOOL handling broke on exactly this.
- Every row the server writes goes through this path, so the same mistake
  would corrupt every boolean, not one test.

The same applies to dates (`Edm.DateTimeOffset`, UTC, ISO 8601), decimals
(`Edm.Decimal`, from `NSDecimalNumber` without going through `double`) and
UUIDs (`Edm.Guid`).

## Errors

Every failure is an OData error body with a status code: `400` for a query
that does not parse, `404` for an unknown set or key, `405` for a method a
resource does not allow, `412` for an ETag mismatch, `501` for a feature
outside the supported set, `406` and `415` for formats it does not speak.
Never a bare `500` for bad input. A handler reports with
`ODataServiceError(status, message)` (`ODataError.h`), whose code is the
status; the body's `code`, `message`, `target` and `details` are what the
client's `ODataError` keys read back.

## Testing

- **The core, without sockets.** `Tests/ODataServiceTests.m`, over the
  Catalog model in memory: `$metadata` (read back by the client's
  `ODataSchema`, and matching the model with no problems), query options,
  navigation, properties and `$value`, `$expand` with nested options,
  server-driven paging, create, update and delete with ETags, errors,
  metadata levels, a handler that hides rows and answers later.
- **Round trip.** `ODataIncrementalStore` over an in-process `ODataService`
  over an in-memory Core Data store: fetch, fault, insert, update and
  delete in one save, the backing store checked directly, and a change
  behind the client's back reported as a conflict.
- **HTTP adapter.** `Server/Tests/ois-serve-check.m`: requests over a real
  loopback socket, chunked bodies, errors, `HEAD`, concurrent requests.
- **Planned: snapshots, both ways.** Each file in `Tests/Snapshots/` sent
  to the service over the Catalog model seeded with the snapshot rows, and
  the response compared: status and headers exactly, JSON bodies as JSON.
- **Planned: parser pairs**, as above.

Everything runs in the existing CI: XCTest on macOS against Apple's Core
Data, and `tools-xctest` on Linux against FreeCoreData on the
gnustep-patches stack.

## Layout

For now the core is part of the one library, next to the client
(`Source/ODataService.m`, `ODataPredicateBuilder.m`,
`ODataMetadataWriter.m`); it needs nothing the client does not. The HTTP
adapter is a library of its own in `Server/`, with `ois-serve` and the
loopback check, so neither the client nor the core links the listener.

The split into shared, client and server libraries is still open, and so
is its companion question: the repository and framework are named for the
client, and renaming them, or adding an umbrella name, is worth deciding
before the split rather than after.

## Milestones

1. ~~**Read-only core.**~~ Done: service document, `$metadata`, collections,
   entity by key (and key as segment), properties and `$value`, `$filter`,
   `$orderby`, `$top`, `$skip`, `$select`, `$count`, paging.
2. ~~**Navigation.**~~ Done: navigation paths and `$expand` with nested
   options, `$ref` and `/$count` within it. Not yet: `$levels`, casts.
3. ~~**Writes.**~~ Done: POST (to a set or through a navigation property),
   PATCH, PUT, DELETE, ETags with `If-Match` and `If-None-Match`,
   `@odata.bind`, `Prefer: return`. The client round trip passes. Not yet:
   deep inserts and updates, writing a single property.
4. ~~**HTTP adapter.**~~ Done: GCDWebServer vendored and ported,
   `ODataHTTPServer`, `ois-serve`, the loopback check in CI on both
   platforms, example units and proxy configurations.
5. **Operations**, declared in protocols, as above.
6. **`$batch`**, multipart and JSON. The client falls back to one request
   at a time without it, so a multi-object save is not atomic until then.
7. **Workbench on the server.** Replace `WorkbenchEngine` with an
   `ODataService` over an in-memory store.

## Open questions

- ~~ETags~~: both. A version attribute where `userInfo` names one (and
  `$metadata` says so with `Core.OptimisticConcurrency`), else a hash of
  the row's values.
- ~~Paging~~: `maxPageSize` on the service, and the client's
  `Prefer: odata.maxpagesize`, whichever is smaller; the client follows
  `@odata.nextLink` already.
- Authentication: left to the reverse proxy at first. If per-user data
  arrives, the data source needs to see the caller, which means the
  request, not only the query.
