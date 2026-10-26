// swift-tools-version: 5.9
import PackageDescription

// Foundation-only policy tests. Does not run the hours-long iPhone server test.
let package = Package(
    name: "iCTRLNativePolicy",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "NativePolicy", path: "iCTRLKit", sources: [
            "RPCCoreTypes.swift", "ClipboardTextPolicy.swift", "ProvisioningExpiry.swift",
            "StartupURLRequest.swift", "RenewalGate.swift", "RenewalReceiptStore.swift", "CompanionRuntimeMetadata.swift", "NativeRPCMethodDefinitions.swift",
            "RPCMethod.swift", "BuildStamp.swift", "FileTransferRPCMethods.swift", "FileTransferStore.swift", "DevelopmentRPCMethods.swift"
        ]),
        .testTarget(name: "NativePolicyTests", dependencies: ["NativePolicy"], path: "NativeTests")
    ]
)
