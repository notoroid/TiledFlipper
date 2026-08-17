//
//  ArtworkCollectionCardList.swift
//  TiledFlipper
//

import SwiftUI

/// アートワークコレクションを、横方向にスライドするカード一覧から選ぶビュー。
///
/// カードにはタイルと同じ行・列数のプレビューを描き、どんな絵柄が並ぶのかが
/// 選ぶ前に分かるようにしている。カード全体がタップ領域で、触れたカードの
/// コレクションが選択される。
struct ArtworkCollectionCardList: View {
    let collections: [ArtworkCollection]
    /// プレビューの行・列数。タイルと揃えて、実際の並びに近い見た目にする。
    let previewRows: Int
    let previewColumns: Int
    @Binding var selection: ArtworkCollection

    /// プレビューの一辺の長さ
    private let previewSize: CGFloat = 108
    private let cornerRadius: CGFloat = 20

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 12) {
                ForEach(collections) { collection in
                    Button {
                        selection = collection
                    } label: {
                        card(for: collection)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collection.displayName)
                    .accessibilityAddTraits(collection == selection ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .scrollTargetLayout()
        }
        // カードの途中で止まらないよう、カードの境目に吸い付かせる
        .scrollTargetBehavior(.viewAligned)
        .scrollIndicators(.hidden)
    }

    private func card(for collection: ArtworkCollection) -> some View {
        let isSelected = collection == selection

        return VStack(spacing: 8) {
            ArtworkCollectionPreview(
                catalog: ArtworkCatalog.catalog(for: collection),
                rows: previewRows,
                columns: previewColumns
            )
            .frame(width: previewSize, height: previewSize)
            .clipShape(.rect(cornerRadius: 8))

            Text(collection.displayName)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
                .lineLimit(1)
        }
        .padding(10)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
        // 選択中のカードだけ縁取りを見せる
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.white.opacity(isSelected ? 0.9 : 0), lineWidth: 2)
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}

/// カードに載せる、コレクションの絵柄を並べたプレビュー。
///
/// タイル本体と同じく、View を敷き詰めるのではなく `Canvas` で 1 パスに描く。
/// 並べるアートワークは先頭から順に固定で選ぶので、再描画しても絵柄は変わらない。
private struct ArtworkCollectionPreview: View {
    let catalog: ArtworkCatalog
    let rows: Int
    let columns: Int

    var body: some View {
        Canvas { context, size in
            let names = catalog.names
            guard !names.isEmpty else { return }

            let layout = TileLayout(rows: rows, columns: columns, spacing: 1, bounds: size)
            for row in 0..<rows {
                for column in 0..<columns {
                    let frame = layout.frame(row: row, column: column)
                    // 点数が枠より少ないコレクションでも埋まるよう、足りない分は先頭から繰り返す
                    let name = names[(row * columns + column) % names.count]

                    context.fill(Path(frame), with: .color(Self.tileBackground))
                    if let image = catalog.image(named: name) {
                        context.draw(image, in: frame)
                    }
                }
            }
        }
    }

    private static let tileBackground = Color(white: 0.12)
}

#Preview {
    @Previewable @State var selection = ArtworkCatalog.defaultCollection

    ArtworkCollectionCardList(
        collections: ArtworkCatalog.collections,
        previewRows: 9,
        previewColumns: 9,
        selection: $selection
    )
    .frame(maxHeight: .infinity)
    .background(Color.black)
}
