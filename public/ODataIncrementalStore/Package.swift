// swift-tools-version: 5.9
// Apple: prefer ODataIncrementalStore.xcworkspace (framework + tests + apps).
// This package is the SwiftPM path. GNUstep uses GNUmakefile / Makefile.
import PackageDescription

let package = Package(
    name: "ODataIncrementalStore",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v6)
    ],
    products: [
        .library(name: "ODataIncrementalStore", targets: ["ODataIncrementalStore"])
    ],
    targets: [
        .target(
            name: "ODataIncrementalStore",
            path: "Source",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "ODataIncrementalStoreTests",
            dependencies: ["ODataIncrementalStore"],
            path: "Tests",
            exclude: ["GNUmakefile", "README.md"],
            // Catalog.xcdatamodeld lives in Examples/Catalog (outside Tests/).
            // Xcode compiles it into the test bundle; GNUstep copies it;
            // OISCatalogModel falls back to __FILE__ for SwiftPM.
            resources: [.copy("Snapshots")],
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("../Source/include")
            ]
        )
    ]
)
