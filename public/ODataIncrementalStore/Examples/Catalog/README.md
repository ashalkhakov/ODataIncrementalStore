# Catalog

AppKit example: an `NSTableView` of Northwind products, driven by
`ODataIncrementalStore`. Search becomes an `NSPredicate`. Double-click
faults a row (`newValuesForObjectWithID:`). Edit + Save is PATCH with
If-Match.

GNUstep (clang, libobjc2, FreeCoreData, gnustep-gui):

```
. /usr/share/GNUstep/Makefiles/GNUstep.sh
make -C ../.. 
make
openapp ./Catalog.app
```

Apple: drop the sources into a Cocoa app target and link
ODataIncrementalStore.

The store URL defaults to the public Northwind v4 service. Override with
the `OIS_SERVICE_URL` environment variable. This app is the real stack;
the XCTest suite never touches the network.
