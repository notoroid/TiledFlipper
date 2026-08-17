//
//  BundleArtworkCollection.swift
//  TiledFlipper
//

import UIKit

/// アプリのバンドルに同梱したアートワークのコレクション。
///
/// リソース名の JSON にアートワークの一覧が並んでいて、画像は同じ名前に
/// `.files` を付けたフォルダに入っている。
struct BundleArtworkCollection: ArtworkCollection, Hashable {
    /// バンドルにある JSON のリソース名 (拡張子なし)。
    /// 画像は同じ名前に `.files` を付けたフォルダに入っている。
    let resourceName: String
    let displayName: String

    /// リソース名はバンドル内で一意なので、そのまま識別子に使う。
    var id: String { resourceName }

    /// バンドルに同梱済みなので取得するものはない。
    ///
    /// ネットワーク越しのコレクションでは待ち時間が生じるので、その間の見た目を
    /// 確かめられるよう仮の待ちだけ入れている。
    func fetch() async throws {
        try await Task.sleep(for: .milliseconds(500))
    }

    func loadArtworkNames() -> [String] {
        struct Entry: Decodable {
            let artwork: String
        }

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
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

    func loadImage(named name: String) -> UIImage? {
        // 画像はアセットカタログではなくバンドル内の PNG なので、ファイル名 (拡張子込み) で
        // URL を引いて読み込む。コレクション間でファイル名が重なっても取り違えないよう、
        // まず自分のフォルダの中を探し、見つからなければバンドル直下を探す。
        let url = Bundle.main.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "\(resourceName).files"
        ) ?? Bundle.main.url(forResource: name, withExtension: nil)

        guard let url else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
