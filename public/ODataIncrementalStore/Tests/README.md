# Tests

XCTest. **No live OData service.** Every HTTP exchange is a JSON snapshot
under `Snapshots/`, written against the OASIS OData v4 protocol (Part 1 +
ABNF). The transport (`ODataSnapshotTransport`) matches method + path +
query + body and replays the recorded status/headers/payload.

```
make                 # build the library
make -C Tests run-tests
```

Translator-only (in-tree Core Data stub):

```
make OIS_COREDATA=stub
make -C Tests OIS_COREDATA=stub run-tests
```

Apple: open `ODataIncrementalStore.xcworkspace`, scheme
**ODataIncrementalStoreTests**, ⌘U. Same `.m` files, snapshots copied
into the test bundle. SwiftPM: `swift test`.

| Class | What it pins |
|---|---|
| `ODataPredicateTranslatorTests` | NSPredicate → `$filter` ABNF (`eq`/`gt`/`and`/`startswith`/…) |
| `ODataQueryBuilderTests` | `$filter` `$orderby` `$top` `$skip` `$select` `$expand` `/$count` |
| `ODataResourceIdentifierTests` | `EntitySet(key)` / compound keys |
| `ODataSnapshotStoreTests` | `NSIncrementalStore` over the snapshot tape: fetch, fault, expand, POST, PATCH+ETag, 412, DELETE |

To add a case: drop a JSON file in `Snapshots/` with `request` and `response`,
cite the spec section in `spec`, then assert the store method that should
produce that request.
