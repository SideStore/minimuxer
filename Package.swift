// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Minimuxer",
    platforms: [
        .iOS(.v13),
        .macOS(.v11)
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
        )
    ],
    targets: [
        .target(
            name: "MinimuxerDomain",
            path: "Domain"
        ),
//        .binaryTarget(
//            name: "IDevice",
//            url: "https://github.com/jkcoxson/idevice/releases/download/v0.1.64/idevice-xcframework-v0.1.64.zip",
//            checksum: "b8250402a23c850f80b9be1d4add309aae6c935ee6a797b73616e4d8f170be5d"
//        ),
        .binaryTarget(
            name: "IDevice",
            url: "https://github.com/SideStore/idevice/releases/download/v0.1.64-ss-399cd94/idevice-xcframework-v0.1.64-ss-399cd94.zip",
            checksum: "ead0d85c7c806831fe50d8c4ee1ccdbaba40cf8dfb39cc8d28a76e6095253134"
        ),
//         .binaryTarget(
//             name: "IDevice",
//             path: "../../local/idevice/swift/bundle.zip"
//         ),
        
        // MARK: Main SPM target
        .target(
            name: "Minimuxer",
            dependencies: [
                "MinimuxerDomain",
                "IDevice",
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "MinimuxerTests",
            dependencies: ["MinimuxerDomain"],
            path: "Tests/MinimuxerTests"
        )
    ]
)
