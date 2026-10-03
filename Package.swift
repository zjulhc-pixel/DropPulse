// swift-tools-version: 6.2
import PackageDescription

let kalam = Context.packageDirectory + "/Vendor/kalam"

let package = Package(
    name: "Droplet",
    platforms: [.macOS(.v26)],
    targets: [
        .systemLibrary(name: "CKalam", path: "Sources/CKalam"),
        .executableTarget(
            name: "Droplet",
            dependencies: ["CKalam"],
            linkerSettings: [.unsafeFlags(["-L", kalam, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
    ]
)
