// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RemindersMCP",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "reminders-mcp", targets: ["RemindersMCP"])],
    targets: [.executableTarget(name: "RemindersMCP", path: "Sources/RemindersMCP")]
)
