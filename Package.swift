// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CSS-LanguageKit",
    platforms: [.macOS(.v13)],
    products: [.library(name: "CSSLanguage", targets: ["CSSLanguage"])],
    dependencies: [
        .package(path: "../Grammar"),
        .package(path: "../Lexer"),
        .package(path: "../Parser"),
        .package(path: "../Incremental-Parsing"),
        .package(path: "../Language-Tooling"),
    ],
    targets: [
        .target(name: "CSSLanguage", dependencies: [
            .product(name: "Grammar", package: "Grammar"),
            .product(name: "Lexer", package: "Lexer"),
            .product(name: "Parser", package: "Parser"),
            .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
            .product(name: "LanguageTooling", package: "Language-Tooling"),
        ]),
        .testTarget(name: "CSSLanguageTests", dependencies: [
            "CSSLanguage",
            .product(name: "IncrementalParsing", package: "Incremental-Parsing"),
        ]),
    ])
