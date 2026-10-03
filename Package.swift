// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RunEventually",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "RunEventuallyCore", targets: ["RunEventuallyCore"]),
        .executable(name: "run-eventually", targets: ["RunEventuallyCLI"]),
        .executable(name: "run-eventually-verify", targets: ["RunEventuallyVerification"]),
        .executable(name: "run-eventually-desktop", targets: ["RunEventuallyDesktop"]),
    ],
    targets: [
        .target(
            name: "RunEventuallyCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "RunEventuallyCLI",
            dependencies: ["RunEventuallyCore"]
        ),
        .executableTarget(
            name: "RunEventuallyVerification",
            dependencies: ["RunEventuallyCore"]
        ),
        .executableTarget(
            name: "RunEventuallyDesktop",
            dependencies: ["RunEventuallyCore"]
        ),
        .testTarget(
            name: "RunEventuallyCoreTests",
            dependencies: ["RunEventuallyCore"]
        ),
    ]
)
