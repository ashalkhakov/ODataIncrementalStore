# Catalog

AppKit example: an `NSTableView` driven by `ODataIncrementalStore` and
`Catalog.xcdatamodeld`. The window is `CatalogWindow.xib` (File's Owner =
`CatalogController`). GNUstep loads it with `GSXib5Loader` /
`[NSBundle loadNibNamed:owner:]`. There is no programmatic
`NSManagedObjectModel`. FreeCoreData loads the `.xcdatamodeld` XML (and
compiled `.momd` if you run `momc`). Search is an `NSPredicate`. The
inspector faults to-one and to-many relationships
(`newValueForRelationship:` / `$expand`).

## Model

| Entity | Cardinality shown | Notes |
|---|---|---|
| Product ↔ Supplier | many-to-many | a product has many suppliers; a supplier supplies many products |
| Product → Category | to-one | inverse Category.products is to-many |
| Stock → Product | to-one | how much of a product is on hand |
| Stock → Location | to-one | where that quantity sits |
| Product.stocks / Location.stocks | to-many | inventory rows |

`userInfo` keys (`OData.entitySet`, `OData.property`, `OData.key`) map
Core Data names onto the OData wire.

GNUstep (clang, libobjc2, FreeCoreData, gnustep-gui):

```
. /usr/share/GNUstep/Makefiles/GNUstep.sh
make -C ../..
make
openapp ./Catalog.app
```

Apple: open `ODataKit.xcworkspace`, scheme **Catalog**.
Xcode compiles `Catalog.xcdatamodeld` to `.momd`, copies
`CatalogWindow.xib`, and embeds `ODataKit.framework` and
`ODataIncrementalStore.framework`.

The store URL defaults to the public Northwind v4 service. That service
has Product/Category/Supplier but not Location/Stock, and treats
Supplier as to-one. Point `OIS_SERVICE_URL` at a service that matches
this model to exercise the full graph.

`Examples/Workbench` is the testing bench (in-memory OData, wire log,
fault/expand/CRUD). This Catalog app is the smaller consumer. The
XCTest suite never touches the network.
