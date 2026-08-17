//
//  TileGridModel.swift
//  TiledFlipper
//

import SwiftUI

/// タイル 1 枚分の状態。
///
/// フリップの見た目は「開始時刻」と描画時の現在時刻の差から毎フレーム
/// 計算する。タイルごとに独立した開始時刻を持つため、前のフリップの
/// 完了を待たずに次のフリップを始められる。
struct Tile {
    /// フリップ後に表示するアートワークのファイル名
    var artwork: String
    /// フリップ前のアートワーク。フリップの前半はこちらを表示する。
    var previousArtwork: String
    /// フリップ開始時刻。nil ならフリップしていない。
    var flipStart: Date?

    /// 指定時刻における表示アートワークと、横方向の縮小率 (1 = 正面、0 = 真横) を求める。
    func appearance(at now: Date, duration: TimeInterval) -> (artwork: String, scale: Double) {
        guard let flipStart else { return (artwork, 1) }

        let progress = now.timeIntervalSince(flipStart) / duration
        guard progress > 0, progress < 1 else { return (artwork, 1) }

        // 板が 180 度回るので、幅は 1 → 0 → 1 と変化する。
        // 真横を向いて幅が 0 になる中間点で、画像を新しいものへ切り替える。
        return (progress < 0.5 ? previousArtwork : artwork, abs(cos(progress * .pi)))
    }

    /// 実行中のフリップを中断して、新しいフリップを始める。
    ///
    /// 中断時点で「見えている」アートワークと幅をそのまま引き継ぐため、
    /// 割り込みが起きても画像が飛んだり、幅が急に戻ったりしない。
    mutating func restartFlip(to newArtwork: String, at now: Date, duration: TimeInterval) {
        let appearance = appearance(at: now, duration: duration)

        previousArtwork = appearance.artwork
        artwork = newArtwork

        // 幅は scale = |cos(pi * progress)| なので、いま同じ幅になる前半の進行度は
        // acos(scale) / pi。その分だけ開始時刻を過去にずらして、続きから回す。
        // フリップしていないタイルは scale = 1 なので、そのまま今から始まる。
        let progress = acos(min(1, max(0, appearance.scale))) / .pi
        flipStart = now.addingTimeInterval(-progress * duration)
    }
}

/// タイル群の状態と、選択タイルのランダムウォークを管理する。
@MainActor
@Observable
final class TileGridModel {
    /// グリッド上の位置
    struct Position {
        var row: Int
        var column: Int
    }

    let rows: Int
    let columns: Int
    /// フリップ 1 回分の長さ
    let flipDuration: TimeInterval = 0.6
    /// 選択が次のタイルへ移るまでの間隔。
    /// `flipDuration` より短くすることで、フリップが完了する前に次が始まり、
    /// 連鎖しているように見える。
    let stepInterval: Duration = .milliseconds(90)

    private(set) var tiles: [Tile]
    private var cursor: Position

    init(rows: Int, columns: Int) {
        self.rows = rows
        self.columns = columns
        self.tiles = (0..<(rows * columns)).map { _ in
            let artwork = ArtworkCatalog.names.randomElement() ?? ""
            return Tile(artwork: artwork, previousArtwork: artwork, flipStart: nil)
        }
        self.cursor = Position(
            row: Int.random(in: 0..<rows),
            column: Int.random(in: 0..<columns)
        )
    }

    /// 選択タイルのフリップを開始し、続けて選択を隣へ移す。
    /// フリップの完了は待たない。
    func advance(now: Date = .now) {
        startFlip(at: cursor, now: now)
        if let next = randomNeighbor(of: cursor) {
            cursor = next
        }
    }

    /// 一定間隔で選択を進め続ける。
    func run() async {
        while !Task.isCancelled {
            advance()
            try? await Task.sleep(for: stepInterval)
        }
    }

    /// 選択タイルのフリップを開始する。
    /// すでにフリップ中なら、それを中断して新しいフリップに差し替える。
    private func startFlip(at position: Position, now: Date) {
        let index = position.row * columns + position.column
        var tile = tiles[index]

        // 中断の場合、除外すべきは「いま見えている」アートワーク。
        // これを外さないと、同じ画像へのフリップになり変化が見えないことがある。
        let displayed = tile.appearance(at: now, duration: flipDuration).artwork
        guard let next = ArtworkCatalog.randomName(excluding: displayed) else { return }

        tile.restartFlip(to: next, at: now, duration: flipDuration)
        tiles[index] = tile
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
