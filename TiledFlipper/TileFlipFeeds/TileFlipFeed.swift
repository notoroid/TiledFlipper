//
//  TileFlipFeed.swift
//  TiledFlipper
//

import Foundation

/// タイル 1 枚を別のアートワークへ差し替える指示。
///
/// 「どの位置を」「どの画像に」だけを持つ。フリップの長さや進行度といった
/// 見た目は受け取る側 (TileGridModel) の担当なので、指示には含めない。
struct TileFlip: Sendable {
    var row: Int
    var column: Int
    /// 差し替え先のアートワークを指す番号。`0..<TileFlipFeed.artworkCount` の範囲。
    ///
    /// ファイル名ではなく番号で渡すことで、指示を作る側はアートワークが
    /// どこに何という名前で置かれているかを知らずに済む。名前への読み替えは
    /// 受け取る側 (TileGridModel) が担当する。
    var artwork: Int
}

/// 差し替え指示をタイルへ流し込む供給元。
///
/// TileGridModel は「どのタイルをどの画像にするか」をこの供給元に任せ、
/// 受け取った `TileFlip` を見た目へ反映することだけを受け持つ。演出を変えるには
/// この protocol に適合する型を用意して差し替えればよく、受け取る側は変わらない。
///
/// 生成する側と受け取る側の両方から参照される共有オブジェクトなので、参照型に限る。
@MainActor
protocol TileFlipFeed: AnyObject {
    /// 指示を流す対象のグリッドの大きさ。受け取る側と揃っている必要がある。
    var rows: Int { get }
    var columns: Int { get }

    /// 差し替え先に選べるアートワークの数。
    /// 流す `TileFlip.artwork` は `0..<artworkCount` に収まっていること。
    var artworkCount: Int { get }

    /// 差し替え指示を流すストリームを作る。
    ///
    /// 受け取り側が読むのをやめたら、生成側も止まること。
    func flips() -> AsyncStream<TileFlip>
}

extension TileFlipFeed {
    /// 差し替え先のアートワークを 1 つランダムに選ぶ。
    /// 差し替わったことが分かるよう、指定した番号は候補から外す。
    ///
    /// 選べるアートワークが 1 つも無ければ nil を返す。
    func randomArtwork(excluding excluded: Int?) -> Int? {
        guard artworkCount > 0 else { return nil }

        // アートワークが 1 つしか無いときは避けようがないので、それをそのまま使う
        let candidates = (0..<artworkCount).filter { $0 != excluded }
        return candidates.randomElement() ?? (0..<artworkCount).randomElement()
    }
}

/// ランダムウォークで選んだタイルへの差し替え指示を流し続ける供給元。
///
/// グリッドの大きさと歩き方しか知らず、TileGridModel からは独立している。
/// 内部状態 (カーソルと各タイルへ流した画像) はメインアクター上でのみ触る。
@MainActor
final class RandomWalkTileFlipFeed: TileFlipFeed {
    /// グリッド上の位置
    private struct Position {
        var row: Int
        var column: Int
    }

    let rows: Int
    let columns: Int
    /// 差し替え先に選べるアートワークの数
    let artworkCount: Int
    /// 選択が次のタイルへ移るまでの間隔。
    /// TileGridModel のフリップ 1 回分より短くすることで、フリップが完了する前に
    /// 次が始まり、連鎖しているように見える。
    let stepInterval: Duration

    private var cursor: Position
    /// 各タイルへ最後に流したアートワーク。
    /// 同じ画像への差し替えを避け、変化が必ず見えるようにするために覚えておく。
    private var lastArtworks: [Int?]

    init(
        rows: Int,
        columns: Int,
        artworkCount: Int,
        stepInterval: Duration = .milliseconds(90)
    ) {
        self.rows = rows
        self.columns = columns
        self.artworkCount = artworkCount
        self.stepInterval = stepInterval
        self.cursor = Position(
            row: Int.random(in: 0..<rows),
            column: Int.random(in: 0..<columns)
        )
        self.lastArtworks = Array(repeating: nil, count: rows * columns)
    }

    /// 差し替え指示を一定間隔で流し続けるストリームを作る。
    ///
    /// 受け取り側が読むのをやめる (画面が消える、Task がキャンセルされる) と
    /// ストリームの終了が通知され、生成側のループも止まる。
    func flips() -> AsyncStream<TileFlip> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    if let flip = nextFlip() {
                        continuation.yield(flip)
                    }
                    try? await Task.sleep(for: stepInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// いまのカーソル位置への差し替え指示を作り、カーソルを隣へ進める。
    private func nextFlip() -> TileFlip? {
        let position = cursor
        if let next = randomNeighbor(of: position) {
            cursor = next
        }

        let index = position.row * columns + position.column
        guard let artwork = randomArtwork(excluding: lastArtworks[index]) else {
            return nil
        }
        lastArtworks[index] = artwork

        return TileFlip(row: position.row, column: position.column, artwork: artwork)
    }

    private static let directions = [(-1, 0), (1, 0), (0, -1), (0, 1)]

    /// 上下左右のランダムな方向へ 1 マス動いた位置を返す。
    ///
    /// 範囲外に出た場合は移動前の位置から別の方向を試し直す。
    /// 試していない方向からランダムに選び直すのは、範囲外を捨てて
    /// 引き直し続けるのと同じ結果になり、かつ必ず終了する。
    private func randomNeighbor(of position: Position) -> Position? {
        for (rowDelta, columnDelta) in Self.directions.shuffled() {
            let candidate = Position(
                row: position.row + rowDelta,
                column: position.column + columnDelta
            )
            if (0..<rows).contains(candidate.row), (0..<columns).contains(candidate.column) {
                return candidate
            }
        }
        return nil
    }
}
