//
//  ArtworkPackageStore.swift
//  TiledFlipper
//

import Foundation

/// ネットワークで配られているアートワークのパッケージを、
/// temporary ディレクトリに展開して置いておく係。
///
/// ダウンロードと展開は同じコレクションについて 1 度だけ走ればよいので、
/// 進行中の作業を覚えておける actor にまとめている。展開先は
/// `uniqueIdentifier` ごとのサブディレクトリで、コレクション間で混ざらない。
actor ArtworkPackageStore {
    static let shared = ArtworkPackageStore()

    enum PackageError: Error {
        /// サーバーがパッケージを返さなかった
        case downloadFailed(statusCode: Int)
    }

    /// パッケージの置き場。temporary なので、OS に消されたら次に取り直す。
    nonisolated static var containerDirectory: URL {
        URL.temporaryDirectory.appending(path: "ArtworkPackages", directoryHint: .isDirectory)
    }

    /// 展開先のディレクトリ。展開前でも位置は決まるので、
    /// 画像の読み込み側はこの計算だけで参照を解決できる。
    nonisolated static func directory(for uniqueIdentifier: String) -> URL {
        containerDirectory.appending(path: uniqueIdentifier, directoryHint: .isDirectory)
    }

    /// 進行中のダウンロード。同じコレクションを二重に取りに行かない。
    private var inFlight: [String: Task<URL, any Error>] = [:]

    /// パッケージを展開し終えたディレクトリを返す。
    /// すでに同じ revision で展開済みなら、そのまま返す。
    func package(for description: NetworkArtworkDescription) async throws -> URL {
        if let task = inFlight[description.uniqueIdentifier] {
            return try await task.value
        }

        // 呼び出し側がキャンセルされても展開は最後までやり切る。
        // 途中で止めると、中途半端に展開されたディレクトリが残ってしまうため。
        let task = Task { try await Self.prepare(description) }
        inFlight[description.uniqueIdentifier] = task
        defer { inFlight[description.uniqueIdentifier] = nil }

        return try await task.value
    }

    private static func prepare(_ description: NetworkArtworkDescription) async throws -> URL {
        let fileManager = FileManager.default
        let directory = directory(for: description.uniqueIdentifier)

        if isPrepared(directory, revision: description.revision) {
            return directory
        }

        // 前の revision や、途中で失敗した残骸を片付けてから展開する
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let archive = try await download(description)
        // 展開が済んだら圧縮ファイルは要らない。失敗したときも残さない。
        defer { try? fileManager.removeItem(at: archive) }

        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        try ZipArchive.extract(data, to: directory)
        try flattenSingleRootDirectory(at: directory)

        // 展開し切ったことの目印。次からはこれを見て取り直しの要否を決める。
        try Data(String(description.revision).utf8).write(to: revisionMarker(in: directory))
        return directory
    }

    /// 圧縮ファイルを自分の一時領域に落とす。
    private static func download(_ description: NetworkArtworkDescription) async throws -> URL {
        let (temporaryFile, response) = try await URLSession.shared.download(from: description.url)

        // 404 のときも本文 (エラーページ) は返ってくるので、状態コードで弾く
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            try? FileManager.default.removeItem(at: temporaryFile)
            throw PackageError.downloadFailed(statusCode: response.statusCode)
        }

        // URLSession が置いた一時ファイルはこの関数を抜けると消えるので、自分の置き場へ移す
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: containerDirectory, withIntermediateDirectories: true)
        let destination = containerDirectory.appending(path: "\(description.uniqueIdentifier).zip")
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporaryFile, to: destination)
        return destination
    }

    /// 展開済みで、かつ同じ revision かどうか
    private static func isPrepared(_ directory: URL, revision: Int) -> Bool {
        guard let marker = try? String(contentsOf: revisionMarker(in: directory), encoding: .utf8) else {
            return false
        }
        return marker == String(revision)
    }

    private static func revisionMarker(in directory: URL) -> URL {
        directory.appending(path: ".revision")
    }

    /// 中身が 1 つのフォルダに包まれている zip では、その中身を 1 段持ち上げる。
    ///
    /// パッケージのルートからの相対パスで画像を引けるようにするため。
    /// 包み方は zip の作り方次第で変わるので、読み込み側に持ち込まない。
    private static func flattenSingleRootDirectory(at directory: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey]
        )
        guard contents.count == 1,
              let root = contents.first,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            return
        }

        for item in try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            try fileManager.moveItem(at: item, to: directory.appending(path: item.lastPathComponent))
        }
        try fileManager.removeItem(at: root)
    }
}
