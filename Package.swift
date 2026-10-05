// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "xm6-volume",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "xm6-volume",
            exclude: ["Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("IOBluetooth"),
                // Embed Info.plist so the Bluetooth privacy check passes for a bare CLI binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/xm6-volume/Info.plist",
                ]),
            ]
        )
    ]
)
