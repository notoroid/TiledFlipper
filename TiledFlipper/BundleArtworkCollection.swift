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

        // artwork は "Albumartworks.files/001.png" のようにフォルダ付きで書かれている。
        // フォルダ違いで同じファイル名のものを取り違えないよう、パスのまま名前に使う。
        // 同じアートワークが複数エントリにあっても 1 件として扱う。
        var seen = Set<String>()
        return entries
            .map(\.artwork)
            .filter { seen.insert($0).inserted }
    }

    func loadImage(named name: String) -> UIImage? {
        // 画像はアセットカタログではなくバンドル内の PNG なので、ファイル名 (拡張子込み) で
        // URL を引いて読み込む。
        //
        // JSON のフォルダがそのままバンドル内の位置になるとは限らない。グループとして
        // 追加した画像はバンドル直下に平たく置かれるため。そこで
        // JSON のフォルダ → コレクションのフォルダ → バンドル直下 の順に探す。
        let components = name.split(separator: "/")
        let fileName = String(components.last ?? "")
        let directory = components.dropLast().joined(separator: "/")

        let url = (directory.isEmpty ? nil : Bundle.main.url(
            forResource: fileName,
            withExtension: nil,
            subdirectory: directory
        )) ?? Bundle.main.url(
            forResource: fileName,
            withExtension: nil,
            subdirectory: "\(resourceName).files"
        ) ?? Bundle.main.url(forResource: fileName, withExtension: nil)

        guard let url else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
