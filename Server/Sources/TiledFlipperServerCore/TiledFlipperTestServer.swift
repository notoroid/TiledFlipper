//
//  TiledFlipperTestServer.swift
//  TiledFlipperServerCore
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// 手元で動かす TiledFlipper 用の gRPC サーバー。
///
/// 通信は平文の HTTP/2 (h2c)。TLS を張らないので、アプリからは
/// `TiledFlipperEndpoint.local.txt` に `http://127.0.0.1:31415` のような
/// 手元のアドレスを書いて繋ぐ。
public struct TiledFlipperTestServer: Sendable {

    /// 待ち受けるホスト。既定はループバックだけ。
    /// 実機から繋ぐときは `0.0.0.0` を渡して LAN へ開ける。
    public var host: String
    /// 待ち受けるポート。0 を渡すと空いているポートが選ばれる。
    public var port: Int
    /// `GetDescriptions` で配るコレクションの一覧。
    public var catalog: ArtworkPackageCatalog

    public init(
        host: String = "127.0.0.1",
        port: Int = 31415,
        catalog: ArtworkPackageCatalog = .empty
    ) {
        self.host = host
        self.port = port
        self.catalog = catalog
    }

    /// サーバーを起動して、止められるまで待ち受け続ける。
    public func run() async throws {
        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: host, port: port),
            transportSecurity: .plaintext
        )
        let server = GRPCServer(transport: transport, services: [TileFlipService(catalog: catalog)])

        try await withThrowingDiscardingTaskGroup { group in
            group.addTask { try await server.serve() }

            // 実際に決まったアドレス (port 0 を渡したときはここで分かる) を知らせる。
            let address = try await transport.listeningAddress
            print("TiledFlipperServer listening on \(address)")
            // ログをファイルへ流していても、起動したことがすぐ分かるようにする。
            // `stdout` を直接参照すると Linux (Glibc) では並行処理安全性チェックに
            // 引っかかるので、全ストリームを flush する `fflush(nil)` を使う。
            fflush(nil)
        }
    }
}
