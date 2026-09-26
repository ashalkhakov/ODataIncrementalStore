# Workbench.app

Native Cocoa / GNUstep app for poking at `ODataIncrementalStore`. This
**is** the workbench. There is no web workbench.

It runs a real `NSIncrementalStore` session against an **in-memory OData
v4 service** (`WorkbenchEngine`, an `ODataTransport`). No socket. The
model is `Catalog.xcdatamodeld` (Product ↔ Supplier many-to-many, Stock
at a Location, Category to-one).

What you can do:

- Type an `NSPredicate`. The query builder shows the GET (`$filter` /
  `$orderby` / `$top` / `$expand` / `/$count`) *before* you execute.
- Execute: `NSManagedObject`, object IDs, dictionary, or count.
- Select a row to fulfill a fault (`newValuesForObjectWithID:`).
- Fire to-one / to-many relationships (`$expand` or navigation GET).
- PATCH unit price, POST a product, DELETE. ETags still apply.
- Read the wire log: every HTTP request the store actually built.
- Reset reseeds the in-memory service.

GNUstep (clang, libobjc2, FreeCoreData, gnustep-gui):

```
. /usr/share/GNUstep/Makefiles/GNUstep.sh
make -C ../..
make
openapp ./Workbench.app
```

Apple: open `ODataIncrementalStore.xcworkspace` at the library root,
scheme **Workbench**. The app embeds `ODataIncrementalStore.framework`
and compiles `Catalog.xcdatamodeld`.

`Examples/Catalog` is a smaller consumer app (table + predicate). This
directory is the testing bench.
