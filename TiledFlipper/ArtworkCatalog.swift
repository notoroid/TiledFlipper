//
//  ArtworkCatalog.swift
//  TiledFlipper
//

import SwiftUI
import UIKit

/// 1 つのアートワークコレクションについて、タイルに表示する画像を集めたもの。
///
/// Canvas は毎フレーム全タイルを描き直すため、読み込みと `Image` の生成は
/// コレクションごとに 1 度だけ行い、以降は名前で引くだけにしている。
/// 画像は 64x64 と小さく、点数も 100 件程度なので全件を持っておいて問題ない。
final class ArtworkCatalog {
    /// アプリに同梱しているコレクション。表示名はここで自由に付け替えられる。
    static let bundledCollections: [any ArtworkCollection] = [
        BundleArtworkCollection(resourceName: "Albumartworks", displayName: "Albums Vol.1"),
        BundleArtworkCollection(resourceName: "Albumartworks2", displayName: "Albums Vol.2"),
    ]

    /// 起動時に表示するコレクション
    static let defaultCollection: any ArtworkCollection = bundledCollections[0]

    /// オンラインで配られているコレクション。
    ///
    /// 一覧が取れなければ同梱ぶんだけで動かしたいので、失敗は空として扱う。
    /// アートワークの実体はここでは落とさず、選ばれたときの `fetch()` で取りに行く。
    static func onlineCollections() async -> [any ArtworkCollection] {
        guard let descriptions = try? await TileFlipServcice.getDescriptions() else {
            return []
        }
        return descriptions.map { NetworkArtworkCollection(description: $0) }
    }

    /// 読み込み済みのカタログ。切り替えで戻ってきたときに読み直さないよう覚えておく。
    private static var loaded: [String: ArtworkCatalog] = [:]

    /// コレクションに対応するカタログを返す。同じコレクションには常に同じ実体を返す。
    static func catalog(for collection: any ArtworkCollection) -> ArtworkCatalog {
        if let catalog = loaded[collection.id] {
            return catalog
        }

        let catalog = ArtworkCatalog(collection: collection)
        // ネットワークのコレクションは取得前だと空になる。それを覚えてしまうと
        // 取得後も空のままになるので、中身があるものだけ残す。
        if !catalog.names.isEmpty {
            loaded[collection.id] = catalog
        }
        return catalog
    }

    let collection: any ArtworkCollection
    /// 画像を読めた artwork の名前一覧 (例: "Albumartworks.files/001.png")
    let names: [String]

    private let images: [String: Image]

    private init(collection: any ArtworkCollection) {
        self.collection = collection

        let listed = collection.loadArtworkNames()
        let images: [String: Image] = Dictionary(
            uniqueKeysWithValues: listed.compactMap { name in
                guard let uiImage = collection.loadImage(named: name) else {
                    return nil
                }
                // タイルは元画像より大きく表示されるので、補間を指定して粗さを抑える
                return (name, Image(uiImage: uiImage).interpolation(.medium))
            }
        )
        self.images = images
        // 一覧に名前があっても実体が無いことがある (配布パッケージの取りこぼしなど)。
        // タイルが空のまま残らないよう、読めたものだけを一覧の順で持つ。
        self.names = listed.filter { images[$0] != nil }
    }

    func image(named name: String) -> Image? {
        images[name]
    }

    /// ランダムなアートワークを 1 つ返す。
    /// 差し替わったことが分かるよう、指定したものは候補から外す。
    func randomName(excluding excluded: String?) -> String? {
        let candidates = names.filter { $0 != excluded }
        return candidates.randomElement() ?? names.randomElement()
    }
}
