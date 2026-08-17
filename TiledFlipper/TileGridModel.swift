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

        // 開始時刻は指示を反映した瞬間の時刻、描画時刻は TimelineView が渡すフレームの
        // 時刻なので、描画時刻の方がわずかに過去 (progress < 0) になることがある。
        // ここで新しいアートワークを返すと、回り始める前に変更後の画像が一瞬見えて
        // ちらつくため、まだ始まっていない間は前のアートワークで正面を向かせておく。
        guard progress > 0 else { return (previousArtwork, 1) }
        guard progress < 1 else { return (artwork, 1) }

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

/// タイル群の状態を保持し、流れてくる差し替え指示を反映する。
///
/// どのタイルをどの画像にするかは決めない。それは `TileFlip` を流す供給元
/// (`RandomWalkTileFlipFeed` など) の担当で、このモデルは受け取った指示を
/// フリップの見た目に変換することだけを受け持つ。
@MainActor
@Observable
final class TileGridModel {
    /// フリップ 1 回分の長さ。
    /// 供給元が「フリップが終わるまで待つ」ためにも参照するので、型の定数にしている。
    static let flipDuration: TimeInterval = 0.6

    let rows: Int
    let columns: Int
    /// タイルに表示するアートワークの一覧。描画する側も同じものから画像を引く。
    let catalog: ArtworkCatalog

    private(set) var tiles: [Tile]

    init(rows: Int, columns: Int, catalog: ArtworkCatalog) {
        self.rows = rows
        self.columns = columns
        self.catalog = catalog
        self.tiles = (0..<(rows * columns)).map { _ in
            let artwork = catalog.names.randomElement() ?? ""
            return Tile(artwork: artwork, previousArtwork: artwork, flipStart: nil)
        }
    }

    /// 流れてくる差し替え指示を、届いた順にタイルへ反映し続ける。
    ///
    /// ストリームが終わるか、呼び出し元の Task がキャンセルされるまで戻らない。
    func apply(_ flips: AsyncStream<TileFlip>) async {
        for await flip in flips {
            apply(flip)
        }
    }

    /// 差し替え指示を 1 件反映する。
    /// すでにフリップ中のタイルなら、それを中断して新しいフリップに差し替える。
    func apply(_ flip: TileFlip, at now: Date = .now) {
        guard (0..<rows).contains(flip.row), (0..<columns).contains(flip.column) else { return }

        let index = flip.row * columns + flip.column
        var tile = tiles[index]
        tile.restartFlip(to: flip.artwork, at: now, duration: Self.flipDuration)
        tiles[index] = tile
    }
}
