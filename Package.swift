// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DriveCheckMenu",
    defaultLocalization: "de",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DriveCheckMenu", targets: ["DriveCheckMenu"])
    ],
    targets: [
        .target(
            name: "DriveCheckMenuCore",
            path: "Sources/DriveCheckMenuCore"
        ),
        .executableTarget(
            name: "DriveCheckMenu",
            dependencies: ["DriveCheckMenuCore"],
            path: "Sources/DriveCheckMenu"
        ),
        .testTarget(
            name: "DriveCheckMenuTests",
            dependencies: ["DriveCheckMenuCore"],
            path: "Tests/DriveCheckMenuTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
