# ローカルサーバーの起動・終了

TiledFlipperServer をクラウドやコンテナを使わず、開発機のターミナルから
直接動かすための手順。gRPC のテストサーバーで、TiledFlipper アプリが
ネットワーク越しに取りに行くアートワーク配布情報とタイル差し替え指示を
手元で再現する。

## 起動

`Server` ディレクトリで実行する。

```sh
cd Server
swift run TiledFlipperServer
```

初回はビルドに時間がかかる(依存の取得と protoc のビルドが走るため)。
起動に成功すると以下のように出力される。

```
配布: Online artwork (revision 3) <- https://irimasu.sakura.ne.jp/tileflipper/Albumartworks3.zip
TiledFlipperServer listening on [ipv4]127.0.0.1:31415
```

既定では `127.0.0.1:31415` で待ち受ける。シミュレータからはこのままで
繋がるが、実機から繋ぐ場合は `--host 0.0.0.0` を付けて起動する。

```sh
swift run TiledFlipperServer --host 0.0.0.0 --port 31415
```

### オプション

| オプション | 説明 |
| --- | --- |
| `--host` | 待ち受けるホスト。既定は `127.0.0.1`。実機から繋ぐときは `0.0.0.0`。 |
| `--port` | 待ち受けるポート。既定は `31415`。`0` を渡すと空いているポートが選ばれる。 |
| `--catalog` | 配布するコレクション一覧 (JSON) のパス。省略すると `ArtworkPackages.local.json` を探し、無ければ何も配らない。書き方は `ArtworkPackages.example.json` を参照。 |

すべてのオプションは `swift run TiledFlipperServer --help` でも確認できる。

### バックグラウンドで動かす場合

ターミナルを専有したくない場合は末尾に `&` を付けて起動し、ジョブ番号を
控えておく。

```sh
swift run TiledFlipperServer &
```

## 終了

フォアグラウンドで動かしている場合は `Ctrl-C` で止める。

バックグラウンドで動かしている場合はプロセスを探して止める。

```sh
# ポート 31415 を掴んでいるプロセスを探す
lsof -i :31415

# 見つかった PID を止める
kill <PID>
```

`swift run` 経由のジョブ番号を控えている場合は `kill %<ジョブ番号>` でも良い。
