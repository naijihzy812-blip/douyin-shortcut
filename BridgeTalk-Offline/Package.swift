// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BridgeTalkCore", products: [.library(name: "BridgeTalkCore", targets: ["BridgeTalkCore"])], targets: [
 .target(name: "BridgeTalkCore", path: "BridgeTalk", exclude: ["BridgeTalkApp.swift", "ConversationModel.swift", "LocalRecognizer.swift", "Info.plist"], sources: ["ConversationCore.swift"]),
 .testTarget(name: "BridgeTalkCoreTests", dependencies: ["BridgeTalkCore"], path: "Tests")
])
