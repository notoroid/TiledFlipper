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

/// グリッドの大きさ。モデルと差し替え指示の供給元が同じ大きさを共有する。
private let gridRows = 9
private let gridColumns = 9

/// 9 行 9 列のタイルを画面中央に表示し、指示されたタイルを次々にフリップさせるビュー。
///
/// タイル数の増加や高頻度の再描画に耐えるため、タイルごとに View を作らず
/// `Canvas` で 1 パスにまとめて描画する。アニメーションは SwiftUI の暗黙
/// アニメーションではなく、`TimelineView` が渡す時刻とタイルごとの
/// フリップ開始時刻の差から毎フレーム計算する。
struct ContentView: View {
    /// タイル同士の間隔
    private let spacing: CGFloat = 5

    /// 表示中のアートワークコレクション
    @State private var selection: any ArtworkCollection = ArtworkCatalog.defaultCollection
    /// 選べるコレクション。オンラインのものは一覧が取れ次第あとから足す。
    @State private var collections: [any ArtworkCollection] = ArtworkCatalog.bundledCollections
    @State private var model = TileGridModel(
        rows: gridRows,
        columns: gridColumns,
        catalog: ArtworkCatalog.catalog(for: ArtworkCatalog.defaultCollection)
    )
    /// カード一覧を出しているか。切り替えるとき以外は畳んでおく。
    @State private var isCollectionListVisible = false
    /// 取得中のコレクション。終わるまで一覧では次の選択を受け付けない。
    @State private var fetchingCollectionID: String?

    var body: some View {
        tiles
            .overlay(alignment: .bottomTrailing) { collectionSwitcher }
            .background(Color.black.ignoresSafeArea())
            // オンラインで配られているコレクションを一覧に足す。
            // アートワークの実体は選ばれたときに落とすので、ここでは名前だけ。
            .task {
                collections = ArtworkCatalog.bundledCollections + (await ArtworkCatalog.onlineCollections())
            }
            // コレクションが変わったら、その画像でタイルを組み直して演出を流し直す。
            // 前の演出は Task のキャンセルでストリームが終わり、自然に止まる。
            .task(id: selection.id) {
                let collection = selection

                // アートワークの実体が揃うまで待つ。ネットワーク越しのコレクションでは
                // ここでダウンロードと展開が行われるので、その間は一覧を触らせない。
                fetchingCollectionID = collection.id
                do {
                    try await collection.fetch()
                } catch {
                    fetchingCollectionID = nil
                    // 取得できなかったら選択をなかったことにして、表示中のものに戻す。
                    // 表示中のコレクションの取得に失敗したときは、すでに読み込んである
                    // 画像でそのまま続ける。
                    if model.catalog.collection.id != collection.id {
                        selection = model.catalog.collection
                        return
                    }
                }
                fetchingCollectionID = nil

                let catalog = ArtworkCatalog.catalog(for: collection)
                // 起動直後は @State の初期値がすでに選択中のコレクションなので作り直さない
                if model.catalog.collection.id != collection.id {
                    model = TileGridModel(rows: gridRows, columns: gridColumns, catalog: catalog)
                }

                // 差し替え指示の供給元。`TileFlipFeed` に適合する別の演出
                // (`RandomWalkTileFlipFeed` など) へ差し替えても、ここから下の扱いは変わらない。
                let feed = RandomizedTileFlipFeed(
                    rows: gridRows,
                    columns: gridColumns,
                    catalog: catalog,
                    flipDuration: .seconds(TileGridModel.flipDuration)
                )
                await model.apply(feed.flips())
            }
    }

    /// 画面右下のボタンと、そこから開くアートワークコレクションのカード一覧。
    ///
    /// 一覧はタイルの領域を狭めず上に重ねて出す。横長の画面ではタイルの大きさが
    /// 画面の高さで決まるので、常に置いておくとタイルが小さくなってしまうため。
    private var collectionSwitcher: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if isCollectionListVisible {
                ArtworkCollectionCardList(
                    collections: collections,
                    previewRows: gridRows,
                    previewColumns: gridColumns,
                    fetchingCollectionID: fetchingCollectionID,
                    selection: $selection
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            Button {
                withAnimation(.snappy) { isCollectionListVisible.toggle() }
            } label: {
                Image(systemName: "square.stack")
                    .font(.title2)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Artwork collections")
            .padding(.trailing, 16)
        }
        .padding(.bottom, 16)
    }

    /// タイル全体。行・列数ぶんのタイルを 1 つの Canvas にまとめて描く。
    private var tiles: some View {
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
    }

    /// フリップの進行度に応じて、横に潰したアートワークを描く。
    private func draw(
        tile: Tile,
        in frame: CGRect,
        at now: Date,
        into context: inout GraphicsContext
    ) {
        let appearance = tile.appearance(at: now, duration: TileGridModel.flipDuration)
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
        if let image = model.catalog.image(named: appearance.artwork) {
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
