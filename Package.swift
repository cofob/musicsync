// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MusicSync",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        // The modules of the iPad app (iPad/MusicSync.xcodeproj); the Mac app is the MusicSyncApp executable.
        .library(name: "MusicSyncKit", targets: ["Support", "Subsonic", "ITunesDB", "Artwork", "Transcode", "Device", "Sync",
                                                 "Library", "Recommend", "Integration", "Remote", "Playback", "Preferences", "MilkDropKit"]),
    ],
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
        .target(name: "Playback", dependencies: ["Support", "Subsonic"]),
        .target(name: "Preferences", dependencies: ["Support"]),
        .target(name: "MilkDropKit", resources: [.copy("Resources/Presets"), .copy("Resources/Textures"), .copy("Resources/LICENSE.txt")]),
        .target(name: "Sync", dependencies: ["Support", "Subsonic", "ITunesDB", "Artwork", "Transcode", "Device"]),
        .executableTarget(name: "MusicSyncApp", dependencies: ["Support", "Subsonic", "ITunesDB", "Artwork", "Transcode", "Device", "Sync", "Library", "Recommend", "Integration", "Remote", "Playback", "Preferences", "MilkDropKit"]),
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
        .testTarget(name: "PlaybackTests", dependencies: ["Playback"]),
        .testTarget(name: "PreferencesTests", dependencies: ["Preferences"]),
        .testTarget(name: "MilkDropKitTests", dependencies: ["MilkDropKit"]),
        .testTarget(name: "MilkDropParityTests", dependencies: ["MilkDropKit"], exclude: ["ProjectM"], resources: [.copy("Reference")]),
    ]
)
