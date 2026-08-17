//
//  EmbeddedEndpoints.swift
//  TiledFlipper
//
//  Created by 能登 要 on 2026/08/18.
//

import Foundation

/// ビルド時に埋め込まれた接続先。
///
/// URL の実体はリポジトリではなく、git 管理外の
/// `ArtworkPackageEndpoint.local.txt` (アートワーク zip の配布先) と
/// `TiledFlipperEndpoint.local.txt` (サービスのエンドポイント) に置いてある。
/// ビルドフェイズ "Embed Artwork Package Endpoint" がその 2 つを読んで、
/// アプリバンドルの `ArtworkPackageEndpoint.plist` にまとめて埋め込む。
///
/// ローカルの txt が無いビルドでもビルドは通り、その分が nil になる。
enum EmbeddedEndpoints {

    private static let resourceName = "ArtworkPackageEndpoint"

    /// アートワークパッケージ (zip) の配布先。
    static var artworkPackageURL: URL? {
        url(forKey: "ArtworkPackageURL")
    }

    /// サービスのエンドポイント。
    static var serviceURL: URL? {
        url(forKey: "ServiceEndpointURL")
    }

    /// plist は毎回読み直さず、最初に読んだ内容を使い回す。
    private static let values: [String: Any] = {
        guard let plist = Bundle.main.url(forResource: resourceName, withExtension: "plist"),
              let values = NSDictionary(contentsOf: plist) as? [String: Any]
        else {
            return [:]
        }
        return values
    }()

    private static func url(forKey key: String) -> URL? {
        // 埋め込みを飛ばしたビルドでは値が空文字で入っている。
        guard let string = values[key] as? String, !string.isEmpty else {
            return nil
        }
        return URL(string: string)
    }
}
