// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkpadCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkpadCore", targets: ["MarkpadCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "release/6.3")
    ],
    targets: [
        .target(
            name: "MarkpadCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown")
            ]
        ),
        .testTarget(
            name: "MarkpadCoreTests",
            dependencies: ["MarkpadCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
