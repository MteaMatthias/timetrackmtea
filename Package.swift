// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TimeTrack",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TimeTrack",
            path: "Sources/TimeTrack",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "TimeTrackTests",
            dependencies: ["TimeTrack"],
            path: "Tests/TimeTrackTests"
        ),
    ]
)
