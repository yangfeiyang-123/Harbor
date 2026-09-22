// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarborSSH",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "HarborSSH", targets: ["HarborSSH"])],
    dependencies: [.package(path: "vendor/SwiftTerm")],
    targets: [
        .target(name: "HarborCore"),
        .executableTarget(name: "HarborSSH", dependencies: ["HarborCore", .product(name: "SwiftTerm", package: "SwiftTerm")], resources: [.copy("Resources/Editor"), .copy("Resources/WorkspaceRuntime"), .copy("Resources/Themes"), .copy("Resources/Simulation")]),
        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborAppTests", dependencies: ["HarborSSH"])
    ],
    swiftLanguageModes: [.v5]
)
