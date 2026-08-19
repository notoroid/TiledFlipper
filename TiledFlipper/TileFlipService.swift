//
//  TileFlipService.swift
//  TiledFlipper
//

import Foundation
import TiledFlipperAPI

/// `tiledflipper.v1.TileFlipService` の呼び出し口。
///
/// openapi.yaml に書かれた 2 つのメソッドを、アプリ側の型で包んである。
///
/// - `getDescriptions()` … 配られているアートワークコレクションの一覧 (単発)
/// - `flips(...)` … タイルの差し替え指示 (server streaming)
///
/// 接続先はビルド時に `TiledFlipperEndpoint.local.txt` から埋め込まれる。
/// 埋め込みが無いビルドや、サーバーに繋がらないときでもアプリは動く必要があるので、
/// 一覧は空、ストリームはすぐ終わる形で返し、呼び出し側が同梱ぶんへ落とせるようにする。
///
/// (API 名は `TileFlipService` だが、この型は綴りを変えずに `TileFlipServcice` のまま。
/// openapi.yaml もその前提で書かれている)
enum TileFlipServcice {

    /// 埋め込まれたサービスのエンドポイント。書いていないビルドでは nil。
    static var serviceURL: URL? { EmbeddedEndpoints.serviceURL }

    /// サービスへの接続。アプリの間ずっと使い回す。
    ///
    /// エンドポイントが埋め込まれていない、あるいは URL として読めないビルドでは
    /// nil になり、以降の呼び出しは「配布が無い」ときと同じ扱いになる。
    private static let connection: TileFlipServiceConnection? = {
        guard let url = serviceURL else { return nil }
        return try? TileFlipServiceConnection(endpoint: url)
    }()

    /// 配られているアートワークコレクションの一覧を返す。
    ///
    /// アートワークの実体 (zip) はここでは取りに行かない。返すのは「どこに何があるか」
    /// だけで、コレクションが選ばれたときに `NetworkArtworkCollection` が
    /// `url` から落とす。一覧が空でもエラーではない。
    static func getDescriptions() async throws -> [NetworkArtworkDescription] {
        guard let connection else {
            // 接続先が埋め込まれていないビルド。同梱ぶんだけで動かす。
            return []
        }

        return try await connection.descriptions().compactMap { description in
            // url が URL として読めないものは配布として使えないので、黙って捨てる。
            // 1 件のせいで残りが出せなくなる方が困る。
            guard let url = URL(string: description.url) else { return nil }
            return NetworkArtworkDescription(
                url: url,
                name: description.name,
                revision: Int(description.revision),
                uniqueIdentifier: description.uniqueIdentifier,
                artworkListFile: description.artworkListFile
            )
        }
    }

    /// タイルの差し替え指示を流し続けるストリームを開く。
    ///
    /// 終端は無い。読むのをやめると RPC もキャンセルされ、サーバー側の生成も止まる。
    /// 繋がらないときや途中で切れたときは、そのエラーでストリームが終わる。
    ///
    /// - Parameters:
    ///   - rows: グリッドの行数。受け取る側と揃っている必要がある。
    ///   - columns: グリッドの列数。
    ///   - artworkCount: 差し替え先に選べるアートワークの数。
    ///   - kind: 流し方。既定はサーバー側でランダムに切り替えるもの。
    ///   - stepInterval: 次のマスへ進むまでの間隔。nil ならサーバーの既定値。
    ///   - flipDuration: 受け取る側でのフリップ 1 回分の長さ。nil ならサーバーの既定値。
    static func flips(
        rows: Int,
        columns: Int,
        artworkCount: Int,
        kind: TileFlipFeedKind = .randomized,
        stepInterval: Duration? = nil,
        flipDuration: Duration? = nil
    ) -> AsyncThrowingStream<TileFlip, any Error> {
        guard let connection else {
            // 接続先が無いビルド。流すものが無いので、空のまま終わらせる。
            return AsyncThrowingStream { $0.finish() }
        }

        let request = Tiledflipper_V1_FlipsRequest(
            rows: rows,
            columns: columns,
            artworkCount: artworkCount,
            feedKind: kind,
            stepInterval: stepInterval,
            flipDuration: flipDuration
        )

        let flips = connection.flips(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await flip in flips {
                        // 位置と番号だけの指示なので、アプリ側の型に移すだけ。
                        continuation.yield(
                            TileFlip(
                                row: Int(flip.row),
                                column: Int(flip.column),
                                artwork: Int(flip.artwork)
                            )
                        )
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
