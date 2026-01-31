// swift-tools-version: 6.0

import PackageDescription

// CryptoKit remains the Apple implementation. Linux CI uses Apple's compatible Swift Crypto.
var cryptoPackages: [Package.Dependency] = []
var cryptoTargets: [Target.Dependency] = []
#if os(Linux)
cryptoPackages = [.package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2")]
cryptoTargets = [.product(name: "Crypto", package: "swift-crypto")]
#endif

let package = Package(
    name: "AgentContracts",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "AgentContracts", targets: ["AgentContracts"]),
    ],
    dependencies: cryptoPackages,
    targets: [
        .target(name: "AgentContracts", dependencies: cryptoTargets),
        .testTarget(name: "AgentContractsTests", dependencies: ["AgentContracts"]),
    ]
)
