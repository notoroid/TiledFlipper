//
//  RandomizedTileFlipFeed.swift
//  TiledFlipperServerCore
//
//  アプリ側 `TiledFlipper/TileFlipFeeds/RandomizedTileFlipFeed.swift` の移植。
//  演出そのものは変えていないので、直すときは両方を見比べること。
//

/// 用意した演出をランダムに切り替えながら差し替え指示を流す供給元。
///
/// 1 つの演出はグリッド 1 面ぶん (`flipsPerTurn` 枚) を流したら役目を終える。
/// 終わる寸前 (残り `handoverFlips` 枚になった時点) で次の演出を始めるので、
/// 前の演出の最後のフリップと重なりながら入れ替わり、切れ目で盤面が止まらない。
///
/// 演出は切り替えのたびに作り直す。途中で止めた状態 (走っている頭やカーソル) を
/// 持ち越さないので、次に選ばれたときは必ず最初から始まる。
@TileFlipFeedActor
final class RandomizedTileFlipFeed: TileFlipFeed {
    /// 切り替え先の演出
    private enum Kind: CaseIterable {
        case randomWalk
        case clockwiseSpiral
        case fallingColumn
        case zigzag
    }

    let rows: Int
    let columns: Int
    /// 差し替え先に選べるアートワークの数。作る演出にそのまま渡す。
    let artworkCount: Int
    /// 1 つの演出が流す枚数。既定はグリッド 1 面ぶん。
    let flipsPerTurn: Int
    /// 残り何枚になったら次の演出を始めるか。この枚数だけ 2 つの演出が重なる。
    let handoverFlips: Int
    /// クライアントでのフリップ 1 回分の長さ。`ClockwiseSpiralTileFlipFeed` へ渡す。
    let flipDuration: Duration
    /// 次のマスへ進むまでの間隔。作る演出にそのまま渡す。
    ///
    /// アプリ側は各演出の既定値に任せていて、この持ち物が無い。サーバーでは
    /// openapi.yaml の `step_interval` がどの演出でも効くようにしたいので持たせてある。
    let stepInterval: Duration

    /// 直前に選んだ演出。続けて同じものを選ばないために覚えておく。
    private var lastKind: Kind?

    init(
        rows: Int,
        columns: Int,
        artworkCount: Int,
        flipsPerTurn: Int? = nil,
        handoverFlips: Int = 6,
        flipDuration: Duration = .milliseconds(600),
        stepInterval: Duration = .milliseconds(90)
    ) {
        self.rows = rows
        self.columns = columns
        self.artworkCount = artworkCount
        self.flipDuration = flipDuration
        self.stepInterval = stepInterval

        let perTurn = max(1, flipsPerTurn ?? (rows * columns))
        self.flipsPerTurn = perTurn
        // 重なりぶんは 1 回ぶんより短くないと、次を呼ぶ合図が出せない
        self.handoverFlips = min(max(0, handoverFlips), perTurn - 1)
    }

    /// 差し替え指示を流し続けるストリームを作る。
    ///
    /// 止められるまで、演出を切り替えながら流し続ける。
    /// 受け取り側が読むのをやめるとストリームの終了が通知され、走っている演出も止まる。
    func flips() -> AsyncStream<TileFlip> {
        AsyncStream { continuation in
            guard rows > 0, columns > 0 else {
                continuation.finish()
                return
            }

            let task = Task {
                // 入れ替わりの間は 2 つの演出が同時に流れる
                var previous: Task<Void, Never>?
                var current: Task<Void, Never>?

                while !Task.isCancelled {
                    let (handover, signal) = AsyncStream<Void>.makeStream()
                    let feed = makeFeed(nextKind())

                    // 担当ぶんを流し切ったら、その演出は自分で終わる。
                    // for-await を抜けるとストリームの終了が伝わり、演出側のループも止まる。
                    let forwarding = Task {
                        var remaining = flipsPerTurn
                        for await flip in feed.flips() {
                            continuation.yield(flip)

                            remaining -= 1
                            // 終わる寸前になったら次の演出を呼ぶ
                            if remaining == handoverFlips {
                                signal.yield(())
                            }
                            if remaining <= 0 {
                                break
                            }
                        }
                        signal.finish()
                    }

                    previous = current
                    current = forwarding

                    // 寸前の合図を待って、次の演出へ移る
                    for await _ in handover { break }
                }

                previous?.cancel()
                current?.cancel()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 直前とは違う演出をランダムに選ぶ。
    private func nextKind() -> Kind {
        let candidates = Kind.allCases.filter { $0 != lastKind }
        let kind = candidates.randomElement() ?? .randomWalk
        lastKind = kind

        return kind
    }

    /// 演出を新しく作る。
    private func makeFeed(_ kind: Kind) -> any TileFlipFeed {
        switch kind {
        case .randomWalk:
            RandomWalkTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                stepInterval: stepInterval
            )
        case .clockwiseSpiral:
            ClockwiseSpiralTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                stepInterval: stepInterval,
                flipDuration: flipDuration
            )
        case .fallingColumn:
            FallingColumnTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                stepInterval: stepInterval
            )
        case .zigzag:
            ZigzagTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                stepInterval: stepInterval
            )
        }
    }
}
