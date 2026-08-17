//
//  FallingColumnTileFlipFeed.swift
//  TiledFlipper
//

import Foundation

/// ランダムに選んだ列を、上から下へ 1 行ずつ落ちるように差し替える指示を流す供給元。
///
/// 1 本の列が落ち切るのを待たずに次の列が落ち始めるので、複数の列が同時に落ちる。
/// 同時に落ちる本数は `columnsPerDrop` カラムにつき 1 本の割合で、等間隔にずらして落とす。
/// また直前に落とし始めた列は選び直しの候補から外し、同じ列が続けて落ちないようにする。
@MainActor
final class FallingColumnTileFlipFeed: TileFlipFeed {
    /// 落下中の 1 列。`row` は次にフリップする行。
    private struct Drop {
        var column: Int
        var row: Int
    }

    let rows: Int
    let columns: Int
    /// 差し替え先のアートワークを選ぶ元になるコレクション
    let catalog: ArtworkCatalog
    /// 1 行下へ進むまでの間隔。
    /// フリップ 1 回分より短くすることで、フリップが完了する前に次の行が始まり、
    /// 上から下へ流れ落ちているように見える。
    let stepInterval: Duration
    /// 何カラムあたり 1 本を落とすか。同時に落ちる本数はこの割合で決まる。
    let columnsPerDrop: Int

    /// 同時に落とす本数。`columnsPerDrop` カラムにつき 1 本。
    private let concurrentDrops: Int
    /// 次の列が落ち始めるまでに、前の列が下がる行数。
    /// 落ち切るまでの行数を本数で割り、等間隔にずらして落とす。
    private let launchSpacing: Int

    private var drops: [Drop] = []
    /// 直前に落とし始めた列。次に選ぶときの候補から外す。
    private var lastColumn: Int?

    /// 各タイルへ最後に流したアートワーク。
    /// 同じ画像への差し替えを避け、変化が必ず見えるようにするために覚えておく。
    private var lastArtworks: [String?]

    /// 前の列を落とし始めてから進んだ行数。
    private var rowsSinceLaunch: Int

    init(
        rows: Int,
        columns: Int,
        catalog: ArtworkCatalog,
        stepInterval: Duration = .milliseconds(90),
        columnsPerDrop: Int = 3
    ) {
        self.rows = rows
        self.columns = columns
        self.catalog = catalog
        self.stepInterval = stepInterval
        self.columnsPerDrop = max(1, columnsPerDrop)
        self.concurrentDrops = max(1, columns / max(1, columnsPerDrop))
        self.launchSpacing = max(1, rows / self.concurrentDrops)
        self.lastArtworks = Array(repeating: nil, count: max(0, rows * columns))
        // 最初のステップですぐ 1 本目を落とし始める
        self.rowsSinceLaunch = self.launchSpacing
    }

    /// 差し替え指示を一定間隔で流し続けるストリームを作る。
    ///
    /// 止められるまで、落ちている列を 1 行ずつ下げながら新しい列を足し続ける。
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
    /// 頃合いなら新しい列を落とし始め、落下中の列をまとめて 1 行ずつ下げる。
    private func nextFlips() -> [TileFlip] {
        // 行数が本数で割り切れないときは間隔の丸めで本数が増えうるので、
        // 落下中の本数でも歯止めをかけて割合を保つ。
        if rowsSinceLaunch >= launchSpacing, drops.count < concurrentDrops {
            startDrop()
            rowsSinceLaunch = 0
        }
        rowsSinceLaunch += 1

        var flips: [TileFlip] = []
        for index in drops.indices {
            if let flip = nextFlip(row: drops[index].row, column: drops[index].column) {
                flips.append(flip)
            }
            drops[index].row += 1
        }
        // 下端を通り過ぎた列は落ち終わり
        drops.removeAll { $0.row >= rows }

        return flips
    }

    /// 直前に落とし始めた列を避けて 1 列選び、上端から落とし始める。
    private func startDrop() {
        let candidates = (0..<columns).filter { $0 != lastColumn }
        // 1 列しかないグリッドでは避けようがないので、その列をそのまま使う
        guard let column = candidates.randomElement() ?? (0..<columns).randomElement() else { return }

        lastColumn = column
        drops.append(Drop(column: column, row: 0))
    }

    /// 指定したマスへの差し替え指示を作る。
    private func nextFlip(row: Int, column: Int) -> TileFlip? {
        let index = row * columns + column
        guard let artwork = catalog.randomName(excluding: lastArtworks[index]) else {
            return nil
        }
        lastArtworks[index] = artwork

        return TileFlip(row: row, column: column, artwork: artwork)
    }
}
