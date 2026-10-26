// swift-tools-version: 5.9
import PackageDescription

let package = Package(name: "QuietLeasePrototype", products: [.library(name: "QuietLeasePrototype", targets: ["QuietLeasePrototype"])], targets: [
    .target(name: "QuietLeasePrototype"),
    .testTarget(name: "QuietLeasePrototypeTests", dependencies: ["QuietLeasePrototype"])
])
