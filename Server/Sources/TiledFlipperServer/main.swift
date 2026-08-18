//
//  main.swift
//  TiledFlipperServer
//
//  Core を呼び出して起動するだけの薄いエントリーポイント。
//

import ArgumentParser
import Foundation
import TiledFlipperServerCore

struct Serve: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "TiledFlipperServer",
        abstract: "TiledFlipper 用の gRPC テストサーバーを起動する。"
    )

    @Option(help: "待ち受けるホスト。実機から繋ぐときは 0.0.0.0。")
    var host: String = "127.0.0.1"

    @Option(help: "待ち受けるポート。0 を渡すと空いているポートが選ばれる。")
    var port: Int = 31415

    @Option(
        name: .customLong("catalog"),
        help: """
            GetDescriptions で配るコレクションの一覧 (JSON) のパス。\
            省略すると \(ArtworkPackageCatalog.defaultFileName) を探し、\
            無ければ何も配らない。書き方は ArtworkPackages.example.json を参照。
            """,
        completion: .file(extensions: ["json"])
    )
    var catalogPath: String?

    func run() async throws {
        let catalog = try loadCatalog()
        if catalog.descriptions.isEmpty {
            print("配るコレクションはありません (クライアントは同梱ぶんだけで動きます)")
        } else {
            for description in catalog.descriptions {
                print("配布: \(description.name) (revision \(description.revision)) <- \(description.url)")
            }
        }

        fflush(stdout)

        try await TiledFlipperTestServer(host: host, port: port, catalog: catalog).run()
    }

    /// 一覧を読む。
    ///
    /// パスを明かに渡されたときは、無ければ (指定の間違いなので) そこで止める。
    /// 省略されたときは既定のファイルを探すだけなので、無くても空の一覧で起動する。
    private func loadCatalog() throws -> ArtworkPackageCatalog {
        if let catalogPath {
            return try ArtworkPackageCatalog.load(contentsOf: URL(filePath: catalogPath))
        }
        return try ArtworkPackageCatalog.loadIfExists(
            contentsOf: URL(filePath: ArtworkPackageCatalog.defaultFileName)
        )
    }
}

// main.swift には @main を置けず、`Serve.main()` と書くと同期版が選ばれて
// async な run() が呼ばれない。引数の解釈と実行をここで分けて書く。
let command = Serve.parseOrExit()
do {
    try await command.run()
} catch {
    Serve.exit(withError: error)
}
