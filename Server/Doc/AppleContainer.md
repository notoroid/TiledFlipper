# Apple Container (`container` CLI) でのテストサーバー運用

macOS 26 以降に載っている `container` CLI (Apple Container / Container Machine) の上で
TiledFlipperServer をビルド・起動できるようにした際に分かったことをまとめる。
関連: [WWDC26 #389 コンテナマシンの詳細](https://developer.apple.com/jp/videos/play/wwdc2026/389)、
[WWDC26 #265 gRPCとSwiftによるリアルタイムのアプリやサービスの構築](https://developer.apple.com/jp/videos/play/wwdc2026/265)。

## 使い方

```
Server/Tools/run-in-container.sh
```

これでイメージのビルド、既存コンテナの片付け、起動、コンテナ IP の取得、
`TiledFlipperEndpoint.local.txt` の書き換えまで一通り行う。Xcode 側は
その後ビルドし直せば新しい IP に繋がる。

手で行う場合は [Containerfile](../Containerfile) の先頭コメントにビルド/実行コマンドを書いてある。

## ハマった点

### 1. ビルド用 VM (`buildkit`) のリソースは初回作成時に固定される

`container build -c <cpus> -m <memory>` は、ビルダー (`buildkit` という名前の
永続コンテナ) がまだ無いときだけ効く。一度作られると、以後 `build` に
`-c`/`-m` を付けてもそのビルダーは作り直されず、既定値
(2 CPU / 2048MB) のまま使われ続ける。

grpc-swift-protobuf は初回ビルドで protoc 一式を C++ からビルドするため、
2GB では実質メモリ不足になり、ビルドが極端に遅くなる (数時間かけても終わらない)
か `exit code 133` で落ちる。

対処:

```
container builder delete --force
container builder start -c 4 -m 6144M
```

CPU/メモリの数値はホストの空き具合に合わせる (このマシンは 16GB/10コアで、
他のアプリが動いている前提で 4 CPU / 6GB にした)。`container inspect buildkit`
で実際に反映されているか確認できる。

### 2. ネストされた runc がまれにデッドロックする

`container build` → 内部の Linux VM 上の `buildkitd` → その中でさらに
`runc` が RUN ステップごとにコンテナを作る、という三重構造になっている。
作業中に一度、`RUN swift build ...` のステップが `{runc:[2:INIT]}` の
まま何十分も進まなくなり、CPU 使用率もほぼ 0% に落ちる現象が起きた。

`container exec buildkit sh -c "ps aux"` で見ると、`swift`/`clang` の
プロセスが一つも無く、runc の init だけが残っていた。ビルドをキャンセル
しても `kill` コマンド自体がスタックしたコンテナを殺せずループする。

こうなったら個別の復旧は諦めて、システムごと作り直すのが早い:

```
container system stop
container system start
container builder delete --force
container builder start -c 4 -m 6144M
```

`container system stop` のログに `some containers could not be stopped
gracefully` と出ても、そのまま強制終了されるので問題ない。

再発する場合は早期の macOS 27 ベータ機能なので、しばらく待ってから
リトライするか、Feedback Assistant で報告するのが良さそう。

### 3. `-v` (ボリュームマウント) はディレクトリ単位のみ

単一ファイルを直接マウントしようとすると失敗する:

```
container run -v "$(pwd)/Server/ArtworkPackages.local.json:/app/ArtworkPackages.local.json:ro" ...
# => Error Domain=VZErrorDomain Code=2 "A directory sharing device configuration is invalid."
#    (NSPOSIXErrorDomain Code=20 "Not a directory")
```

Docker (bind mount) と違い、virtiofs 越しの共有はディレクトリでないと
張れない。`Server/` ごとマウントして、コンテナ内のパスをオプションで
指す形にした:

```
container run -v "$(pwd)/Server:/data:ro" tiledflipper-server \
  --host 0.0.0.0 --port 8080 --catalog /data/ArtworkPackages.local.json
```

### 4. コンテナは Docker の `-p` に相当するものを持たない

`container run` に `-p`/`--publish` オプションは無い。代わりに、コンテナが
起動すると独自の IP アドレス (vmnet の DHCP で割り当てられる、例:
`192.168.65.5`) を持ち、ホストからそのアドレスに直接繋げる。

```
container inspect tiledflipper-server
# => networks[0].address が "192.168.65.5/24" のように入っている
```

コンテナを作り直すたびに IP が変わりうるので、`run-in-container.sh` は
毎回 `container inspect` で取り直して `TiledFlipperEndpoint.local.txt` を
上書きするようにしてある。

なお iOS Simulator は Mac 本体とネットワークスタックを共有しているので、
このアドレスにそのまま繋がる。実機 (Wi-Fi 経由) からこの `192.168.65.0/24`
に届くかどうかは未検証。

### 5. `swift:6.4` の公式イメージは (まだ) 無い

Xcode 付属のローカルツールチェーンは `Apple Swift version 6.4` だが、
Docker Hub の公式 `swift` イメージはこの時点で `6.3.3` が最新。
`Package.swift` の `swift-tools-version` は `6.1` を要求しているだけなので、
`swift:6.3` / `swift:6.3-slim` を使えば問題ない。

### 6. `fflush(stdout)` が Linux では並行処理チェックに落ちる

macOS (Darwin) のツールチェーンでは通っていたが、Linux (Glibc) 上の
Swift 6 コンパイラでは次のエラーになった:

```
error: reference to var 'stdout' is not concurrency-safe because it involves shared mutable state
```

Glibc の `stdout` グローバル変数が Darwin 側のような `Sendable` 相当の
注釈を持っていないのが原因と見られる。`stdout` を直接参照せず、
全ストリームを flush する `fflush(nil)` に置き換えて解消した
([TiledFlipperTestServer.swift](../Sources/TiledFlipperServerCore/TiledFlipperTestServer.swift)、
[main.swift](../Sources/TiledFlipperServer/main.swift))。

## 参考: よく使うコマンド

```
container system start / stop          # apiserver の起動・停止
container builder start -c 4 -m 6144M  # ビルド用 VM を明示的なリソースで作成
container builder delete --force       # ビルド用 VM を削除 (詰まったときの復旧に)
container list -a                      # 全コンテナの状態と IP
container logs <name>                  # コンテナの標準出力
container logs buildkit                # buildkitd 自体のデバッグログ (ビルドが進んでいるか怪しいとき)
container exec buildkit sh -c "ps aux" # ビルド VM の中で実際に何が動いているか
container inspect <name>               # IP やリソース割り当てを JSON で確認
```

## 将来のクラウド移行に向けて

[Containerfile](../Containerfile) は OCI 標準のマルチステージビルドなので、
Google Cloud Run / AWS ECS Fargate など、コンテナを受け付けるサービスに
そのまま持っていける。

- **Google Cloud Run**: `gcloud run deploy --use-http2` で gRPC をそのまま公開できる。
  セットアップが単純で、WWDC26 #265 のデモも同じ構成 (grpc-swift + Cloud Run) を
  使っている。リクエストタイムアウトの上限 (最大60分) があるので、`TileFlipFeed`
  のように接続を張りっぱなしにするストリーミング RPC を本番でも使うなら注意。
- **AWS (ECS Fargate + ALB)**: ALB は gRPC (HTTP/2) に対応しているが、
  VPC・ALB・ターゲットグループ・ECS サービス定義が必要でセットアップの手間が大きい。
  Cloud Run のような総時間の上限が無いので、長時間ストリーミングには強い。

今の時点ではどちらか確定させる必要はなく、実際にデプロイする段階で選べば良い。
