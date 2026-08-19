// swift-tools-version: 6.1
//
//  Package.swift
//  TiledFlipperAPI
//
//  TiledFlipper アプリが `tiledflipper.v1.TileFlipService` を呼ぶための
//  クライアント側。API の形は リポジトリルートの `openapi.yaml`、proto は
//  `Server/Sources/TiledFlipperServerCore/Protos/tiledflipper.proto` で、
//  サーバーと同じものを 1 つだけ使う。
//
//  `Sources/TiledFlipperAPI/Generated/` のスタブは生成物だが、リポジトリに
//  入れてある。ビルドプラグイン (GRPCProtobufGenerator) を Xcode プロジェクト
//  へ持ち込むとプラグインの信頼をビルドのたびに訊かれるので、アプリ側は
//  生成済みのものを読むだけにしている。作り直すときは
//  `Tools/generate-stubs.sh` を実行する。
//

import PackageDescription

let package = Package(
    name: "TiledFlipperAPI",
    platforms: [
        // gRPC Swift 2 が要求する下限に合わせる。
        .iOS("18.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "TiledFlipperAPI", targets: ["TiledFlipperAPI"])
    ],
    dependencies: [
        // gRPC のコアランタイム (クライアント、RPC の型)。
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        // Protobuf のシリアライザ。生成済みスタブが参照する。
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        // HTTP/2 のトランスポート。手元のサーバーは平文 (h2c) なので、
        // URLSession ではなく NIO の実装を直に使う。
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "TiledFlipperAPI",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "GRPCNIOTransportHTTP2Posix", package: "grpc-swift-nio-transport"),
            ]
        )
    ]
)
