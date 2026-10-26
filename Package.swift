// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MCPDoctor",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "MCPDoctor", targets: ["MCPDoctor"]),
    ],
    targets: [
        .target(name: "MCPDoctorCore"),
        .executableTarget(name: "MCPDoctor", dependencies: ["MCPDoctorCore"]),
        .testTarget(name: "MCPDoctorCoreTests", dependencies: ["MCPDoctorCore"]),
    ]
)
