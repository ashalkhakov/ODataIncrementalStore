# ODataIncrementalStore

**LGPL-2.1-or-later.** An `NSIncrementalStore` that talks to a remote OData v4
service. Written in **modern Objective-C** for **libobjc2** so it builds on
GNUstep (clang + gnustep-base + [FreeCoreData](https://github.com/ashalkhakov/FreeCoreData))
and on Apple Core Data.

`NSFetchRequest` becomes `$filter` / `$orderby` / `$top` / `$expand`. Saves
become POST, PATCH, DELETE. ETags become optimistic locks.

This is the combination Microsoft’s [OData4ObjC](https://github.com/OData/odata4objc)
(archived 2013) and AFIncrementalStore each only half-did — in Objective-C 2.0,
not Swift, so GNUstep can actually run it.

## Runtime

OIS **will not compile** against GCC’s `libobjc`. The headers refuse anything
that is not clang + ObjC 2.0 + ARC + blocks.

| | |
|---|---|
| Language | Objective-C 2.0 (properties, literals, blocks, ARC, `NS_ENUM`, zeroing weak) |
| Runtime | **libobjc2** (`-fobjc-runtime=gnustep-2.0`) or Apple’s |
| ABI | Non-fragile. Ivars live in `@implementation { }` blocks. |
| Foundation | gnustep-base or Apple Foundation |
| Core Data | Apple Core Data, or **[FreeCoreData](https://github.com/ashalkhakov/FreeCoreData)** on GNUstep |
| Transport | `NSURLSession` + `NSCondition`, on Apple and on gnustep-base built with libcurl; `NSURLConnection` otherwise, which on GNUstep cannot follow relative redirects or read `$batch` responses |
| Strings | `-fconstant-string-class=NSConstantString` on GNUstep |

OIS is ARC. FreeCoreData is MRC (`-fno-objc-arc`). They link: methods named `new…` return +1 on both sides.

```
clang -fobjc-runtime=gnustep-2.0 -fobjc-arc -fblocks \
      -fconstant-string-class=NSConstantString
```

## GNUstep

CI builds this against a GNUstep stack from
[gnustep-patches](https://github.com/ashalkhakov/gnustep-patches) — see
`.github/workflows/ci.yml` for the exact recipe.

Install [FreeCoreData](https://github.com/ashalkhakov/FreeCoreData) first — it
is the Core Data runtime this store subclasses (`NSIncrementalStore`,
`NSIncrementalStoreNode`, the coordinator). Install its model compiler too
(`make -C Tools/momc install` there): the tests and example apps compile
`Catalog.xcdatamodeld` to `.momd`, which is what FreeCoreData loads. Then:

```sh
export GNUSTEP_MAKEFILES=/usr/share/GNUstep/Makefiles
. /usr/share/GNUstep/Makefiles/GNUstep.sh
make
make install
```

Without gnustep-make, clang + `gnustep-config` is enough:

```sh
make -f Makefile
./ois-filter 'unitPrice > 20 AND discontinued == NO'
# (UnitPrice gt 20) and (Discontinued eq false)
```

## Tests (XCTest, no network)

HTTP is a directory of OData v4 request/response snapshots. The suite
never opens a socket. Tests load `Examples/Catalog/Catalog.xcdatamodeld`
(the same model as the example apps) — not a hand-built
`NSManagedObjectModel`.

```sh
make test
# or
make -C Tests run-tests
```

On Apple: scheme **ODataIncrementalStoreTests** in the workspace (⌘U).
Snapshots live in `Tests/Snapshots/` and cite the OASIS
protocol section they pin.

## Example apps

`Examples/Workbench` is the testing bench: a Cocoa window that drives a
real store against an in-memory OData v4 service (no network). Predicate
→ `$filter`, fetch, fault, expand, PATCH/POST/DELETE, wire log.

`Examples/Catalog` is a smaller consumer: table + predicate + inspector.

Both load `Catalog.xcdatamodeld`.

```sh
make -C Examples/Workbench
openapp ./Workbench.app   # GNUstep
```

## Apple / Xcode

Open **`ODataIncrementalStore.xcworkspace`** (not a lone `.xcodeproj` — the
example apps need the framework project in the same workspace).

| Scheme | Product |
|---|---|
| `ODataIncrementalStore` | macOS framework |
| `ODataIncrementalStoreTests` | XCTest, snapshot HTTP, no network (⌘U) |
| `Catalog` | consumer AppKit app |
| `Workbench` | in-memory OData workbench |

```
xcodebuild -workspace ODataIncrementalStore.xcworkspace \
  -scheme ODataIncrementalStoreTests -destination 'platform=macOS' test
```

The framework is a real `ODataIncrementalStore.framework` (public headers +
module map). Catalog and Workbench embed it. GNUstep uses the GNUmakefiles.

## Usage

```objc
#import <ODataIncrementalStore/ODataIncrementalStore.h>

[ODataIncrementalStore registerStore];

NSError *error = nil;
NSURL *url = [NSURL URLWithString:@"https://services.odata.org/V4/Northwind/Northwind.svc/"];
NSPersistentStoreCoordinator *psc =
    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
[psc addPersistentStoreWithType:[ODataIncrementalStore storeType]
                  configuration:nil
                            URL:url
                        options:@{ ODataIncrementalStoreAccessTokenOption: token }
                          error:&error];
```

```objc
NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Product"];
request.predicate = [NSPredicate predicateWithFormat:
    @"unitPrice > %d AND discontinued == NO", 20];
request.sortDescriptors = @[ [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES] ];
request.fetchLimit = 25;
request.relationshipKeyPathsForPrefetching = @[ @"category" ];
NSArray *products = [context executeFetchRequest:request error:&error];
```

That fetch is this request:

```
GET Products?$filter=(UnitPrice gt 20) and (Discontinued eq false)
           &$orderby=ProductName,ProductID
           &$top=25
           &$expand=Category
```

The key is added to `$orderby` as a tiebreaker, so pages split the same
way however many rows share a name, and every `@odata.nextLink` is
followed until the collection ends or `fetchLimit` is reached.

## Models from `$metadata`

A service's schema can be the model, two ways.

**At runtime**, for a client that knows nothing of the service in advance
(the Workbench will connect to any service this way):

```objc
NSManagedObjectModel *model = [ODataIncrementalStore modelForServiceAtURL:url options:nil error:&error];
```

**Ahead of time**, for a client built on one service, with its own logic on
top: `ois-model` writes the model as an `.xcdatamodeld`, which Xcode edits
and `momc` compiles like any other.

```sh
ois-model https://services.odata.org/V4/Northwind/Northwind.svc/ Northwind.xcdatamodeld
```

Entity types become entities (base types are super-entities), properties
and navigation properties become attributes and relationships in lower
camel case (`UserName` is `userName`), partners become inverses, and the
OData names, keys, entity sets and Edm types go into `userInfo`, so the
model needs nothing else at runtime. Complex, collection, stream and
spatial properties are not mapped; `ois-model` lists them.

**A changed service is a new model version**, as in Core Data. Run
`ois-model` again: if the schema has changed, it adds a version to the
package (`Northwind 2`) and makes it current, keeping the old ones; if not,
it writes nothing. A store opened with a generated model checks it against
the service's schema by version hashes, as Core Data checks a model against
any store, and fails with `NSPersistentStoreIncompatibleVersionHashError`
when the service has moved on. To pick the version that matches, the
Core Data way:

```objc
NSDictionary *metadata = [ODataIncrementalStore metadataForServiceAtURL:url options:nil error:&error];
NSManagedObjectModel *model = [NSManagedObjectModel mergedModelFromBundles:nil forStoreMetadata:metadata];
```

A model written by hand is not version-checked. The store reads
`$metadata` when it opens and fills in what the model leaves unsaid (keys,
entity sets, Edm types, enumerations, derived types), and lists where the
two disagree in `metadataProblems`
(`ODataIncrementalStoreRequireMatchingModelOption` makes that fail the
open).

## Mapping

| Core Data | OData |
|---|---|
| `NSEntityDescription.name` | Entity type |
| `userInfo[@"OData.entitySet"]` | Entity set (`Products`) |
| attribute names | properties (`unitPrice` → `UnitPrice` by default) |
| `userInfo[@"OData.property"]` | override a wire name |
| `userInfo[@"OData.key"]` | key attribute(s) |
| `userInfo[@"OData.type"]` | the Edm type, where one Core Data type stands for several: `Edm.Date` on a Date, `Edm.Duration` on a Double, `Edm.TimeOfDay` or `Edm.Guid` on a String |
| `userInfo[@"OData.type"]` on an entity | its entity type, qualified (`NS.Employee`); a sub-entity is a derived type |
| `NSIncrementalStoreNode.version` | `@odata.etag` |

## Threading

`NSIncrementalStore` callbacks are synchronous. **Do not load this store on the
main queue.** Use a private-queue context.

Requests go out through a transport and come back by target-action: an
`ODataExchange` carries the request, and `-finish` sends its action to its
target once the response (or an error) is in. `ODataClient` offers the same
(`-sendRequest:target:action:`, `-sendChangeSet:target:action:`), and its
synchronous methods, which the store uses, wait on a condition for the
exchange to finish. So a transport can be as asynchronous as it likes, and
nothing that uses the store has to be.

A transport of your own (`ODataIncrementalStoreTransportOption`) implements
one method:

```objc
- (void)startExchange:(ODataExchange *)exchange
{
  // send exchange.request; then, now or later, on any thread:
  exchange.URLResponse = response;
  exchange.data = data;          // or exchange.error = error;
  [exchange finish];
}
```

It must not finish by waiting for the thread that started the exchange:
that thread is waiting for `-finish`, not running its run loop.

## Roadmap

Client conformance with OData v4, item by item, and the order the gaps
are being closed in: [docs/odata-conformance.md](docs/odata-conformance.md).

A matching OData server in Objective-C, over Core Data, on GNUstep and
Cocoa. Not started; the design is in
[docs/server-design.md](docs/server-design.md).

## License

GNU Lesser General Public License v2.1 or later. See `LICENSE`.
FreeCoreData is separate and MIT.
