# Tests

XCTest. **No live OData service.** Every HTTP exchange is a JSON snapshot
under `Snapshots/`, written against the OASIS OData v4 protocol (Part 1 +
ABNF). The transport (`ODataSnapshotTransport`) matches method + path +
query + body and replays the recorded status/headers/payload.

The suite loads **`Examples/Catalog/Catalog.xcdatamodeld`** — the same
model as Catalog.app and Workbench.app. There is no programmatic
`NSManagedObjectModel`. Xcode compiles the `.xcdatamodeld` to `.momd` in
the test bundle; GNUstep / FreeCoreData reads the XML package.

```
make                 # build the library
make -C Tests run-tests
```

Requires FreeCoreData on GNUstep, or Apple Core Data via the Xcode
scheme **ODataIncrementalStoreTests** (⌘U).

| Class | What it pins |
|---|---|
| `ODataPredicateTranslatorTests` | NSPredicate → `$filter` ABNF (`eq`/`gt`/`and`/`startswith`/…) |
| `ODataQueryBuilderTests` | `$filter` `$orderby` `$top` `$skip` `$select` `$expand` `/$count` |
| `ODataResourceIdentifierTests` | `EntitySet(key)` / compound keys |
| `ODataSnapshotStoreTests` | `NSIncrementalStore` over the snapshot tape: fetch, fault, expand, POST, PATCH+ETag, 412, DELETE |

To add a case: drop a JSON file in `Snapshots/` with `request` and `response`,
cite the spec section in `spec`, then assert the store method that should
produce that request.
