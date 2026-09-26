# OData server: design

**Status: future work.** Nothing here is implemented. This is the plan for
the server half of the project, written down so that the client can be
changed with it in mind.

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
│ ODataDataSource       protocol                   │
│   ODataCoreDataSource  (NSPersistentContainer)   │  the default
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
ODataService *service = [[ODataService alloc] initWithDataSource:source
                                                     serviceRoot:root];
// A Core Data store talking to a Core Data store through OData, in-process.
options = @{ ODataIncrementalStoreTransportOption: service };
```

This gives a full round-trip test with no network on both platforms. It is
also what the Workbench example does today with `WorkbenchEngine`, which is
a hard-coded, dictionary-backed prototype of this core (routing, `$filter`,
`$orderby`, `$select` and `$expand` evaluated over the library's parser,
ETags, a hand-written `$metadata`). The server replaces it: Workbench
becomes an `ODataService` over an in-memory Core Data store, seeded with
the same rows.

### The data source

`ODataDataSource` is a small protocol: describe the schema, fetch a
collection, fetch by key, count, insert, update, delete. `ODataCoreDataSource`
implements it over an `NSPersistentContainer` (or a coordinator), so the
store behind it can be SQLite, XML or in-memory on either platform.
Keeping it a protocol leaves room for sources that are not Core Data. The
first implementation is Core Data only.

Each request gets its own private-queue context, and all work runs inside
`-performBlockAndWait:`. On GNUstep that depends on libdispatch having been
built before gnustep-base, which `build-gnustep.sh` in gnustep-patches
already guarantees and verifies.

### What an application writes

The defaults serve the model as it is. An application adds to them in
two places, entity sets and operations, and both answer through a reply
(below). Neither needs a subclass of the service.

**Entity sets.** Each set is handled by an `ODataEntitySetHandler`. The
default one does everything over the data source:

| Method | Default |
|---|---|
| get by key | a fetch on the key attributes, limit 1 |
| fetch | the request's predicate, sort, limit, offset and prefetching |
| count | `countForFetchRequest:` |
| insert | a new object from the body, validated, saved |
| update | the object's changed properties, `If-Match` checked, saved |
| delete | `If-Match` checked, deleted, saved |

- A subclass overrides any of these for one set and is registered by
  set name (`-setHandler:forEntitySet:`). Typical uses:
  - fetch: add a predicate that scopes rows to the caller;
  - insert: fill in server-side values;
  - delete: refuse, or mark as deleted instead.
- A method that does not apply answers `405`. The set's
  `Capabilities.*Restrictions` in `$metadata` are derived from what the
  handler allows.
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
reply keeps the context alive until it is finished. A reply that is
never finished is answered `504` after the request's timeout.

### Running it

`ois-serve` is a tool configured by a property list:

- the model (`.momd`), and the store type and URL (`SQLite`,
  `CDPostgreSQLStore` with `postgresql://…`, …);
- the listen address and port;
- the public service root, which is used in `@odata.context` and next
  links, so they point at the proxy and not at loopback;
- the bundle holding the application's handlers and operations.

An application that would rather link the library runs the same
`ODataHTTPServer` from its own `main`. Example unit files for systemd
and launchd, and nginx and Caddy configs, ship with it.

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

It lives in `ThirdParty/GCDWebServer/` with its license, and is built
into the optional HTTP target only.

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
| a version attribute, or a hash of the row | `@odata.etag` |

`$metadata` (CSDL XML) is generated from the model, not written by hand.

Requests map onto fetch requests, the reverse of `ODataQueryBuilder`:

| OData | Core Data |
|---|---|
| `$filter` | `NSPredicate` |
| `$orderby` | `sortDescriptors` |
| `$top`, `$skip` | `fetchLimit`, `fetchOffset` |
| `$select` | `propertiesToFetch` (or fault and pick) |
| `$expand` | `relationshipKeyPathsForPrefetching`, then inline |
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

From that tree, build the predicate from
`NSComparisonPredicate`, `NSCompoundPredicate` and `NSExpression` objects.
**Never build a predicate by formatting a string for
`+predicateWithFormat:`**:

- A string built from request input is an injection vector.
- gnustep-base's predicate parser has quirks the client has already hit.
  It rewrites `BETWEEN` into `>=` / `<=` and wraps each bound in a second
  constant expression, so parsing is not a neutral step.

The client's `ODataPredicateTranslator` and this parser should be tested
against each other: predicate → `$filter` → predicate, and `$filter` →
predicate → `$filter`, over the same table of cases.

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
outside the supported set. Never return a bare `500` for bad input. The
client's `ODataError` domain is the other end of this, so the two should
agree on codes.

## Testing

- **Snapshots, both ways.** Each file in `Tests/Snapshots/` records a
  request and its response. The client tests replay them. The server tests
  send each recorded request to an `ODataService` over the Catalog model,
  seeded with the snapshot rows, and compare the response: status and
  headers exactly, and JSON bodies as JSON, not as bytes.
- **Round trip.** `ODataIncrementalStore` over an in-process `ODataService`
  over an in-memory Core Data store: fetch, fault, expand, insert, update
  with ETags, conflict, delete, then check the backing store directly.
- **Parser pairs.** The `$filter` ↔ `NSPredicate` tables above.
- **HTTP adapter.** A few requests over a real loopback socket, in CI on
  both platforms. That is enough to catch a broken listener; the protocol
  itself is tested without sockets.

Everything runs in the existing CI: XCTest on macOS against Apple's Core
Data, and `tools-xctest` on Linux against FreeCoreData on the
gnustep-patches stack.

## Layout

When the server lands, the tree splits into three libraries, each with a
GNUmakefile target and an Xcode target:

- **shared:** mapper, resource identifiers, literals, the `$filter`
  grammar, CSDL. Moved out of `Source/`, not rewritten.
- **client:** `ODataIncrementalStore`, `ODataClient`, `ODataQueryBuilder`,
  `ODataPredicateTranslator`.
- **server:** `ODataService`, `ODataDataSource`, `ODataCoreDataSource`, and
  the HTTP adapter as a separate, optional target so the core never links
  it.

The repository and framework are named for the client. Renaming them, or
adding an umbrella name, is worth deciding before the split rather than
after.

## Milestones

1. **Read-only core.** Service document, `$metadata`, collections, entity
   by key, `$filter`, `$orderby`, `$top`, `$skip`, `$select`, `$count`.
   The read-only snapshots pass against the server.
2. **Navigation.** `$expand` and navigation paths (`Products(1)/Category`).
3. **Writes.** POST, PATCH, DELETE, ETags and `If-Match`, `@odata.bind`.
   All snapshots pass, and so does the client round trip.
4. **HTTP adapter.** GCDWebServer vendored and ported, `ois-serve`, a
   loopback test in CI on both platforms, and example service units and
   nginx/Caddy configs.
5. **Workbench on the server.** Replace `WorkbenchEngine` with an
   `ODataService` over an in-memory store.

## Open questions

- ETags: a version attribute named by `userInfo`, or a hash of the row's
  values? The client only needs them to be opaque and to change on update.
  Either way, `$metadata` names the properties with
  `Core.OptimisticConcurrency`.
- Paging: server-driven paging (`@odata.nextLink`) with a default page
  size, which the client would then have to follow.
- Authentication: left to the reverse proxy at first. If per-user data
  arrives, the data source needs to see the caller, which means the
  request, not only the query.
