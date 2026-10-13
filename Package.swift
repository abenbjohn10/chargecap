// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ChargeCap",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ChargeKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "ChargeCap",
            dependencies: ["ChargeKit"],
            linkerSettings: [.linkedFramework("ServiceManagement"), .linkedFramework("CoreBluetooth")]
        ),
        .executableTarget(
            name: "chargecap-helper",
            dependencies: ["ChargeKit"]
        ),
    ]
)
