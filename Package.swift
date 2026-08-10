// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "image64",
    platforms: [.macOS(.v14)],
    products: [
        // The conversion engine. UI-free, so both front ends — and the test
        // suite — link the identical code.
        .library(name: "C64Kit", targets: ["C64Kit"]),
        .executable(name: "image64", targets: ["Image64CLI"]),
        .executable(name: "Image64App", targets: ["Image64App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "C64Kit"),
        .executableTarget(
            name: "Image64CLI",
            dependencies: [
                "C64Kit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // ArgumentParser is deliberately absent here: the dependency is
        // permitted in the CLI target only.
        .executableTarget(name: "Image64App", dependencies: ["C64Kit"]),
        // Fixture builders both test targets read. A plain target rather than a
        // second copy of the file in each suite: the CLI tests must convert the
        // *same* images the engine tests measure, or a lockstep failure could
        // hide behind differently-drawn inputs.
        .target(name: "TestSupport", dependencies: ["C64Kit"], path: "Tests/TestSupport"),
        .testTarget(
            name: "C64KitTests",
            dependencies: ["C64Kit", "TestSupport"],
            // Golden fixtures — small binary files copied into the test bundle so
            // the golden tests read the exact bytes committed to the repo, not
            // whatever the pipeline happens to produce today.
            resources: [.copy("Fixtures")]
        ),
        // Depends on the executable so `swift test` is guaranteed to have built
        // the binary these tests spawn, and on `C64Kit` for the lockstep test
        // that calls `ConversionOperation.run` directly and compares bytes.
        .testTarget(
            name: "CLITests", dependencies: ["C64Kit", "TestSupport", "Image64CLI"]),
    ]
)
