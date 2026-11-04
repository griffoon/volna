// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Volna",
    platforms: [
        .iOS(.v26),
    ],
    products: [
        .library(name: "Volna", targets: ["Volna"]),
        .library(name: "VolnaWidget", targets: ["VolnaWidget"]),
    ],
    targets: [
        .target(
            name: "Volna",
            resources: [
                .copy("Resources/DelaGothicOne-Regular.ttf"),
                .copy("Resources/OFL-DelaGothicOne.txt"),
                // Core ML package shipped as a plain folder and compiled on the device
                // (see VocalSeparator). Not in git: run tools/convert_vocal_model.sh first.
                .copy("Resources/VocalModel"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "VolnaWidget",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
