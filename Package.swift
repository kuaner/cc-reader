// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CCReaderKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "CCReaderKit",
            targets: ["CCReaderKit"]
        ),
    ],
    targets: [
        .target(
            name: "CCReaderKit",
            path: "CCReader",
            exclude: [
                "CCReaderApp.swift",
                "CCReader.entitlements",
            ],
            resources: [
                .process("Resources/highlight-dark.css"),
                .process("Resources/highlight-light.css"),
                .process("Resources/highlight.min.js"),
                .process("Resources/marked.min.js"),
                .process("Resources/Assets.xcassets"),
                .process("Resources/en.lproj"),
                .process("Resources/ja.lproj"),
                .process("Resources/zh-Hans.lproj"),
            ]
        ),
    ]
)
