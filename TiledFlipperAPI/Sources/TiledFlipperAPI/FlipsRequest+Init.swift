//
//  FlipsRequest+Init.swift
//  TiledFlipperAPI
//

import SwiftProtobuf

extension Tiledflipper_V1_FlipsRequest {

    /// Swift 側の型で `Flips` の引数を組み立てる。
    ///
    /// 呼び出し側が `Int` や `Duration` を proto の型へ直す手間 (と
    /// SwiftProtobuf への依存) を持たずに済むようにしている。
    /// nil を渡した分は送らず、サーバー側の既定値に任せる。
    ///
    /// - Parameters:
    ///   - rows: グリッドの行数。
    ///   - columns: グリッドの列数。
    ///   - artworkCount: 差し替え先に選べるアートワークの数。
    ///   - feedKind: 流し方。未指定は `FEED_KIND_RANDOMIZED` と同じ扱い。
    ///   - stepInterval: 次のマスへ進むまでの間隔。
    ///   - flipDuration: 受け取る側でのフリップ 1 回分の長さ。
    ///   - flipsPerTurn: `FEED_KIND_RANDOMIZED` のみ。1 つの演出が流す枚数。
    ///   - handoverFlips: `FEED_KIND_RANDOMIZED` のみ。残り何枚で次の演出を始めるか。
    ///   - columnsPerDrop: `FEED_KIND_FALLING_COLUMN` のみ。何カラムあたり 1 本落とすか。
    public init(
        rows: Int,
        columns: Int,
        artworkCount: Int,
        feedKind: Tiledflipper_V1_FeedKind = .unspecified,
        stepInterval: Duration? = nil,
        flipDuration: Duration? = nil,
        flipsPerTurn: Int? = nil,
        handoverFlips: Int? = nil,
        columnsPerDrop: Int? = nil
    ) {
        self.init()
        self.rows = Int32(rows)
        self.columns = Int32(columns)
        self.artworkCount = Int32(artworkCount)
        self.feedKind = feedKind
        if let stepInterval {
            self.stepInterval = Google_Protobuf_Duration(rounding: stepInterval)
        }
        if let flipDuration {
            self.flipDuration = Google_Protobuf_Duration(rounding: flipDuration)
        }
        if let flipsPerTurn {
            self.flipsPerTurn = Int32(flipsPerTurn)
        }
        if let handoverFlips {
            self.handoverFlips = Int32(handoverFlips)
        }
        if let columnsPerDrop {
            self.columnsPerDrop = Int32(columnsPerDrop)
        }
    }
}

extension Google_Protobuf_Duration {
    /// Swift の `Duration` から作る。
    ///
    /// `google.protobuf.Duration` はナノ秒までしか持てないので、それより
    /// 細かい分は切り捨てる。演出の間隔にナノ秒未満の意味は無い。
    fileprivate init(rounding duration: Duration) {
        let components = duration.components
        self.init(
            seconds: components.seconds,
            nanos: Int32(components.attoseconds / 1_000_000_000)
        )
    }
}
