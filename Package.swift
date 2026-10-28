// swift-tools-version: 5.9
import PackageDescription

// Foundation-only policy tests. Does not run the hours-long iPhone server test.
let package = Package(
    name: "iCTRLNativePolicy",
    platforms: [.macOS(.v12)],
    targets: [
        .target(name: "NativePolicy", path: "iCTRLKit", sources: [
            "RPCCoreTypes.swift", "ClipboardTextPolicy.swift", "ProvisioningExpiry.swift",
            "StartupURLRequest.swift", "RenewalGate.swift", "RenewalReceiptStore.swift", "CompanionRuntimeMetadata.swift", "RunnerProfileMetadata.swift", "NativeRPCMethodDefinitions.swift",
            "RPCMethod.swift", "BuildStamp.swift", "FileTransferRPCMethods.swift", "FileTransferStore.swift", "DevelopmentRPCMethods.swift",
            "QuietLease.swift", "QuietCallback.swift", "QuietControl.swift", "QuietModeStore.swift", "QuietRPCMethodDefinitions.swift", "QuietDiagnostics.swift", "QuietForegroundRestorationPolicy.swift", "ShadeArtifact.swift"
        ]),
        .testTarget(name: "NativePolicyTests", dependencies: ["NativePolicy"], path: "NativeTests")
    ]
)
