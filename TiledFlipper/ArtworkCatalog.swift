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
    /// 選択できるコレクション。表示名はここで自由に付け替えられる。
    static let collections: [any ArtworkCollection] = [
        BundleArtworkCollection(resourceName: "Albumartworks", displayName: "Albums Vol.1"),
        BundleArtworkCollection(resourceName: "Albumartworks2", displayName: "Albums Vol.2"),
    ]

    /// 起動時に表示するコレクション
    static let defaultCollection: any ArtworkCollection = collections[0]

    /// 読み込み済みのカタログ。切り替えで戻ってきたときに読み直さないよう覚えておく。
    private static var loaded: [String: ArtworkCatalog] = [:]

    /// コレクションに対応するカタログを返す。同じコレクションには常に同じ実体を返す。
    static func catalog(for collection: any ArtworkCollection) -> ArtworkCatalog {
        if let catalog = loaded[collection.id] {
            return catalog
        }

        let catalog = ArtworkCatalog(collection: collection)
        loaded[collection.id] = catalog
        return catalog
    }

    let collection: any ArtworkCollection
    /// artwork のファイル名一覧 (例: "001.png")
    let names: [String]

    private let images: [String: Image]

    private init(collection: any ArtworkCollection) {
        self.collection = collection

        let names = collection.loadArtworkNames()
        self.names = names
        self.images = Dictionary(
            uniqueKeysWithValues: names.compactMap { name in
                guard let uiImage = collection.loadImage(named: name) else {
                    return nil
                }
                // タイルは元画像より大きく表示されるので、補間を指定して粗さを抑える
                return (name, Image(uiImage: uiImage).interpolation(.medium))
            }
        )
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
