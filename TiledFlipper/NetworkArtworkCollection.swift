//
//  NetworkArtworkCollection.swift
//  TiledFlipper
//
//  Created by 能登 要 on 2026/08/17.
//

import Foundation
import UIKit

/// 1 つのアートワークコレクションの在り処。
///
/// `GetDescriptions` が返す `NetworkArtworkDescription` と同じ形。
/// 取ってくるのは `TileFlipServcice` の担当。
struct NetworkArtworkDescription: Sendable, Hashable {
    let url: URL
    let name: String
    let revision: Int
    let uniqueIdentifier: String
    let artworkListFile: String
}

/// ネットワーク越しに配られているアートワークのコレクション。
///
/// 実体は zip で配られていて、`fetch()` で temporary ディレクトリに展開してから
/// 一覧の JSON と画像を読む。展開先は `uniqueIdentifier` から決まるので、
/// 読み込み側は展開の面倒 (ダウンロード、展開、後片付け) を知らずに済む。
struct NetworkArtworkCollection: ArtworkCollection {
    let description: NetworkArtworkDescription

    var id: String { description.uniqueIdentifier }
    var displayName: String { description.name }

    /// パッケージを展開したディレクトリ。展開前でも位置は決まる。
    private var packageDirectory: URL {
        ArtworkPackageStore.directory(for: description.uniqueIdentifier)
    }

    func fetch() async throws {
        _ = try await ArtworkPackageStore.shared.package(for: description)
    }

    func loadArtworkNames() -> [String] {
        struct Entry: Decodable {
            let artwork: String
        }

        let listFile = packageDirectory.appending(path: description.artworkListFile)
        guard let data = try? Data(contentsOf: listFile),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            // まだ展開していない (あるいは temporary ごと消された) ときはここに来る。
            // `fetch()` のあとに読み直せば揃う。
            return []
        }

        // artwork はパッケージのルートから見た相対パス。
        // 同じアートワークが複数エントリにあっても 1 件として扱う。
        var seen = Set<String>()
        return entries
            .map(\.artwork)
            .filter { seen.insert($0).inserted }
    }

    func loadImage(named name: String) -> UIImage? {
        // 名前は一覧の JSON に書かれた相対パスなので、展開先に継ぎ足すだけで引ける
        let url = packageDirectory.appending(path: name)
        return UIImage(contentsOfFile: url.path)
    }
}
