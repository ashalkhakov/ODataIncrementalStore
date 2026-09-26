# Workbench.app

A native Cocoa / GNUstep app for trying out an OData v4 service with
`ODataIncrementalStore`, the way an app would use it: a real
`NSIncrementalStore`, a real Core Data context.

Pick a service at the top:

- **Built-in (in memory)**: `WorkbenchEngine`, an OData service in the
  process, behind `ODataTransport`, with no network. It serves the Catalog
  (`Examples/Catalog/Catalog.xcdatamodeld`: products, categories, suppliers,
  stock at locations) and reads requests with the library's parser
  (`ODataExpression.h`): `$filter`, `$orderby`, `$select`, `$expand` with
  nested options, `$top`, `$skip`, `$count`.
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
  properties of a dictionary result (`$select`). The GET the store will
  send is shown before you execute it.
- Execute. Rows are real managed objects; select one to see its attributes,
  fire its faults, or its relationships.
- Change things as an app does: Insert a new object of the entity
  (required values start empty), edit cells, Delete rows; nothing is sent
  until Save, which sends them as POST, PATCH and DELETE, and Revert drops
  them. A new object's key can be edited, for services that want the
  client's (TripPin's people).
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

`Workbench --self-test` drives the window against each service in turn and
prints a line per check (CI runs it); with `WORKBENCH_SHOTS=<dir>` it also
saves the window as a PDF per service.

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

Apple: open `ODataIncrementalStore.xcworkspace` at the library root, scheme
**Workbench**. The app embeds `ODataIncrementalStore.framework`, copies
`WorkbenchWindow.xib`, and compiles `Catalog.xcdatamodeld`.
