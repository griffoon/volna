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
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "VolnaWidget",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
