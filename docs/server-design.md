# OData server: design

**Status: milestones 1 to 7 are implemented** (see Milestones): the core
(`ODataService`, `ODataEntitySetHandler`, `ODataReply`), `$metadata` from
the model (`ODataMetadataWriter`), `$filter` to `NSPredicate`
(`ODataPredicateBuilder`), the HTTP adapter with `ois-serve` (`Server/`),
operations declared in protocols (`ODataOperationCatalog`), and `$batch`
(`ODataServiceBatch`); and the Workbench's built-in service is this server
(milestone 7). Where the code went differently from the plan, the sections
below say so.

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

- `$apply`, `$search`, delta links, async requests, streams and media
  entities. (`$batch` was one; it is done.)
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
what the Workbench's built-in service is: `WorkbenchEngine` wraps an
`ODataService` over the Catalog model in an in-memory Core Data store,
seeded with Northwind's rows, logs each exchange, and declares a few
operations of its own. It replaced a hand-written, dictionary-backed
prototype of this core, about 900 lines.

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
  it then answers `405`, and `$metadata` says so on the set
  (`Capabilities.InsertRestrictions` and its siblings), as the handler
  allows at the time of the request.
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
| operation and parameter names | the selector. `shareTripWithUserName:tripId:reply:` is `ShareTrip(UserName, TripId)`: the first keyword up to `With` names the operation, the rest the first parameter. Without `With`, the whole keyword names the operation and its last word the parameter: `pricierThanPrice:reply:` is `PricierThanPrice(Price)`. Named by `ODataPropertyMapper`'s rules, as properties are. |
| parameter and return types | the extended encoding: `int32_t` is `Edm.Int32`, `int64_t` `Edm.Int64`, `double` `Edm.Double`, `BOOL` `Edm.Boolean`, `NSString *` `Edm.String`, `NSDate *` `Edm.DateTimeOffset`, `NSDecimalNumber *` `Edm.Decimal`, `NSUUID *` `Edm.Guid`, `NSData *` `Edm.Binary`, a managed object class its entity type |
| function or action | the protocol it inherits from: `<ODataFunctions>` or `<ODataActions>` |
| binding | an instance method of an entity's class is bound to the entity; a class method (`+`) is bound to its collection; a method of the service's `serviceOperations` object is unbound, reached through an import. Only protocols a class adopts itself count. |
| nullability | a scalar is non-nullable; an object is nullable |

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

+ (NSDictionary<NSString *, NSString *> *)ODataOperationNames
{
  return @{ @"namesInCategory:": @"ProductNames" };
}
```

The keys are selectors as written, a parameter after a dot by the name
the rules give it. A declaration the framework cannot type is listed in
`operationProblems`, naming the selector and the key that would fix it,
and left out of `$metadata`; `ois-serve` refuses to start with any. So a
mistake shows at startup, not at the first call.
`ois-model --classes` already gives the client the same methods
(`-[Person getFavoriteAirline:]`); it will also write these protocols
from `$metadata`, so client and server can share one. Declarations in
CSDL, generating the protocol, can come later on top of this. The
protocol stays what the framework reads.

As built:

- **Arguments.** A function's come from the URL: literals, parameter
  aliases, and aliases whose value is JSON (`SumOfPrices(Prices=@p)?@p=[1.5,2.25]`),
  which is how the client passes complex values and collections. An
  action's come from its JSON body. Entities are passed by reference
  (`{"@odata.id": "Products(1)"}`). A missing number, an unknown
  parameter, or a value of the wrong type is a `400`.
- **The call.** Through `NSInvocation`, inside the request's context. The
  reply's `request` gives the method the context; for an operation bound
  to a collection, `request.collectionFetchRequest` is the collection:
  `Categories(1)/Products/Default.PricierThanPrice(Price=18)` sees the
  category's products only.
- **After it.** An action's changes are saved, as a write's are; a
  function's are rolled back. The result is written by its declared type:
  an entity with `$select` and `$expand` applied, a collection of them, a
  value or a collection of values, each with its context URL; nothing is
  a `204`.
- **Composing.** Functions are composable: the entities one returns are
  read on as any collection or entity, the rest of the path and the query
  options included (`Products/Default.PricierThanPrice(Price=10)?$filter=…&$top=2`,
  `…/$count`, `Products(4)/Default.CheapestInCategory()/Category`). An
  action's result, and a value, cannot be read on from (`400`).
- libobjc2's `Protocol` objects cannot be retained, so the catalog keeps
  them as pointers; Apple's can.
- The client calls these operations as it calls any service's
  (`-invokeODataOperation:parameters:error:`, `ODataOperationCall`), in
  `ODataServiceTests testClientCallsOperations`.

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
reply keeps the context alive until it is finished. A deferred reply that
is not answered within the service's `replyTimeout` (60 seconds by
default) is answered `504`, and a later answer is ignored.

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
`all` (as `SUBQUERY`), `$count` of a to-many relationship, parameter
aliases, type casts and `isof`, and `year`, `date`, `floor`, `ceiling`
and `round` compared with a literal, and `has` (all below). Casts to
primitive types, the other date functions (`month`, `day`, `hour`, …), and
a service's own functions answer `501`. Literals are typed by the attribute they meet.
`tolower(Name) eq 'abc'` becomes `name ==[c] 'abc'`, which a SQL store can
use without lowering every row. gnustep-base names its arithmetic
functions differently from Apple (`_add`, not `add:to:`) and has no
modulo, so `mod` is Apple only.
Type casts (`Default.Manager/Budget`, `Manager/Default.Manager/Budget`,
`Reports/Default.Manager/any(…)`, `Reports/Default.Manager/$count`,
`cast(Manager,Default.Manager)`) and `isof` (`isof(Default.Manager)`,
`isof(Manager,Default.Manager)`) ask an object's type with `entity IN
{the type and its subentities}`. Apple's stores all answer `entity` in a
predicate, of the fetched object, of one it reaches through a
relationship and of a `SUBQUERY`'s variable, in SQL or evaluated on their
nodes; FreeCoreData's do too since its atomic stores' nodes answer it.
Whatever reads a cast object is behind that test in an `AND`, since a
store that evaluates a predicate itself raises when asked an Employee's
`budget`; and where the object is not of the type the cast is null, as
the URL conventions have it: `Default.Manager/Budget eq null` holds for
every Employee that is not a Manager (`NOT test OR budget == nil`).
Ordering by a cast is `501`: a store that sorts objects would ask them
all.
`year`, `date`, `floor`, `ceiling` and `round` have no `NSPredicate`
function a store evaluates, but each is a step function: compared with a
literal, it is a range of its argument. `year(Hired) eq 2025` is
`hired >= 2025-01-01T00:00Z AND hired < 2026-01-01T00:00Z` (in UTC, as
dates are written), `floor(Price) le 18` is `price < 19`, `round(Price)
eq -5` is `-5.5 < price <= -4.5` (half away from zero); `ne` is outside
the range or null, `in` each value's range, and a fraction makes `eq`
false and moves the others to the whole number beside it. A SQL store can
use an index for that. Compared with anything but a literal, or ordered
by, they are `501`; `month`, `day` and the rest are not ranges, and are
`501` too.
`has` has no bitwise `and` a store evaluates either, but an enumeration
has few values: a flags one's are the combinations of its members' bits,
a plain one's its members'. `Colours has Default.Colour'Red'` is
`colours IN {1, 3, 5, 7}`, the values that have the bit, which every
store takes. An enumeration kept as text, or of more than 16 flags, is
`501`.
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
   options, `$ref` and `/$count` within it, `$levels` (a number, or `max`,
   taken as 32 and never through the same entity twice); type casts in the
   path (`Employees/Default.Manager`, `Employees(2)/Default.Manager/Budget`,
   and inserting through one) and in `$select` (`Default.Manager/Budget`);
   references (`Products(1)/Category/$ref`, `Categories(1)/Products/$ref`).
   Also casts in `$filter` and `isof`, as above.
3. ~~**Writes.**~~ Done: POST (to a set or through a navigation property),
   PATCH, PUT, DELETE, ETags with `If-Match` and `If-None-Match`,
   `@odata.bind`, `Prefer: return`. The client round trip passes. Also:
   - a single property (`PUT`/`PATCH` `{"value": …}`, `PUT` its `$value`,
     `DELETE` it to null);
   - references: `PUT` and `DELETE` a to-one `$ref`, `POST` to a to-many
     one and `DELETE` from it by `$id` or by key, which is how the client
     changes relationships;
   - deep inserts, to any depth, each entity through its set's handler (one
     that answers later cannot be waited for there, `501`), answered with
     what was created expanded;
   - deep updates (Part 1 section 11.4.3.1): a nested entity that names
     one there (by `@id`, or its key) updates it, as by PATCH, and one
     that names none is created; a to-one takes an entity or null, a
     to-many the full set, those it leaves out unlinked, not deleted; and
     `Nav@delta` changes a collection: entries added or updated, `@removed`
     ones unlinked, or deleted for the reason `deleted`. Each nested
     change goes through its set's handler as the set allows it (`405`
     otherwise), and a nested `@odata.etag` must match (`412`).
4. ~~**HTTP adapter.**~~ Done: GCDWebServer vendored and ported,
   `ODataHTTPServer`, `ois-serve`, the loopback check in CI on both
   platforms, example units and proxy configurations.
5. ~~**Operations**~~, declared in protocols, as above. Done: functions and
   actions bound to entities and collections, and unbound ones through
   imports, answering at once or later, and composing on a function's
   entities.
6. ~~**`$batch`**~~, multipart and JSON. Done:
   - Each request is answered as any other, in order. A change set's (an
     atomicity group's) requests share one context, saved once they have
     all succeeded; if one fails, or the save does, none takes effect, and
     the change set is answered with that failure alone (in JSON, the
     others of the group with `424`).
   - `$1` names what request 1 created, in a URL and in `@odata.bind`; the
     batch's own headers (who is asking) hold for each request under its
     own; the batch stops at the first failure unless the client prefers
     `odata.continue-on-error`; no reads in a multipart change set.
   - A handler that answers later holds nothing up: the batch goes on when
     its exchange finishes, target-action.
   - The client's multi-object saves are atomic through it
     (`testClientSavesAreAtomic`). Inserts join the change set when the
     client supplies keys (`ODataIncrementalStorePostOnObtainPermanentIDsOption`
     set to NO); by default it POSTs them first, for the service to assign
     keys, and those are not part of the save's change set.
   - Found on the way: the client took the ETag of an entity from any
     payload that named it, a key-only reference inside another row
     included, while keeping older values, so its next update overwrote a
     change it had not seen. It now takes an ETag only with the row
     (`testReferencesDoNotRefreshTheClientsETag`). And with port 0,
     GCDWebServer can pick a port that is free for IPv4 and taken for
     IPv6; `ODataHTTPServer` tries another.
7. ~~**Workbench on the server.**~~ Done: `WorkbenchEngine` is an
   `ODataService` over an in-memory store with operations of its own, and
   the Workbench's self-test (59 checks, 4 of them the built-in
   operations) passes on both platforms. The model is copied before its
   Product entity gets its own class, since a model loaded again may be
   the one the client already uses; FreeCoreData models can be copied
   since #43.

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
