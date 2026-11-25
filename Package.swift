// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OmniFetch",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "omnifetch", targets: ["OmniFetchCLI"]),
        .library(name: "OmniFetchCore", targets: ["OmniFetchCore"]),
        .executable(name: "OmniFetchGUI", targets: ["OmniFetch"])
    ],
    targets: [
        .target(
            name: "OmniFetchCore",
            path: "Sources/OmniFetchCore"
        ),
        .executableTarget(
            name: "OmniFetchCLI",
            dependencies: ["OmniFetchCore"]
        ),
        .executableTarget(
            name: "OmniFetch",
            dependencies: ["OmniFetchCore"],
            path: "Sources/OmniFetch"
        )
    ]
)
