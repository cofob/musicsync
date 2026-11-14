// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicSync",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "Support"),
        .target(name: "Subsonic", dependencies: ["Support"]),
        .target(name: "ITunesDB", dependencies: ["Support"]),
        .target(name: "Artwork", dependencies: ["Support"]),
        .target(name: "Transcode", dependencies: ["Support"]),
        .target(name: "Device", dependencies: ["Support"]),
        .target(name: "Recommend"),
        .target(name: "Library", dependencies: ["Support", "Subsonic", "Recommend"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "Integration", dependencies: ["Subsonic"]),
        .target(name: "Remote"),
        .target(name: "Sync", dependencies: ["Support", "Subsonic", "ITunesDB", "Artwork", "Transcode", "Device"]),
        .executableTarget(name: "MusicSyncApp", dependencies: ["Support", "Subsonic", "ITunesDB", "Artwork", "Transcode", "Device", "Sync", "Library", "Recommend", "Integration", "Remote"]),
        .testTarget(name: "SupportTests", dependencies: ["Support"]),
        .testTarget(name: "SubsonicTests", dependencies: ["Subsonic"]),
        .testTarget(name: "ITunesDBTests", dependencies: ["ITunesDB"]),
        .testTarget(name: "ArtworkTests", dependencies: ["Artwork"]),
        .testTarget(name: "TranscodeTests", dependencies: ["Transcode"]),
        .testTarget(name: "DeviceTests", dependencies: ["Device"]),
        .testTarget(name: "SyncTests", dependencies: ["Sync", "Library"]),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
        .testTarget(name: "RecommendTests", dependencies: ["Recommend"]),
        .testTarget(name: "IntegrationTests", dependencies: ["Integration"]),
        .testTarget(name: "RemoteTests", dependencies: ["Remote"]),
    ]
)
