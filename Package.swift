// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "2pic",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Stitch"),
        .executableTarget(
            name: "TwoPic",
            dependencies: ["Stitch"],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        .executableTarget(name: "StitchCheck", dependencies: ["Stitch"]),
    ]
)
