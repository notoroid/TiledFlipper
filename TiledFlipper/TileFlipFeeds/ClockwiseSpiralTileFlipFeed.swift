//
//  ClockwiseSpiralTileFlipFeed.swift
//  TiledFlipper
//

import Foundation

/// 四隅のうちランダムな 1 点から、時計回り (右巻き) に渦を描いて進む差し替え指示を流す供給元。
///
/// 1 つの頭が 1 ステップにつき 1 マスずつ進む。外周を回り終えたら 1 つ内側のリングの
/// 同じ隅へ移り、中心まで来たら 1 周が終わる。次の周は起点の隅を選び直すので、
/// 毎回どこから始まるかが変わる。
@MainActor
final class ClockwiseSpiralTileFlipFeed: TileFlipFeed {
    /// グリッド上の位置
    private struct Position {
        var row: Int
        var column: Int
    }

    /// 周の起点になる隅
    private enum Corner: CaseIterable {
        case leftTop
        case rightTop
        case rightBottom
        case leftBottom
    }

    let rows: Int
    let columns: Int
    /// 差し替え先に選べるアートワークの数
    let artworkCount: Int
    /// 次のマスへ進むまでの間隔。
    /// フリップ 1 回分より短くすることで、フリップが完了する前に次が始まり、
    /// 起点から順に連鎖しているように見える。
    let stepInterval: Duration
    /// 受け取り側でのフリップ 1 回分の長さ。
    /// 1 周の最後のマスが回り終えるのを待つために使うので、
    /// TileGridModel.flipDuration と揃える。
    let flipDuration: Duration

    /// 四隅それぞれを起点にした、外周から中心へ向かう時計回りの経路。
    /// 経路はグリッドの大きさだけで決まるので、4 通りとも 1 度だけ組み立てて使い回す。
    private let paths: [[Position]]

    /// 各タイルへ最後に流したアートワーク。
    /// 同じ画像への差し替えを避け、変化が必ず見えるようにするために覚えておく。
    private var lastArtworks: [Int?]

    init(
        rows: Int,
        columns: Int,
        artworkCount: Int,
        stepInterval: Duration = .milliseconds(90),
        flipDuration: Duration = .milliseconds(600)
    ) {
        self.rows = rows
        self.columns = columns
        self.artworkCount = artworkCount
        self.stepInterval = stepInterval
        self.flipDuration = flipDuration
        self.paths = Corner.allCases.map { Self.makePath(rows: rows, columns: columns, from: $0) }
        self.lastArtworks = Array(repeating: nil, count: max(0, rows * columns))
    }

    /// 差し替え指示を一定間隔で流し続けるストリームを作る。
    ///
    /// 中心まで到達したら起点の隅を選び直して次の周に入り、止められるまで繰り返す。
    /// 受け取り側が読むのをやめるとストリームの終了が通知され、生成側のループも止まる。
    func flips() -> AsyncStream<TileFlip> {
        AsyncStream { continuation in
            guard paths.contains(where: { !$0.isEmpty }) else {
                continuation.finish()
                return
            }

            let task = Task {
                while !Task.isCancelled {
                    // 1 周ごとに、四隅のどこから始めるかを選び直す。
                    guard let path = paths.randomElement() else { break }

                    for position in path {
                        if let flip = nextFlip(at: position) {
                            continuation.yield(flip)
                        }
                        try? await Task.sleep(for: stepInterval)
                        if Task.isCancelled { break }
                    }

                    // 1 周ぶんを流し終えても中心のマスはまだ回っている途中なので、
                    // それが終わるまで待ってから次の周に入る。周と周が重ならず、
                    // 全マスが揃った状態が一瞬見えてから次が始まる。
                    try? await Task.sleep(for: flipDuration)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 指定したマスへの差し替え指示を作る。
    private func nextFlip(at position: Position) -> TileFlip? {
        let index = position.row * columns + position.column
        guard let artwork = randomArtwork(excluding: lastArtworks[index]) else {
            return nil
        }
        lastArtworks[index] = artwork

        return TileFlip(row: position.row, column: position.column, artwork: artwork)
    }

    /// 指定した隅を起点に、外周から中心へ向かって時計回りに 1 マスずつ進む経路を組み立てる。
    private static func makePath(rows: Int, columns: Int, from corner: Corner) -> [Position] {
        var path: [Position] = []
        var top = 0
        var left = 0
        var bottom = rows - 1
        var right = columns - 1

        // 内側のリングも同じ隅から始めることで、外周から中心まで 1 本の渦になる。
        while top <= bottom, left <= right {
            path += ring(top: top, left: left, bottom: bottom, right: right, columns: columns, from: corner)
            top += 1
            left += 1
            bottom -= 1
            right -= 1
        }

        return path
    }

    /// リング 1 周ぶんのマスを、指定した隅から時計回りに並べて返す。
    private static func ring(
        top: Int,
        left: Int,
        bottom: Int,
        right: Int,
        columns: Int,
        from corner: Corner
    ) -> [Position] {
        // 左上から時計回りに 1 周する経路。1 行・1 列まで縮んだリングでは
        // 同じマスを 2 度通るので、既に通ったマスは飛ばして重複を防ぐ。
        var path: [Position] = []
        var visited = Set<Int>()
        func append(row: Int, column: Int) {
            guard visited.insert(row * columns + column).inserted else { return }
            path.append(Position(row: row, column: column))
        }

        for column in left...right { append(row: top, column: column) }
        for row in top...bottom { append(row: row, column: right) }
        for column in stride(from: right, through: left, by: -1) { append(row: bottom, column: column) }
        for row in stride(from: bottom, through: top, by: -1) { append(row: row, column: left) }

        // 起点の隅が先頭に来るよう回す。縮んだリングでは隅同士が重なるが、
        // その場合も同じマスが先頭に来るだけで経路は変わらない。
        let start: Position = switch corner {
        case .leftTop: Position(row: top, column: left)
        case .rightTop: Position(row: top, column: right)
        case .rightBottom: Position(row: bottom, column: right)
        case .leftBottom: Position(row: bottom, column: left)
        }
        guard let offset = path.firstIndex(where: { $0.row == start.row && $0.column == start.column })
        else {
            return path
        }

        // 1 行・1 列まで縮んだリングは線なので回り方が決まらない。
        // 起点が反対側の端なら向きを反転させて、端から端へまっすぐ進ませる。
        if top == bottom || left == right {
            return offset == 0 ? path : path.reversed()
        }

        return Array(path[offset...] + path[..<offset])
    }
}
