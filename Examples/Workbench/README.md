# Workbench.app

A native Cocoa / GNUstep app for trying out an OData v4 service with
`ODataIncrementalStore`, the way an app would use it: a real
`NSIncrementalStore`, a real Core Data context.

Pick a service at the top:

- **Built-in (this library's server)**: the library's own server,
  `ODataService`, in the process, behind `ODataTransport`, with no network
  (`WorkbenchEngine` wraps it and logs each exchange). It serves the
  Catalog (`Examples/Catalog/Catalog.xcdatamodeld`: products, categories,
  suppliers, stock at locations), seeded with a few of Northwind's rows,
  and what the Catalog does not show (`WorkbenchBuiltInModel`): products
  with a version (ETags, so conflicts), budgets over time (application
  time), and pictures (a media entity). Its store is SQLite with
  persistent history, in a temporary file, so its sets have delta links.
  Its operations are declared in protocols in `WorkbenchEngine.m`:
  `DiscountedPriceByPercent` and `RaisePriceByPercent` on a product,
  `CheaperThanPrice` on the products, `CountProductsInCategoryNamed` and
  `CountProductsSlowly` (it takes its time: try it with respond-async) on
  the service. What the store sends is answered as any `ois-serve` would
  answer it, `$batch` included.
- **Northwind (read-only)**: Microsoft's public Northwind v4.
- **TripPin (read/write)**: Microsoft's public TripPin, in a session of its
  own, so writing is safe. Reset starts a new one.
- **Other URL…**: any OData v4 service root; press Connect.

For a real service the model is the one its `$metadata` describes, built at
runtime: nothing is known about the service in advance.

What you can do:

- Choose a preset, or build the query: an entity, a predicate (`NSPredicate`
  syntax), `$top`, `$skip`, a page size, sub-entities or not, and a result
  type (objects, object IDs, dictionaries, a count). The panel below holds
  the rest of what a fetch request can say: sort keys, as many as you like,
  through to-one relationships (`$orderby`); relationships to prefetch,
  opened to nest (`$expand=Suppliers($expand=Products)`); and the
  properties of a dictionary result (`$select`). Under the lists: a
  `$search` (the service's own free-text search, ANDed with the
  predicate), and, for a dictionary result, values computed from each row
  (`unitPrice * 1.2 as withTax`, NSExpression's syntax: `$compute` where
  the service has it, else computed by the store), or a grouping: key
  paths to group by (`category.name`) and aggregates
  (`count:(id) as products, sum:(unitPrice) as total`, with `sum`, `min`,
  `max`, `average` and `count`). For an entity with application time
  (the built-in Budgets), the field beside Execute asks for a day
  (`2024-10-01`, `$at`) or a period (`2024-01-01..2025-01-01`, `$from` and
  `$to`; `..=` to include the end; `2024-01-01..` from then on). The GET the store will send is shown
  before you execute it: `$apply` where the service has it, else the read
  of the rows the store groups itself.
- Execute. Rows are real managed objects; select one to see its attributes,
  fire its faults, or its relationships. Each prefetched relationship is a
  column, showing what came with the row. Fire relationships reads every
  relationship and says, for each, whether that asked the service: a
  prefetched one does not, one that was not prefetched does.
- Streams: a media entity's resource or a stream property (TripPin's
  photos), chosen beside the inspector. Download reads it into the store's
  stream directory and shows its content type, media ETag and size;
  Upload… sends a file into the selected row's stream (a PUT with its
  media ETag), or, with no row selected, makes a new media entity from it
  (a POST), whose other properties you then edit and Save.
- Change things as an app does: Insert a new object of the entity
  (required values start empty), edit cells, Delete rows; nothing is sent
  until Save, which sends them as POST, PATCH and DELETE, and Revert drops
  them. A new object's key can be edited, for services that want the
  client's (TripPin's people).
- Change a timeline: for an entity with application time, the
  operations menu has `Temporal.Update`, `Upsert` and `Delete`, whose
  parameters are one delta time slice, by attribute
  (`category='Beverages', from=2025-03-01, to=2025-06-01, amount=1500`):
  the service splits the slices around the period, and the timeline is
  read again.
- The Store menu: what a save does when the service has changed an object
  since it was read (refuse, showing each conflict in the inspector; my
  changes win; the service's win); prefer respond-async (the service may
  answer a slow request 202, and the store polls its status monitor: the
  log shows it); JSON `$batch` with a 4.01 service; and, at the built-in
  service, a change another client makes, for Changes to read and a stale
  Save to conflict with.
- Call the service's actions and functions: the selected object's, its
  entity's, and the service's own, from the menu at the bottom right, with
  parameters as `name=value, …`. TripPin has some (`GetFavoriteAirline` on a
  person, `GetNearestAirport(lat, lon)`).
- Changes: read what changed at the service since the last look (delta
  links, where the service gives them); the first look starts tracking.
- Read the wire log: a row per exchange the store had with the service.
  Choose one to see it whole in a window of its own, as it went over the
  wire: the request line, headers and body, then the status line, headers
  and body, nothing shortened (a body that is not text as a hex dump).

## Getting it

CI packages the Workbench on every push, as artifacts of the run (kept 14
days), and attaches both packages to the release when a `v*` tag is pushed:

- **macOS**: `ODataWorkbench-macOS-<version>.zip`, a universal (Apple silicon
  and Intel) `Workbench.app` with the framework inside. It is signed ad hoc,
  not with a Developer ID, so open it the first time with right-click, Open
  (or `xattr -dr com.apple.quarantine Workbench.app`).
- **Linux**: `ODataWorkbench-Linux-<version>-x86_64.AppImage`, the app with
  the library, FreeCoreData and the GNUstep runtime inside
  (`Scripts/prepare-appdir.sh`, `Scripts/package-appimage.sh`). It needs
  what any Linux desktop has: X11, fontconfig, freetype, OpenGL. Make it
  executable and run it; where FUSE is missing, `APPIMAGE_EXTRACT_AND_RUN=1`
  runs it without.

Before either is uploaded, CI starts it and runs its offline self-test: the
AppImage in a plain Ubuntu container with no GNUstep in it.

## Testing

`Workbench --self-test` drives the window against each service in turn and
prints a line per check (CI runs it); with `WORKBENCH_SHOTS=<dir>` it also
saves the window as a PDF per service. `Workbench --self-test builtin` tests
the built-in service alone, with no network.

The window is `WorkbenchWindow.xib` (File's Owner `WorkbenchController`),
Xcode 5 format, springs and struts, no Auto Layout; GNUstep loads it with
`GSXib5Loader`.

GNUstep (clang, libobjc2, FreeCoreData, gnustep-gui):

```
. /usr/share/GNUstep/Makefiles/GNUstep.sh
make -C ../..
make
openapp ./Workbench.app
```

Apple: open `ODataKit.xcworkspace` at the library root, scheme
**Workbench**. The app embeds `ODataKit.framework`,
`ODataIncrementalStore.framework` and `ODataService.framework`, copies
`WorkbenchWindow.xib`, and compiles `Catalog.xcdatamodeld`.
