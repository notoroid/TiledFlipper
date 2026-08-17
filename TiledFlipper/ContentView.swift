//
//  ContentView.swift
//  TiledFlipper
//
//  Created by 能登 要 on 2026/08/16.
//

import SwiftUI

/// タイル全体を AspectFit で画面中央に配置するためのレイアウト計算。
///
/// タイルは常に正方形で、行・列数と間隔から 1 枚あたりのサイズと
/// 全体の描画原点を求める。ヒットテストやアニメーションからも
/// 同じ計算を再利用できるよう、描画とは独立した値型にしている。
struct TileLayout {
    let rows: Int
    let columns: Int
    let spacing: CGFloat
    /// タイル 1 枚の一辺の長さ
    let tileSize: CGFloat
    /// タイル全体 (グリッド) の左上座標
    let origin: CGPoint

    init(rows: Int, columns: Int, spacing: CGFloat, bounds: CGSize) {
        self.rows = rows
        self.columns = columns
        self.spacing = spacing

        // 間隔を除いた残りを行数・列数で割り、小さい方に合わせる (AspectFit)
        let availableWidth = bounds.width - spacing * CGFloat(columns - 1)
        let availableHeight = bounds.height - spacing * CGFloat(rows - 1)
        let size = min(availableWidth / CGFloat(columns), availableHeight / CGFloat(rows))
        self.tileSize = max(0, size)

        let contentWidth = tileSize * CGFloat(columns) + spacing * CGFloat(columns - 1)
        let contentHeight = tileSize * CGFloat(rows) + spacing * CGFloat(rows - 1)
        self.origin = CGPoint(
            x: (bounds.width - contentWidth) / 2,
            y: (bounds.height - contentHeight) / 2
        )
    }

    /// 指定した行・列のタイルが占める矩形
    func frame(row: Int, column: Int) -> CGRect {
        CGRect(
            x: origin.x + CGFloat(column) * (tileSize + spacing),
            y: origin.y + CGFloat(row) * (tileSize + spacing),
            width: tileSize,
            height: tileSize
        )
    }
}

/// 9 行 9 列のタイルを画面中央に表示し、選択タイルを次々にフリップさせるビュー。
///
/// タイル数の増加や高頻度の再描画に耐えるため、タイルごとに View を作らず
/// `Canvas` で 1 パスにまとめて描画する。アニメーションは SwiftUI の暗黙
/// アニメーションではなく、`TimelineView` が渡す時刻とタイルごとの
/// フリップ開始時刻の差から毎フレーム計算する。
struct ContentView: View {
    /// タイル同士の間隔
    private let spacing: CGFloat = 5

    @State private var model = TileGridModel(rows: 9, columns: 9)

    var body: some View {
        GeometryReader { proxy in
            let layout = TileLayout(
                rows: model.rows,
                columns: model.columns,
                spacing: spacing,
                bounds: proxy.size
            )

            TimelineView(.animation) { timeline in
                // 陰影を半透明で重ねるため、opaque な Canvas にはしない。
                // 背景の黒は下地のビューが担当する。
                Canvas { context, _ in
                    for row in 0..<model.rows {
                        for column in 0..<model.columns {
                            draw(
                                tile: model.tiles[row * model.columns + column],
                                in: layout.frame(row: row, column: column),
                                at: timeline.date,
                                into: &context
                            )
                        }
                    }
                }
            }
        }
        .background(Color.black)
        .ignoresSafeArea()
        .task { await model.run() }
    }

    /// フリップの進行度に応じて、横に潰したアートワークを描く。
    private func draw(
        tile: Tile,
        in frame: CGRect,
        at now: Date,
        into context: inout GraphicsContext
    ) {
        let appearance = tile.appearance(at: now, duration: model.flipDuration)
        let width = frame.width * appearance.scale
        // 真横を向いている一瞬は描いても見えないので省く
        guard width >= 0.5 else { return }

        let rect = CGRect(
            x: frame.midX - width / 2,
            y: frame.minY,
            width: width,
            height: frame.height
        )

        // 画像が透過を含んでいてもタイルの形が保たれるよう、下地を敷いてから描く
        context.fill(Path(rect), with: .color(Self.tileBackground))
        if let image = ArtworkCatalog.image(named: appearance.artwork) {
            context.draw(image, in: rect)
        }

        // 真横に近いほど暗くして、板が回っているように見せる
        context.fill(Path(rect), with: .color(.black.opacity(0.45 * (1 - appearance.scale))))
    }

    private static let tileBackground = Color(white: 0.12)
}

#Preview {
    ContentView()
}
