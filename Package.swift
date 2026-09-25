// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SeeU",
    platforms: [.iOS(.v16)],
    products: [.library(name: "SeeU", targets: ["SeeU"])],
    targets: [
        .target(name: "SeeU"),
        .testTarget(name: "SeeUTests", dependencies: ["SeeU"])
    ],
    swiftLanguageModes: [.v5]
)
