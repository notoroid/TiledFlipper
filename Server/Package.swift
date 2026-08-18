// swift-tools-version: 6.1
//
//  Package.swift
//  TiledFlipperServer
//
//  TiledFlipper アプリがネットワーク越しに取りに行く部分 (アートワーク配布情報と
//  タイルの差し替え指示) を、手元で動かすための gRPC テストサーバー。
//
//  API の形は リポジトリルートの `openapi.yaml` に書いてある。proto は
//  `Sources/TiledFlipperServerCore/Protos/tiledflipper.proto` がその写しで、
//  ビルドプラグイン (GRPCProtobufGenerator) がビルドのたびにスタブを生成する。
//  生成には swift-protobuf に同梱された protoc を使うので、protoc を別途
//  入れておく必要は無い (初回だけ protoc のビルドで時間がかかる)。
//

import PackageDescription

let package = Package(
    name: "TiledFlipperServer",
    platforms: [
        // gRPC Swift 2 が要求する下限に合わせる。
        .macOS("15.0")
    ],
    dependencies: [
        // gRPC のコアランタイム (サービス定義、サーバー、RPC の型)。
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        // .proto からスタブを生成するビルドプラグインと、Protobuf のシリアライザ。
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        // HTTP/2 のトランスポート (SwiftNIO 上に載っている実装)。
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        // 実行ファイルの引数 (--host / --port) を読む。
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // サーバーの中身。gRPC のサービス実装と、待ち受けを組み立てるところ。
        .target(
            name: "TiledFlipperServerCore",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
            ],
            plugins: [
                // Protos/ に置いた .proto から、ビルド時にスタブを生成する。
                // 生成の設定は Protos/grpc-swift-proto-generator-config.json。
                .plugin(name: "GRPCProtobufGenerator", package: "grpc-swift-protobuf")
            ]
        ),
        // Core を呼び出して起動するだけの薄いエントリーポイント。
        .executableTarget(
            name: "TiledFlipperServer",
            dependencies: [
                "TiledFlipperServerCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
