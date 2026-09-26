# ODataIncrementalStore

**GPL-3.0-or-later.** An `NSIncrementalStore` that talks to a remote OData v4
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
| Transport | `NSURLConnection` send-synchronous off Apple (no libdispatch); `NSURLSession` + `NSCondition` on Apple |
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
# UnitPrice gt 20 and Discontinued eq false
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
GET Products?$filter=UnitPrice gt 20 and Discontinued eq false
           &$orderby=ProductName
           &$top=25
           &$expand=Category
```

## Mapping

| Core Data | OData |
|---|---|
| `NSEntityDescription.name` | Entity type |
| `userInfo[@"OData.entitySet"]` | Entity set (`Products`) |
| attribute names | properties (`unitPrice` → `UnitPrice` by default) |
| `userInfo[@"OData.property"]` | override a wire name |
| `userInfo[@"OData.key"]` | key attribute(s) |
| `NSIncrementalStoreNode.version` | `@odata.etag` |

## Threading

`NSIncrementalStore` callbacks are synchronous. **Do not load this store on the
main queue.** Use a private-queue context.

## License

GNU General Public License v3.0 or later. See `LICENSE`.
FreeCoreData is separate and MIT.
