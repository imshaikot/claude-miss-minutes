// swift-tools-version:5.9
import PackageDescription

// Module map (dependencies only point downwards):
//
//   MissMinutes (app: composition root, menu bar, settings window)
//     ├─ MinutesStage      overlay windows, screen sensing, locomotion, speech bubble
//     │    └─ MinutesCharacter   the rig renderer and its display-linked view
//     ├─ MinutesBrain      Claude Code process, body-control bridge server
//     ├─ MinutesVoice      speech synthesis with amplitude-driven lip sync
//     │    └─ MinutesObjC        catches AVFoundation's Objective-C exceptions
//     └─ MinutesCore       pure model: pose, animation, perch planning, settings,
//                          stream-json parsing, director (no AppKit)
let package = Package(
    name: "MissMinutes",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MissMinutes", targets: ["MissMinutes"]),
    ],
    targets: [
        .target(name: "MinutesCore"),
        .target(name: "MinutesCharacter", dependencies: ["MinutesCore"]),
        .target(name: "MinutesStage", dependencies: ["MinutesCore", "MinutesCharacter"]),
        .target(name: "MinutesBrain", dependencies: ["MinutesCore"]),
        .target(name: "MinutesObjC"),
        .target(name: "MinutesVoice", dependencies: ["MinutesCore", "MinutesObjC"]),
        .executableTarget(
            name: "MissMinutes",
            dependencies: ["MinutesCore", "MinutesCharacter", "MinutesStage", "MinutesBrain", "MinutesVoice"],
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(name: "MinutesCoreTests", dependencies: ["MinutesCore"]),
    ],
    swiftLanguageVersions: [.v5]
)
