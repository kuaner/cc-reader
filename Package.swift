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
                .process("Resources/timeline-shell.js"),
                .process("Resources/timeline-shell.css"),
                .process("Resources/timeline-shell.html"),
                .process("Resources/markdown-preview.js"),
                .process("Resources/markdown-preview.css"),
                .process("Resources/markdown-preview.html"),
                .process("Resources/Assets.xcassets"),
                .process("Resources/en.lproj"),
                .process("Resources/ja.lproj"),
                .process("Resources/zh-Hans.lproj"),
            ]
        ),
    ]
)
