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
| Core Data | Apple Core Data, or **[FreeCoreData](https://github.com/ashalkhakov/FreeCoreData)** on GNUstep. The in-tree stub is translator-only (`OIS_COREDATA=stub`). |
| Transport | `NSURLConnection` send-synchronous off Apple (no libdispatch); `NSURLSession` + `NSCondition` on Apple |
| Strings | `-fconstant-string-class=NSConstantString` on GNUstep |

OIS is ARC. FreeCoreData is MRC (`-fno-objc-arc`). They link: methods named `new…` return +1 on both sides.

```
clang -fobjc-runtime=gnustep-2.0 -fobjc-arc -fblocks \
      -fconstant-string-class=NSConstantString
```

## GNUstep

Install [FreeCoreData](https://github.com/ashalkhakov/FreeCoreData) first — it
is the Core Data runtime this store subclasses (`NSIncrementalStore`,
`NSIncrementalStoreNode`, the coordinator). Then:

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

Translator only, no FreeCoreData:

```sh
make OIS_COREDATA=stub
# or
make -f Makefile OIS_COREDATA=stub
```

## Tests (XCTest, no network)

HTTP is a directory of OData v4 request/response snapshots. The suite
never opens a socket.

```sh
make test
# or
make -C Tests run-tests
```

On Apple: `swift test`. Snapshots live in `Tests/Snapshots/` and cite the
OASIS protocol section they pin.

## Example (AppKit)

`Examples/Catalog` is a Cocoa/GNUstep window: type an `NSPredicate`, fetch
products, edit a price, save. That is a real `NSIncrementalStore` session.

```sh
make -C Examples/Catalog
openapp ./Catalog.app   # GNUstep
```

## Apple / Swift Package Manager

The same `.m` / `.h` tree is an SPM clang target. Add the package, then:

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
