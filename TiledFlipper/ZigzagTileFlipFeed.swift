//
//  ZigzagTileFlipFeed.swift
//  TiledFlipper
//

import Foundation

/// 上端の左右どちらかから始まり、水平に進んでは折り返しながら下っていく差し替え指示を流す供給元。
///
/// 頭は 1 ステップにつき 1 マス横へ進み、タイルの範囲外 (列 -1 または列数) に達したら
/// 1 行下りて向きを変える。最下段の次の行に達したところで、その頭は 1 つぶんの
/// アニメーションを終える。
///
/// 直近に始めた頭が全体の半分の行まで下りたら次の頭を出すので、常に 2〜3 本が
/// 同時に走っている状態になる。
@MainActor
final class ZigzagTileFlipFeed: TileFlipFeed {
    /// 蛇行しながら下る頭 1 つぶん。
    private struct Head {
        var row: Int
        /// 次にフリップする列。範囲外 (-1 または列数) のときは折り返しの途中。
        var column: Int
        /// 進む向き。+1 が右、-1 が左。
        var step: Int
    }

    let rows: Int
    let columns: Int
    /// 隣のマスへ進むまでの間隔。
    /// フリップ 1 回分より短くすることで、フリップが完了する前に次のマスが始まり、
    /// 尾を引いて流れているように見える。
    let stepInterval: Duration

    private var heads: [Head] = []

    /// 各タイルへ最後に流したアートワーク。
    /// 同じ画像への差し替えを避け、変化が必ず見えるようにするために覚えておく。
    private var lastArtworks: [String?]

    init(rows: Int, columns: Int, stepInterval: Duration = .milliseconds(90)) {
        self.rows = rows
        self.columns = columns
        self.stepInterval = stepInterval
        self.lastArtworks = Array(repeating: nil, count: max(0, rows * columns))
    }

    /// 差し替え指示を一定間隔で流し続けるストリームを作る。
    ///
    /// 止められるまで、走っている頭を 1 マスずつ進めながら新しい頭を足し続ける。
    /// 受け取り側が読むのをやめるとストリームの終了が通知され、生成側のループも止まる。
    func flips() -> AsyncStream<TileFlip> {
        AsyncStream { continuation in
            guard rows > 0, columns > 0 else {
                continuation.finish()
                return
            }

            let task = Task {
                while !Task.isCancelled {
                    for flip in nextFlips() {
                        continuation.yield(flip)
                    }
                    try? await Task.sleep(for: stepInterval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 1 ステップぶん進める。
    /// 頃合いなら新しい頭を出し、走っている頭をまとめて 1 マスずつ進める。
    private func nextFlips() -> [TileFlip] {
        // 直近に出した頭が半分の行まで下りたら次を出す。
        // まだ 1 つも走っていないとき (開始直後) はすぐに出す。
        if heads.last.map({ $0.row >= rows / 2 }) ?? true {
            heads.append(makeHead())
        }

        var flips: [TileFlip] = []
        for index in heads.indices {
            if let flip = advance(&heads[index]) {
                flips.append(flip)
            }
        }
        // 最下段の次の行に達した頭は終わり
        heads.removeAll { $0.row >= rows }

        return flips
    }

    /// 上端の左右どちらかをランダムに選んで、新しい頭を作る。
    private func makeHead() -> Head {
        if Bool.random() {
            Head(row: 0, column: 0, step: 1)               // 左上から右へ
        } else {
            Head(row: 0, column: columns - 1, step: -1)    // 右上から左へ
        }
    }

    /// 頭を 1 マスぶん進める。いま居るマスへの指示を返し、次の位置へ動かす。
    ///
    /// 範囲外にいる間は指示を出さず、1 行下りて向きを変えるための 1 ステップに充てる。
    private func advance(_ head: inout Head) -> TileFlip? {
        guard (0..<columns).contains(head.column) else {
            // 範囲外に出たので 1 行下り、逆向きに折り返して端の列から再開する
            head.row += 1
            head.step = -head.step
            head.column = head.step > 0 ? 0 : columns - 1
            return nil
        }

        let flip = (0..<rows).contains(head.row) ? nextFlip(row: head.row, column: head.column) : nil
        head.column += head.step

        return flip
    }

    /// 指定したマスへの差し替え指示を作る。
    private func nextFlip(row: Int, column: Int) -> TileFlip? {
        let index = row * columns + column
        guard let artwork = ArtworkCatalog.randomName(excluding: lastArtworks[index]) else {
            return nil
        }
        lastArtworks[index] = artwork

        return TileFlip(row: row, column: column, artwork: artwork)
    }
}
