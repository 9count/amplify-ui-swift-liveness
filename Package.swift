// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "AmplifyUILiveness",
    defaultLocalization: "en",
    platforms: [.iOS(.v14)],
    products: [
        .library(
            name: "FaceLiveness",
            targets: ["FaceLiveness"]),
    ],
    dependencies: [
        .package(url: "https://github.com/aws-amplify/amplify-swift", exact: "2.33.3")
    ],
    targets: [
        .target(
            name: "FaceLiveness",
            dependencies: [
                .product(name: "AWSPluginsCore", package: "amplify-swift"),
                .product(name: "AWSCognitoAuthPlugin", package: "amplify-swift"),
                .product(name: "AWSPredictionsPlugin", package: "amplify-swift"),
                "HistogramCalculator"
            ],
            resources: [
                .process("Resources/Base.lproj"),
                .copy("Resources/face_detection_short_range.mlmodelc"),
                .copy("Utilities/DepthToJET/Metal")
            ]
        ),
        .target(name: "HistogramCalculator"),
        .testTarget(
            name: "FaceLivenessTests",
            dependencies: ["FaceLiveness"]),
    ]
)
