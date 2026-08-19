//
//  NetworkTileFlipFeed.swift
//  TiledFlipper
//

import Foundation
import TiledFlipperAPI

/// 差し替え指示の流し方。openapi.yaml の `FeedKind` そのもの。
///
/// アプリ側で同じ列挙を持ち直すと 2 か所を合わせ続けることになるので、
/// 生成されたものへ名前を付けるだけにしている。
typealias TileFlipFeedKind = Tiledflipper_V1_FeedKind

/// 差し替え指示をサーバーから受け取って流す供給元。
///
/// 指示を「作る」のはサーバー (`Flips`) の担当で、この型は受け取ったものを
/// そのまま流すだけ。同じ `TileFlipFeed` なので、受け取る側 (`TileGridModel`) から
/// 見ると同梱の演出 (`RandomizedTileFlipFeed` など) と区別が付かない。
///
/// 繋がらないときや途中で切れたときは、エラーを投げずにストリームを終える。
/// 呼び出し側はそれを見て同梱の演出へ落とせる。
@MainActor
final class NetworkTileFlipFeed: TileFlipFeed {
    let rows: Int
    let columns: Int
    /// 差し替え先に選べるアートワークの数。サーバーが流す番号の上限になる。
    let artworkCount: Int
    /// サーバーに頼む流し方。
    let kind: TileFlipFeedKind
    /// 次のマスへ進むまでの間隔。nil ならサーバーの既定値に任せる。
    let stepInterval: Duration?
    /// 受け取る側でのフリップ 1 回分の長さ。
    /// サーバーは演出の進み方を決めるのに使うので、こちらの値を教える。
    let flipDuration: Duration?

    init(
        rows: Int,
        columns: Int,
        artworkCount: Int,
        kind: TileFlipFeedKind = .randomized,
        stepInterval: Duration? = nil,
        flipDuration: Duration? = nil
    ) {
        self.rows = rows
        self.columns = columns
        self.artworkCount = artworkCount
        self.kind = kind
        self.stepInterval = stepInterval
        self.flipDuration = flipDuration
    }

    /// サーバーから届く差し替え指示を流し続けるストリームを作る。
    ///
    /// 受け取り側が読むのをやめるとストリームの終了が通知され、RPC も
    /// キャンセルされる。サーバー側の生成もそこで止まる。
    func flips() -> AsyncStream<TileFlip> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    for try await flip in TileFlipServcice.flips(
                        rows: rows,
                        columns: columns,
                        artworkCount: artworkCount,
                        kind: kind,
                        stepInterval: stepInterval,
                        flipDuration: flipDuration
                    ) {
                        continuation.yield(flip)
                    }
                } catch {
                    // 繋がらない、あるいは途中で切れた。呼び出し側が同梱の演出へ
                    // 落とせるよう、ここではストリームを終えるだけにする。
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
