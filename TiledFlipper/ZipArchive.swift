//
//  ZipArchive.swift
//  TiledFlipper
//

import Compression
import Foundation

/// zip の中身をディレクトリに書き出す、読み出し専用の展開処理。
///
/// システムには zip を展開する公開 API がない (AppleArchive が扱うのは `.aar`)。
/// アートワークのパッケージを開けるだけでよいので、必要な範囲だけを自前で読む。
/// 対応するのは無圧縮 (stored) と deflate の 2 つで、zip64 と暗号化は扱わない。
enum ZipArchive {
    enum ExtractionError: Error {
        /// zip として読めなかった
        case malformedArchive
        /// stored / deflate 以外で圧縮されていた
        case unsupportedCompression(entry: String)
        /// 展開後の大きさが記録と合わなかった
        case corruptedEntry(entry: String)
        /// 4GB 超などで zip64 が必要
        case unsupportedZip64
        /// 展開先の外に出ようとするパスだった
        case unsafeEntryPath(String)
    }

    /// `archive` の中身を `directory` の下に展開する。
    ///
    /// zip の中のディレクトリ構成はそのまま再現する。macOS が付けるメタデータ
    /// (`__MACOSX`, `.DS_Store`, `._` 始まり) は取り込まない。
    static func extract(_ archive: Data, to directory: URL) throws {
        let bytes = [UInt8](archive)

        guard let endRecord = endOfCentralDirectoryOffset(in: bytes) else {
            throw ExtractionError.malformedArchive
        }

        let entryCount = try uint16(bytes, at: endRecord + 10)
        let centralDirectoryOffset = try uint32(bytes, at: endRecord + 16)
        guard entryCount != 0xFFFF, centralDirectoryOffset != 0xFFFF_FFFF else {
            throw ExtractionError.unsupportedZip64
        }

        let fileManager = FileManager.default
        var offset = centralDirectoryOffset

        for _ in 0..<entryCount {
            guard try uint32(bytes, at: offset) == centralFileHeaderSignature else {
                throw ExtractionError.malformedArchive
            }

            let compressionMethod = try uint16(bytes, at: offset + 10)
            let compressedSize = try uint32(bytes, at: offset + 20)
            let uncompressedSize = try uint32(bytes, at: offset + 24)
            let nameLength = try uint16(bytes, at: offset + 28)
            let extraLength = try uint16(bytes, at: offset + 30)
            let commentLength = try uint16(bytes, at: offset + 32)
            let localHeaderOffset = try uint32(bytes, at: offset + 42)
            let name = try string(bytes, at: offset + 46, length: nameLength)

            // 次のエントリへ。ここから下で continue しても読み進められるよう先に進めておく。
            offset += 46 + nameLength + extraLength + commentLength

            guard compressedSize != 0xFFFF_FFFF,
                  uncompressedSize != 0xFFFF_FFFF,
                  localHeaderOffset != 0xFFFF_FFFF
            else {
                throw ExtractionError.unsupportedZip64
            }

            if isMetadata(name) { continue }

            let destination = try destination(for: name, in: directory)
            // ディレクトリのエントリは名前が "/" で終わる
            if name.hasSuffix("/") {
                try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }

            // 中身の位置はローカルヘッダを読まないと分からない。名前と拡張フィールドの
            // 長さは中央ディレクトリ側と一致しないことがあるので、こちらの値を使う。
            guard try uint32(bytes, at: localHeaderOffset) == localFileHeaderSignature else {
                throw ExtractionError.malformedArchive
            }
            let localNameLength = try uint16(bytes, at: localHeaderOffset + 26)
            let localExtraLength = try uint16(bytes, at: localHeaderOffset + 28)
            let dataOffset = localHeaderOffset + 30 + localNameLength + localExtraLength
            let payload = try slice(bytes, at: dataOffset, length: compressedSize)

            let contents: Data
            switch compressionMethod {
            case 0:
                contents = payload
            case 8:
                contents = try inflate(payload, uncompressedSize: uncompressedSize, entry: name)
            default:
                throw ExtractionError.unsupportedCompression(entry: name)
            }

            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: destination)
        }
    }

    private static let centralFileHeaderSignature = 0x0201_4b50
    private static let localFileHeaderSignature = 0x0403_4b50

    /// 終端レコード (End of Central Directory) の位置。
    ///
    /// 末尾にコメントが付くことがあるので、後ろから署名を探す。
    private static func endOfCentralDirectoryOffset(in bytes: [UInt8]) -> Int? {
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        let recordLength = 22
        guard bytes.count >= recordLength else { return nil }

        // コメントは最大 65535 バイトなので、そこまで遡れば必ず見つかる
        let lowerBound = max(0, bytes.count - recordLength - 65_535)
        var offset = bytes.count - recordLength
        while offset >= lowerBound {
            if Array(bytes[offset..<(offset + 4)]) == signature { return offset }
            offset -= 1
        }
        return nil
    }

    /// deflate を展開する。展開後の大きさは zip に記録されているので、
    /// 一度に収まるバッファを取って一括で戻す。
    private static func inflate(_ payload: Data, uncompressedSize: Int, entry: String) throws -> Data {
        guard uncompressedSize > 0 else { return Data() }

        var decoded = Data(count: uncompressedSize)
        let written = decoded.withUnsafeMutableBytes { destination -> Int in
            payload.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return 0
                }
                // COMPRESSION_ZLIB は zlib ヘッダなしの raw deflate。zip の中身はこれで読める。
                return compression_decode_buffer(
                    destinationBase,
                    uncompressedSize,
                    sourceBase,
                    payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written == uncompressedSize else {
            throw ExtractionError.corruptedEntry(entry: entry)
        }
        return decoded
    }

    /// zip の中の名前から書き出し先を作る。
    /// 展開先の外を指すもの (絶対パスや `..`) は受け付けない。
    private static func destination(for name: String, in directory: URL) throws -> URL {
        let components = name.split(separator: "/").map(String.init)
        guard !name.hasPrefix("/"),
              !components.isEmpty,
              !components.contains(".."),
              !components.contains(".")
        else {
            throw ExtractionError.unsafeEntryPath(name)
        }

        return components.reduce(directory) { $0.appending(path: $1) }
    }

    /// macOS が zip に混ぜるメタデータかどうか
    private static func isMetadata(_ name: String) -> Bool {
        let components = name.split(separator: "/")
        return components.contains { $0 == "__MACOSX" || $0 == ".DS_Store" || $0.hasPrefix("._") }
    }

    private static func uint16(_ bytes: [UInt8], at offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { throw ExtractionError.malformedArchive }
        return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], at offset: Int) throws -> Int {
        guard offset >= 0, offset + 4 <= bytes.count else { throw ExtractionError.malformedArchive }
        return Int(bytes[offset])
            | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16
            | Int(bytes[offset + 3]) << 24
    }

    private static func string(_ bytes: [UInt8], at offset: Int, length: Int) throws -> String {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else {
            throw ExtractionError.malformedArchive
        }
        return String(decoding: bytes[offset..<(offset + length)], as: UTF8.self)
    }

    private static func slice(_ bytes: [UInt8], at offset: Int, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset + length <= bytes.count else {
            throw ExtractionError.malformedArchive
        }
        return Data(bytes[offset..<(offset + length)])
    }
}
