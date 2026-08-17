//
//  ArtworkCatalog.swift
//  TiledFlipper
//

import SwiftUI
import UIKit

/// アートワークコレクション 1 つ分の定義。
///
/// 表示名はバンドル上のリソース名とは別に持つ。JSON や画像フォルダの名前を
/// 変えずに、UI 上の呼び名だけを付け替えられるようにするため。
struct ArtworkCollection: Identifiable, Hashable, Sendable {
    /// バンドルにある JSON のリソース名 (拡張子なし)。
    /// 画像は同じ名前に `.files` を付けたフォルダに入っている。
    let resourceName: String
    /// UI に表示する名前
    let displayName: String

    /// リソース名はバンドル内で一意なので、そのまま識別子に使う。
    var id: String { resourceName }
}

/// 1 つのアートワークコレクションについて、タイルに表示する画像を集めたもの。
///
/// Canvas は毎フレーム全タイルを描き直すため、JSON の解析と `Image` の生成は
/// コレクションごとに 1 度だけ行い、以降は名前で引くだけにしている。
/// 画像は 64x64 と小さく、点数も 100 件程度なので全件を持っておいて問題ない。
final class ArtworkCatalog {
    /// 選択できるコレクション。表示名はここで自由に付け替えられる。
    static let collections: [ArtworkCollection] = [
        ArtworkCollection(resourceName: "Albumartworks", displayName: "Albums Vol.1"),
        ArtworkCollection(resourceName: "Albumartworks2", displayName: "Albums Vol.2"),
    ]

    /// 起動時に表示するコレクション
    static let defaultCollection = collections[0]

    /// 読み込み済みのカタログ。切り替えで戻ってきたときに読み直さないよう覚えておく。
    private static var loaded: [ArtworkCollection.ID: ArtworkCatalog] = [:]

    /// コレクションに対応するカタログを返す。同じコレクションには常に同じ実体を返す。
    static func catalog(for collection: ArtworkCollection) -> ArtworkCatalog {
        if let catalog = loaded[collection.id] {
            return catalog
        }

        let catalog = ArtworkCatalog(collection: collection)
        loaded[collection.id] = catalog
        return catalog
    }

    let collection: ArtworkCollection
    /// artwork のファイル名一覧 (例: "001.png")
    let names: [String]

    private let images: [String: Image]

    private init(collection: ArtworkCollection) {
        self.collection = collection

        let names = Self.loadNames(for: collection)
        self.names = names
        self.images = Dictionary(
            uniqueKeysWithValues: names.compactMap { name in
                guard let uiImage = Self.loadImage(named: name, in: collection) else {
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

    private static func loadNames(for collection: ArtworkCollection) -> [String] {
        struct Entry: Decodable {
            let artwork: String
        }

        guard let url = Bundle.main.url(forResource: collection.resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            return []
        }

        // artwork には "001.png" と "Foo.files/001.png" のようにフォルダ付きで
        // 書かれているものが混ざる。バンドル内での探し方は同じなので、
        // ファイル名だけに揃えてから扱う。
        // 同じアートワークが複数エントリにあっても 1 件として扱う。
        var seen = Set<String>()
        return entries
            .map { URL(fileURLWithPath: $0.artwork).lastPathComponent }
            .filter { seen.insert($0).inserted }
    }

    private static func loadImage(named name: String, in collection: ArtworkCollection) -> UIImage? {
        // 画像はアセットカタログではなくバンドル内の PNG なので、ファイル名 (拡張子込み) で
        // URL を引いて読み込む。コレクション間でファイル名が重なっても取り違えないよう、
        // まず自分のフォルダの中を探し、見つからなければバンドル直下を探す。
        let url = Bundle.main.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "\(collection.resourceName).files"
        ) ?? Bundle.main.url(forResource: name, withExtension: nil)

        guard let url else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
