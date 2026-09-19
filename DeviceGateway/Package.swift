// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MinimuxerGateway",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14)
    ],
    products: [
        .library(
            name: "DeviceGatewayAPI",
            targets: ["DeviceGatewayAPI"]
        ),
        .library(
            name: "IdeviceGateway",
            targets: ["IdeviceGateway"]
        ),
        .library(
            name: "IdeviceGateway-Dynamic",
            type: .dynamic,
            targets: ["IdeviceGateway"]
        ),
        .library(
            name: "LibimobiledeviceGateway",
            targets: ["LibimobiledeviceGateway"]
        ),
        .library(
            name: "LibimobiledeviceGateway-Dynamic",
            type: .dynamic,
            targets: ["LibimobiledeviceGateway"]
        )
    ],
    dependencies: [
        .package(path: "../Common"),
        .package(url: "https://github.com/mahee96/RemotePairingKit.git", branch: "main")
//        .package(path: "../../../../local/RemotePairingKit")
    ],
    targets: [
         .binaryTarget(
             name: "IDevice",
             url: "https://github.com/SideStore/idevice/releases/download/v0.1.68-ss-7b1107d/idevice-xcframework-v0.1.68-ss-7b1107d.zip#DeviceGateway",
             checksum: "29f16d4f6bbc5215c7ff18e0718b4d0abdc8b48c4136a620d06328c46edf4711"
         ),
//        .binaryTarget(
//            name: "IDevice",
//            path: "../../../../local/idevice/swift/IDevice.xcframework"
//        ),
        .binaryTarget(
            name: "libimobiledevice",
            url: "https://github.com/SideStore/libimobiledevice-xcframework/releases/download/1.4.0-ss-0f88f7b/libimobiledevice.xcframework.zip#DeviceGateway",
            checksum: "7ccbdd56b074807461fc43d2e32ba92f20df2501a6c14cf9f64a917e7f3fe6e7"
        ),
//         .binaryTarget(
//             name: "libimobiledevice",
//             path: "../../../../local/libimobiledevice-xcframework/libs/libimobiledevice.xcframework"
//         ),

        // Base API Target
        .target(
            name: "DeviceGatewayAPI",
            dependencies: [
                .product(name: "MinimuxerCommon", package: "Common")
            ],
            path: ".",
            exclude: [
                "idevice",
                "libimobiledevice"
            ],
            sources: [
                "BaseDeviceGateway.swift",
                "DeviceGatewayAPI.swift",
                "DeviceGatewayError.swift",
                "DeviceGatewayLogging.swift"
            ]
        ),

        // Dynamic Idevice Target
        .target(
            name: "IdeviceGateway",
            dependencies: [
                "DeviceGatewayAPI",
                .product(name: "MinimuxerCommon", package: "Common"),
                "IDevice"
            ],
            path: "idevice"
        ),

        // Dynamic Libimobiledevice Target
        .target(
            name: "LibimobiledeviceGateway",
            dependencies: [
                "DeviceGatewayAPI",
                .product(name: "MinimuxerCommon", package: "Common"),
                "libimobiledevice",
                .product(name: "OpenSSL",   package: "RemotePairingKit"),
                .product(name: "RPPairing", package: "RemotePairingKit")
            ],
            path: "libimobiledevice"
        )
    ],
    
    cxxLanguageStandard: .cxx17
)
