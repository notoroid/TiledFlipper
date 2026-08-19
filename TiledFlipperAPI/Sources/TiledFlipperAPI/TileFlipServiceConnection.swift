//
//  TileFlipServiceConnection.swift
//  TiledFlipperAPI
//

import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix

/// `tiledflipper.v1.TileFlipService` への接続。
///
/// エンドポイントごとに 1 つ作って使い回す。gRPC の接続はこの中で開かれ、
/// 呼び出し側は生成済みスタブや GRPC のモジュールを知らずに済む。
///
/// - `descriptions()` が `GetDescriptions` (単発)。
/// - `flips(_:)` が `Flips` (server streaming)。
public final class TileFlipServiceConnection: Sendable {

    /// エンドポイントとして受け取れなかった URL。
    public struct UnsupportedEndpoint: Error, CustomStringConvertible {
        public let url: URL
        public var description: String {
            "エンドポイントとして使えない URL (\(url.absoluteString))。http または https と、ホスト名が必要。"
        }
    }

    private let client: GRPCClient<HTTP2ClientTransport.Posix>
    /// 接続を回し続けるタスク。RPC はこれが動いている間だけ通る。
    private let connections: Task<Void, Never>

    /// エンドポイントの URL から接続を作る。
    ///
    /// `https` なら TLS、`http` なら平文 (h2c) で繋ぐ。ポートを書いていない
    /// URL には、その scheme の既定のポート (443 / 80) を使う。
    ///
    /// 作った時点ではまだ繋がっていない。実際の接続は最初の RPC で開かれ、
    /// 切れたときは gRPC 側が繋ぎ直す。
    public init(endpoint: URL) throws {
        guard let host = endpoint.host(), !host.isEmpty else {
            throw UnsupportedEndpoint(url: endpoint)
        }

        let security: HTTP2ClientTransport.Posix.TransportSecurity
        let defaultPort: Int
        switch endpoint.scheme?.lowercased() {
        case "https":
            security = .tls
            defaultPort = 443
        case "http":
            // 手元のテストサーバーは TLS を張っていない。
            security = .plaintext
            defaultPort = 80
        default:
            throw UnsupportedEndpoint(url: endpoint)
        }

        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: endpoint.port ?? defaultPort),
            transportSecurity: security
        )
        let client = GRPCClient(transport: transport)
        self.client = client
        // RPC を投げるより先に走り始めている必要はない (始まるまでの分は
        // gRPC 側が溜めてくれる) ので、ここで走らせておくだけでよい。
        self.connections = Task { try? await client.runConnections() }
    }

    deinit {
        client.beginGracefulShutdown()
    }

    private var service: Tiledflipper_V1_TileFlipService.Client<HTTP2ClientTransport.Posix> {
        Tiledflipper_V1_TileFlipService.Client(wrapping: client)
    }

    /// 配られているアートワークコレクションの一覧を取る。
    ///
    /// 一覧が空でもエラーではない。呼び出し側は同梱ぶんだけで動けばよい。
    public func descriptions() async throws -> [Tiledflipper_V1_NetworkArtworkDescription] {
        try await service.getDescriptions(Tiledflipper_V1_GetDescriptionsRequest()).descriptions
    }

    /// タイルの差し替え指示を流し続けるストリームを開く。
    ///
    /// 終端は無い。読むのをやめる (ストリームを捨てる、Task をキャンセルする)
    /// と RPC もキャンセルされ、サーバー側の生成も止まる。
    /// 途中で切れたときは、そのエラーでストリームが終わる。
    public func flips(
        _ request: Tiledflipper_V1_FlipsRequest
    ) -> AsyncThrowingStream<Tiledflipper_V1_TileFlip, any Error> {
        AsyncThrowingStream { continuation in
            // 生成されたスタブは「応答を扱うクロージャの中だけ」ストリームを
            // 有効にするので、その寿命をこのタスクで持つ。
            let task = Task {
                do {
                    try await service.flips(request) { response in
                        for try await flip in response.messages {
                            continuation.yield(flip)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
