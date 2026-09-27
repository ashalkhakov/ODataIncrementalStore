# Building

## Toolchain

ODataKit **will not compile** against GCC's `libobjc`: the headers refuse
anything that is not clang, Objective-C 2.0, ARC and blocks.

| | |
|---|---|
| Language | Objective-C 2.0 (properties, literals, blocks, ARC, `NS_ENUM`, zeroing weak) |
| Runtime | **libobjc2** (`-fobjc-runtime=gnustep-2.0`) or Apple's |
| ABI | Non-fragile: ivars live in `@implementation { }` blocks |
| Foundation | gnustep-base or Apple Foundation |
| Core Data | Apple Core Data, or **[FreeCoreData](https://github.com/ashalkhakov/FreeCoreData)** on GNUstep |
| Transport | `NSURLSession`, on Apple and on a gnustep-base built with libcurl; `NSURLConnection` otherwise (with the patched stack below it follows relative redirects and reads `$batch` answers) |
| Strings | `-fconstant-string-class=NSConstantString` on GNUstep |

The libraries are ARC. FreeCoreData is manual reference counting
(`-fno-objc-arc`); they link, since methods named `new…` return +1 on both
sides.

```
clang -fobjc-runtime=gnustep-2.0 -fobjc-arc -fblocks \
      -fconstant-string-class=NSConstantString
```

## macOS: Xcode

Open **`ODataKit.xcworkspace`** (not a lone `.xcodeproj`: the example apps
need the framework project in the same workspace).

| Scheme | Product |
|---|---|
| `ODataKit` | macOS framework, the shared core |
| `ODataIncrementalStore` | macOS framework, the client (links `ODataKit`) |
| `ODataService` | macOS framework, the server (links `ODataKit`) |
| `ODataKitTests` | XCTest for all three: snapshots, the service in process, no network (⌘U) |
| `Catalog` | A small AppKit client |
| `Workbench` | The workbench |

```
xcodebuild -workspace ODataKit.xcworkspace -scheme ODataKitTests -destination 'platform=macOS' test
```

A client app embeds `ODataKit.framework` and `ODataIncrementalStore.framework`
(Catalog does); one that serves as well adds `ODataService.framework`
(Workbench does). The server tools build with plain clang, with no Xcode
project: `make -C Server` writes `Server/build/ois-serve`, and
`make -C Server check` runs it over a loopback socket.

## GNUstep

CI builds against a GNUstep stack from
[gnustep-patches](https://github.com/ashalkhakov/gnustep-patches), whose
`Scripts/build-gnustep.sh` makes it; `.github/workflows/ci.yml` has the exact
recipe and the commits it pins.

Install [FreeCoreData](https://github.com/ashalkhakov/FreeCoreData) first: it
is the Core Data this store subclasses (`NSIncrementalStore`, the coordinator)
and the server stores in. Install its model compiler too (`make -C Tools/momc
install` there): the tests and example apps compile `Catalog.xcdatamodeld` to
`.momd`, which is what FreeCoreData loads. Then:

```sh
. /usr/share/GNUstep/Makefiles/GNUstep.sh
make && make install         # libODataKit, libODataIncrementalStore, libODataService
make -C Server               # libODataHTTPServer, Server/obj/ois-serve
```

Link a client with `-lODataIncrementalStore -lODataKit -lCoreData`, and a
server with `-lODataService -lODataKit -lCoreData` as well.

Without gnustep-make, clang and `gnustep-config` build the command-line tool:

```sh
make -f Makefile
./ois-filter 'unitPrice > 20 AND discontinued == NO'
# (UnitPrice gt 20) and (Discontinued eq false)
```

## Tests

XCTest, and no network: HTTP is a directory of OData v4 request/response
snapshots of real services (`Tests/Snapshots/`, each citing the protocol
section it pins), and the service is tested in process, a store talking to
it through `ODataTransport`. The tests load
`Examples/Catalog/Catalog.xcdatamodeld`, the example apps' model.

```sh
make test            # GNUstep
```

On Apple: the `ODataKitTests` scheme (⌘U).

`Tests/Live/` checks that real services agree: Microsoft's Northwind v4
(read) and TripPin (write, in a session of its own), streams and `$search`
among them. CI runs it without letting it fail a build, since the services are
not ours:

```sh
make -C Tests/Live live      # GNUstep
```

## The example apps

- `Examples/Workbench`: the workbench ([its README](../Examples/Workbench/README.md)).
  `Workbench --self-test` drives its window against each service and prints a
  line per check; `--self-test builtin` needs no network.
- `Examples/Catalog`: a smaller client: a table, a predicate, an inspector.
- `Examples/QuickStart`: the README's first path, one file.

```sh
make -C Examples/Workbench && openapp Examples/Workbench/Workbench.app   # GNUstep
```
