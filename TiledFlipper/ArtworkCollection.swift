//
//  ArtworkCollection.swift
//  TiledFlipper
//

import UIKit

/// タイルに表示するアートワークをまとめた、コレクション 1 つ分の定義。
///
/// アートワークの置き場所 (アプリのバンドル、ネットワークなど) ごとに実装を
/// 用意する。カタログや UI 側はどこから読み込むのかを知らず、このプロトコル
/// 越しにだけ触る。
///
/// 実装は複数のタスクから触られるため `Sendable` を求める。
protocol ArtworkCollection: Sendable {
    /// コレクションを一意に表す識別子。切り替えの判定や読み込み済みの
    /// カタログを覚えておくためのキーに使う。
    var id: String { get }
    /// UI に表示する名前。リソース名とは別に持ち、置き場所の名前を変えずに
    /// 呼び名だけを付け替えられるようにする。
    var displayName: String { get }

    /// アートワークの実体を、読み込める場所に用意する。
    ///
    /// ネットワーク越しのコレクションでは、アートワークのパッケージ (zip) を
    /// ダウンロードし、アプリの temporary ディレクトリに展開するところまでを行う。
    /// ダウンロードと展開そのものは actor に閉じ込め、ここからは await して呼び出す。
    ///
    /// `loadArtworkNames()` と `loadImage(named:)` は、このメソッドが正常に
    /// 終わったあとに呼ばれる。すでに用意できているものは取得し直さなくてよい。
    func fetch() async throws

    /// 表示するアートワークのファイル名一覧 (例: "001.png")
    func loadArtworkNames() -> [String]
    /// 名前に対応するアートワーク画像。見つからなければ nil を返す。
    func loadImage(named name: String) -> UIImage?
}
