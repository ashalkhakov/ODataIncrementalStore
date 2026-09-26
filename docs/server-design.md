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

- Serve a Core Data model over OData v4 JSON: the service document,
  `$metadata`, entity sets, single entities, navigation, and create, update
  and delete.
- Cover at least everything the client sends. The client is the first
  consumer, and the snapshots in `Tests/Snapshots/` are the first
  specification.
- One core for both platforms, testable with no sockets.
- An embedded HTTP listener good enough for development and tests.
  Production traffic goes through a reverse proxy (nginx, Caddy), which
  owns TLS, HTTP/2, compression, rate limiting and, at first,
  authentication.

## Non-goals, at first

- `$batch`, `$apply`, `$search`, delta links, async requests, OData
  actions and functions, streams and media entities.
- XML (Atom) payloads. JSON only, as the client speaks.
- Being a general-purpose web framework.

## Architecture

```
            reverse proxy (TLS, auth, limits)
                        │ HTTP/1.1
┌───────────────────────▼──────────────────────────┐
│ HTTP adapter          embedded server (OCFWeb?)  │  thin, replaceable
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
a hard-coded, dictionary-backed prototype of this core (routing, a `$filter`
parser with lambdas, `$expand`, ETags, a hand-written `$metadata`). The
server replaces it: Workbench becomes an `ODataService` over an in-memory
Core Data store, seeded with the same rows.

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

### The HTTP adapter

This is the only part that touches sockets, and it should stay small enough
to replace. The candidate is **OCFWeb** (MIT, around 1K lines on top of
OCFWebServer, SOCKit and GRMustache). Its README claims OS X and iOS only.
The first task is to find out what it takes to build on GNUstep. It likely
needs CFNetwork-style APIs and dispatch sources; libs-corebase covers only
part of that. There are two fallbacks:

- A minimal HTTP/1.1 listener on `NSFileHandle`
  (`-acceptConnectionInBackgroundAndNotify`) or plain BSD sockets. Both
  exist on both platforms, and behind a reverse proxy the parser has little
  to handle: no TLS, no HTTP/2, and keep-alive is optional.
- A small C HTTP library, wrapped.

Either way, the adapter's whole job is to turn bytes into an `NSURLRequest`,
call `ODataService`, and write the response back.

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

Parse `$filter` into an AST, then build the predicate from
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
4. **HTTP adapter.** OCFWeb on GNUstep, or the fallback. A loopback test in
   CI, and an example service behind a reverse proxy config.
5. **Workbench on the server.** Replace `WorkbenchEngine` with an
   `ODataService` over an in-memory store.

## Open questions

- Can OCFWeb (with OCFWebServer, SOCKit and GRMustache) build on GNUstep,
  and at what cost? This decides milestone 4.
- ETags: a version attribute named by `userInfo`, or a hash of the row's
  values? The client only needs them to be opaque and to change on update.
- Paging: server-driven paging (`@odata.nextLink`) with a default page
  size, which the client would then have to follow.
- Authentication: left to the reverse proxy at first. If per-user data
  arrives, the data source needs to see the caller, which means the
  request, not only the query.
