// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "EchoGestures",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "EchoGestures", targets: ["EchoGestures"])],
    targets: [
        .executableTarget(name: "EchoGestures", path: "Sources",
                          swiftSettings: [.unsafeFlags(["-Xcc", "-DACCELERATE_NEW_LAPACK"])], linkerSettings: [
            .linkedFramework("SwiftUI"), .linkedFramework("AppKit"), .linkedFramework("AVFoundation"),
            .linkedFramework("Accelerate"), .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"),
            .linkedFramework("ApplicationServices")
        ]),
        .executableTarget(name: "EchoGesturesVoiceArray", path: "Native", linkerSettings: [
            .linkedFramework("AudioToolbox"), .linkedFramework("CoreAudio"), .linkedFramework("CoreFoundation")
        ])
    ]
)
