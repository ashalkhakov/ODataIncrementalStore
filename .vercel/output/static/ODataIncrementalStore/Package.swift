// swift-tools-version: 5.9
// Apple / Xcode path. The same .m files build on GNUstep with clang
// -fobjc-runtime=gnustep-2.0 (see GNUmakefile and Makefile).
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
            exclude: [],
            publicHeadersPath: "include"
        )
    ]
)
