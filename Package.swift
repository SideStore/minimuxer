// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minimuxer",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v14)
    ],
    products: [
        .library(
            name: "Minimuxer",
            targets: ["Minimuxer"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            .upToNextMajor(from: "0.9.0")
        ),
        .package(path: "Common"),
        .package(path: "DeviceGateway")
    ],
    targets: [
        .binaryTarget(
            name: "EMProxy",
            url: "https://github.com/SideStore/em_proxy/releases/download/v0.9.3/EMProxy.xcframework.zip#Minimuxer",
            checksum: "3998789c38d09b55e488d46e31897affc7bbcb9c244d7a9d5b2d5cf6afd916c3"
        ),
//         .binaryTarget(
//             name: "EMProxy",
//             path: "../../local/em_proxy/libs/EMProxy.xcframework"
//         ),

        // Main SPM target
        .target(
            name: "Minimuxer",
            dependencies: [
                .product(name: "MinimuxerCommon", package: "Common"),
                .product(name: "DeviceGatewayAPI", package: "DeviceGateway"),
                .product(name: "IdeviceGateway", package: "DeviceGateway"),
                .product(name: "LibimobiledeviceGateway", package: "DeviceGateway"),
                "EMProxy",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "MinimuxerTests",
            dependencies: ["Minimuxer"],
            path: "Tests"
        )
    ],
    cLanguageStandard: .gnu11,
    cxxLanguageStandard: .gnucxx14
)
