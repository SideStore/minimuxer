// swift-tools-version: 5.9
import PackageDescription

let local: Bool = false
let localPrefix: String = "./"

var targets: [Target] = [
    // Base API Targets
    .target(name: "MinimuxerCommon"),
    .target(name: "DeviceGateway", dependencies: ["MinimuxerCommon"]),

    // Dynamic idevice Target
    .target(name: "IDeviceGateway", dependencies: ["DeviceGateway", "MinimuxerCommon", "IDevice"]),

    // Dynamic Libimobiledevice Target
    .target(
        name: "LibimobiledeviceGateway",
        dependencies: [
            "DeviceGateway",
            "MinimuxerCommon",
            "libimobiledevice",
            .product(name: "OpenSSL",   package: "RemotePairingKit"),
            .product(name: "RPPairing", package: "RemotePairingKit")
        ],
    ),

    // Main SPM Target
    .target(
        name: "Minimuxer",
        dependencies: [
            "IDeviceGateway",
            "MinimuxerCommon",
            "DeviceGateway",
            "LibimobiledeviceGateway",
            "EMProxy",
            .product(name: "ZIPFoundation", package: "ZIPFoundation")
        ],
    ),
    .testTarget(name: "MinimuxerTests", dependencies: ["Minimuxer"])
]

if local {
    targets.append(contentsOf: [
        .binaryTarget(name: "EMProxy", path: "\(localPrefix)/local/em_proxy/libs/EMProxy.xcframework"),
        .binaryTarget(name: "IDevice", path: "\(localPrefix)/local/idevice/swift/IDevice.xcframework"),
        .binaryTarget(name: "libimobiledevice", path: "\(localPrefix)/local/libimobiledevice-xcframework/libs/libimobiledevice.xcframework"),
    ])
} else {
    targets.append(contentsOf: [
        .binaryTarget(
            name: "IDevice",
            url: "https://github.com/SideStore/idevice/releases/download/v0.1.68-ss-3e55c84/idevice-xcframework-v0.1.68-ss-3e55c84.zip#DeviceGateway",
            checksum: "445702d53942597deb4cdec2c4122d16a3f4ac124ce26cd75b68dab3dad92416"
        ),
        .binaryTarget(
            name: "libimobiledevice",
            url: "https://github.com/SideStore/libimobiledevice-xcframework/releases/download/1.4.0-ss-0f88f7b/libimobiledevice.xcframework.zip#DeviceGateway",
            checksum: "7ccbdd56b074807461fc43d2e32ba92f20df2501a6c14cf9f64a917e7f3fe6e7"
        ),
        .binaryTarget(
            name: "EMProxy",
            url: "https://github.com/SideStore/em_proxy/releases/download/v0.9.3/EMProxy.xcframework.zip#Minimuxer",
            checksum: "3998789c38d09b55e488d46e31897affc7bbcb9c244d7a9d5b2d5cf6afd916c3"
        ),
    ])
}

let package = Package(
    name: "Minimuxer",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14)
    ],
    products: [
        .library(name: "MinimuxerCommon", targets: ["MinimuxerCommon"]),
        .library(name: "DeviceGateway", targets: ["DeviceGateway"]),
        .library(name: "IDeviceGateway", targets: ["IDeviceGateway"]),
        .library(name: "LibimobiledeviceGateway", targets: ["LibimobiledeviceGateway"]),
        .library(name: "IDeviceGateway-Dynamic", type: .dynamic, targets: ["IDeviceGateway"]),
        .library(name: "LibimobiledeviceGateway-Dynamic", type: .dynamic, targets: ["LibimobiledeviceGateway"]),
        .library(name: "Minimuxer", targets: ["Minimuxer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mahee96/RemotePairingKit.git", branch: "main"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", .upToNextMajor(from: "0.9.0")),
    ],
    targets: targets,
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx14
)
