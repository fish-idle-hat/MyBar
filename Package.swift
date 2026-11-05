// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThermoBar",
    platforms: [.macOS("14.2")],
    products: [
        .executable(name: "ThermoBar", targets: ["ThermoBar"]),
        .executable(name: "ThermoBarFanHelper", targets: ["ThermoBarFanHelper"]),
        .executable(name: "ThermoBarAudioHelper", targets: ["ThermoBarAudioHelper"]),
        .executable(name: "ThermoBarMenuHelper", targets: ["ThermoBarMenuHelper"]),
        .executable(name: "TheBarTypingHelper", targets: ["TheBarTypingHelper"]),
        .executable(name: "MyBarTrackpadHelper", targets: ["MyBarTrackpadHelper"]),
    ],
    targets: [
        .target(name: "TrackpadGestureCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CTrackpadBridge", linkerSettings: [.linkedFramework("CoreFoundation")]),
        .executableTarget(name: "MyBarTrackpadHelper", dependencies: ["TrackpadGestureCore", "CTrackpadBridge"],
                          swiftSettings: [.swiftLanguageMode(.v5)], linkerSettings: [.linkedFramework("IOKit")]),
        .target(
            name: "CPowerMetrics",
            linkerSettings: [.linkedFramework("CoreFoundation")]
        ),
        .target(
            name: "FanControlProtocol",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(name: "MenuBarControlProtocol", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "TypingFeedbackProtocol", resources: [.copy("Resources/KeyboardSounds")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "ThermoBar",
            dependencies: ["CPowerMetrics", "FanControlProtocol", "MenuBarControlProtocol", "TypingFeedbackProtocol", "TrackpadGestureCore"],
            resources: [.copy("Resources/Pet")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("EventKit"),
                .linkedFramework("Network"),
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(
            name: "TheBarTypingHelper",
            dependencies: ["TypingFeedbackProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AVFAudio")]
        ),
        .executableTarget(
            name: "ThermoBarFanHelper",
            dependencies: ["FanControlProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ThermoBarMenuHelper",
            dependencies: ["MenuBarControlProtocol"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ThermoBarAudioHelper",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("CoreAudio"),
            ]
        ),
        .testTarget(
            name: "ThermoBarTests",
            dependencies: ["ThermoBar", "FanControlProtocol", "MenuBarControlProtocol", "ThermoBarMenuHelper", "ThermoBarAudioHelper", "TypingFeedbackProtocol", "TheBarTypingHelper", "TrackpadGestureCore", "MyBarTrackpadHelper"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
