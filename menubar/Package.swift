// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ClaudeBillingMenuBar",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ClaudeBillingMenuBar", targets: ["ClaudeBillingMenuBar"]),
    ],
    targets: [
        .executableTarget(name: "ClaudeBillingMenuBar"),
        .testTarget(
            name: "ClaudeBillingMenuBarTests",
            dependencies: ["ClaudeBillingMenuBar"]
        ),
    ]
)
