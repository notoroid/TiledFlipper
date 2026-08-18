//
//  ArtworkPackageCatalog.swift
//  TiledFlipperServerCore
//

import Foundation

/// 配っているアートワークコレクション 1 つの在り処。
///
/// アプリ側の `NetworkArtworkDescription` と同じ形。実体 (zip) は別の場所に
/// 置いてあり、サーバーは「どこに何があるか」だけを持つ。
public struct ArtworkPackageDescription: Sendable, Hashable, Codable {
    /// zip の配布先。
    public var url: URL
    /// 選択画面に出す表示名。
    public var name: String
    /// 中身の版。上がったらクライアントが落とし直す。
    public var revision: Int
    /// コレクションを一意に指す文字列。クライアントの展開先ディレクトリ名にもなるので、
    /// 同じ中身なら常に同じ値であること。
    public var uniqueIdentifier: String
    /// zip を展開したルートから見た、アートワーク一覧 JSON の相対パス。
    public var artworkListFile: String

    public init(
        url: URL,
        name: String,
        revision: Int,
        uniqueIdentifier: String,
        artworkListFile: String
    ) {
        self.url = url
        self.name = name
        self.revision = revision
        self.uniqueIdentifier = uniqueIdentifier
        self.artworkListFile = artworkListFile
    }
}

/// 配っているコレクションの一覧。`GetDescriptions` が返す中身そのもの。
///
/// 配布先の URL はリポジトリに置かない (アプリ側の `ArtworkPackageEndpoint.local.txt` と
/// 同じ扱い) ので、一覧は git 管理外の JSON から読む。書き方は
/// `ArtworkPackages.example.json` を参照。ファイルが無ければ空の一覧として扱い、
/// クライアントは同梱ぶんだけで動く。
public struct ArtworkPackageCatalog: Sendable {

    /// 何も配らないときの一覧。
    public static let empty = ArtworkPackageCatalog(descriptions: [])

    /// 指定が無いときに読みに行く JSON。カレントディレクトリからの相対。
    public static let defaultFileName = "ArtworkPackages.local.json"

    public var descriptions: [ArtworkPackageDescription]

    public init(descriptions: [ArtworkPackageDescription]) {
        self.descriptions = descriptions
    }

    /// JSON ファイルから一覧を読む。
    ///
    /// 中身が壊れていれば投げる。起動時に読んで落としてしまい、
    /// RPC を受けてから気付くことがないようにする。
    public static func load(contentsOf file: URL) throws -> ArtworkPackageCatalog {
        struct Contents: Decodable {
            let descriptions: [ArtworkPackageDescription]
        }

        let decoder = JSONDecoder()
        // JSON のキーは openapi.yaml / proto と同じ snake_case で書く。
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let data = try Data(contentsOf: file)
        return ArtworkPackageCatalog(descriptions: try decoder.decode(Contents.self, from: data).descriptions)
    }

    /// ファイルがあれば読み、無ければ空の一覧を返す。
    ///
    /// 配布先を用意していない手元でも、そのまま起動できるようにするため。
    public static func loadIfExists(contentsOf file: URL) throws -> ArtworkPackageCatalog {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .empty
        }
        return try load(contentsOf: file)
    }
}
