//
//  ArtworkCatalog.swift
//  TiledFlipper
//

import SwiftUI
import UIKit

/// Starbucks.json の artwork 属性から集めた、タイルに表示する画像の一覧。
///
/// Canvas は毎フレーム全タイルを描き直すため、JSON の解析と `Image` の生成は
/// 起動時に 1 度だけ行い、以降は名前で引くだけにしている。
/// 画像は 64x64 と小さく、点数も 100 件程度なので全件を持っておいて問題ない。
enum ArtworkCatalog {
    /// artwork のファイル名一覧 (例: "001.png")
    static let names: [String] = loadNames()

    private static let images: [String: Image] = Dictionary(
        uniqueKeysWithValues: names.compactMap { name in
            // 画像はアセットカタログではなくバンドル直下の PNG なので、
            // ファイル名 (拡張子込み) で URL を引いて読み込む
            guard let url = Bundle.main.url(forResource: name, withExtension: nil),
                  let uiImage = UIImage(contentsOfFile: url.path)
            else {
                return nil
            }
            // タイルは元画像より大きく表示されるので、補間を指定して粗さを抑える
            return (name, Image(uiImage: uiImage).interpolation(.medium))
        }
    )

    static func image(named name: String) -> Image? {
        images[name]
    }

    /// ランダムなアートワークを 1 つ返す。
    /// 差し替わったことが分かるよう、指定したものは候補から外す。
    static func randomName(excluding excluded: String?) -> String? {
        let candidates = names.filter { $0 != excluded }
        return candidates.randomElement() ?? names.randomElement()
    }

    private static func loadNames() -> [String] {
        struct Entry: Decodable {
            let artwork: String
        }

        guard let url = Bundle.main.url(forResource: "Albumartworks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else {
            return []
        }

        // 同じアートワークが複数エントリにあっても 1 件として扱う
        var seen = Set<String>()
        return entries.map(\.artwork).filter { seen.insert($0).inserted }
    }
}
