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

## なぜ arm64 でビルドしているか (ローカル検証と Cloud Run 用ビルドの違い)

このドキュメントで扱っている `container build` (アーキテクチャ指定なし、
Apple Silicon 上では既定で arm64) は、**手元の Mac で
TiledFlipperServer を動かし、iOS Simulator / 実機から接続できることを
確かめるためのローカル動作検証**が目的。「macOS の Container Machine で
ローカルテストサーバーを動かす」という、そもそもの目標そのものにあたる。

これとは別に、[CloudRunDeployment.md](./CloudRunDeployment.md) で扱っている
`linux/amd64` 向けのビルドは目的が異なる。Google Cloud Run が
`linux/amd64` のイメージしか受け付けないため、Cloud Run にデプロイする
イメージを用意する目的だけで行ったもの。`container build --arch amd64`
でこの Mac 上からクロスビルドしようとしたところ Rosetta がクラッシュする
問題に当たり (「7. `swift build` が `protoc-tool` のリンク直後に
セグフォルトすることがある」の前段にあたる話)、amd64 向けはローカルでの
クロスビルドを諦めて Google Cloud Build (GCP 側のネイティブ環境) に
切り替えている。**つまり amd64 のビルドは現在ローカルの `container`
コマンドを一切経由しておらず、ここで書いているハマりどころとは別系統。**

ローカル (arm64) での「ビルドできるか」と「動かして繋がるか」は次のように
切り分けている:

- **接続検証**: Containerfile に `COPY Package.swift Package.resolved ./`
  ([2 番目の変更](#containerfile-の書き換えの流れ)) までの版では、ローカル
  arm64 ビルド → `container run` → `container inspect` で得た IP に
  `curl`/iOS Simulator から接続、という一連の流れは成功していた。
- **最新版の再検証**: `COPY ArtworkPackages.local.json ./`
  ([3 番目の変更](#containerfile-の書き換えの流れ)) を加えた現在の版では、
  ローカル arm64 ビルドがビルダー VM のリソースリセット・runc の
  デッドロック・SwiftPM のセグフォルトと、毎回違う理由で完走せず、
  接続検証まで到達できていない (2026-08-23 時点)。一方この版は
  Google Cloud Build 経由でのビルドと Cloud Run へのデプロイ・疎通は
  成功している。つまり「接続の仕組み」自体は疑わしくなく、疑わしいのは
  「最新の Containerfile を Apple Container (arm64 ネイティブ) で
  ビルドし切れるか」という一点に絞られている。

## Containerfile の書き換えの流れ

[Containerfile](../Containerfile) は環境ごとに複数のファイルを用意して
いるわけではなく、1 本のファイルを目的に合わせて 3 段階で書き換えてきた。
ローカル検証にも Cloud Run 向けビルドにも常に同じファイルを使っている
(それが OCI 標準の Containerfile を使う狙いでもある)。

1. `1d566e8` (2026-08-20) — 新規作成。`swift:6.3` でビルドし
   `swift:6.3-slim` で実行するマルチステージ構成。ローカルの Apple
   Container で動かすことだけを目的にしていた。
2. `24548ff` (2026-08-22) — Cloud Build 対応。
   `COPY Package.swift Package.resolved .` を `./` に変更。buildkit
   (ローカルの Apple Container) では省略した書き方でも通っていたが、
   Cloud Build 上の従来の docker ビルダーは「複数ファイルを COPY する
   ときは宛先の末尾に `/` が要る」という点により厳密で、そのままでは
   ビルドが落ちていた。
3. `a5b4333` (2026-08-22) — Cloud Run 対応。`COPY ArtworkPackages.local.json
   ./` を追加。Cloud Run にはローカルファイルを実行時にマウントする
   仕組みが無く、ローカルの Apple Container で使っていた
   `container run -v ... --catalog ...` 方式が使えないため、ビルド時点で
   イメージへ焼き込む形に変えた (中身は配布 URL と版数だけで機微情報は
   無いので焼き込んでも問題ないと判断した)。

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

### 7. `swift build` が `protoc-tool` のリンク直後にセグフォルトすることがある

「2. ネストされた runc がまれにデッドロックする」の続報。ビルダー VM の
CPU/メモリを 2 CPU/2GB → 4 CPU/6GB → 4 CPU/8GB と増やして何度か試したが、
リソースを増やしても直らず、むしろ今回はクラッシュの中身まで捕まった。

`grpc-swift-protobuf` が内部で使う `protoc-tool` のリンクが終わった
直後 (`[298/299] Linking protoc-tool`) に、`swift-package` 自身が
Signal 11 (セグメンテーション違反) で毎回ほぼ同じ場所 (経過 88〜95 秒
あたり) で落ちる:

```
#10 88.34 [298/299] Linking protoc-tool
#10 88.36
#10 88.36 *** Signal 11: Backtracing from 0xffff9d2551b4... done ***
#10 94.94
#10 94.94 *** Program crashed: Bad pointer dereference at 0xfffffffffffffff0 ***
#10 94.94
#10 94.94 Platform: arm64 Linux (Ubuntu 24.04.4 LTS)
#10 94.94
#10 94.94 Thread 0 crashed:
#10 94.94
#10 94.94   0                         0x0000ffff9d2551b4 _swift_release_dealloc + 36 in libswiftCore.so
#10 94.94   1 [ra]                    ... doDecrementSlow<(swift::PerformDeinit)1> ...
#10 94.94   2 [ra] [system]           ... destroy for WriteAuxiliaryFile ... in swift-package
#10 94.94   ...
#10 94.94  11 [ra] [system]           ... LLBuildProgressTracker.deinit ... in swift-package
```

クラッシュ箇所は `LLBuildProgressTracker` や `BuildExecutionContext` の
`deinit` (後片付けの参照カウント解放) の中で、実際のコンパイル作業が
終わった後の掃除処理で起きている。メモリを増やしても再現したことから、
リソース不足ではなく `swift:6.3` の Linux arm64 ツールチェーンと
Apple Container の仮想化層の組み合わせにおける再現性の高いバグと見られる。
クラッシュ後は buildkit がプロセスの終了を検知できず、「2.」と同じ
ハングした状態になる。

**解決策: `swift:6.2` に切り替えたら再発しなくなった。** `swift:6.2` /
`swift:6.2-slim` で同じ Containerfile ・同じ Sources を何度もビルドしたが、
一度もセグフォルトしていない。しかも `swift:6.3` では 4 CPU/6GB や
8GB でも落ちていたのに対し、`swift:6.2` では **ビルダー VM を
`container builder start` の既定値そのもの (2 CPU/2GB) まで絞っても**
問題なく完走し、コンテナの起動・疎通確認まで通ることを確認した
(`Linking protoc-tool` を安定して通過する)。「1.」で書いた
「初回は 2GB だと実質メモリ不足になる」という話は `swift:6.3` +
grpc-swift-protobuf の組み合わせ特有の話であり、`swift:6.2` では
そもそも問題にならない。これは「メモリ不足」ではなく「`swift:6.3` の
Linux arm64 ツールチェーン自体の不具合」だったことをさらに裏付けている。

このリポジトリでは [Containerfile](../Containerfile) に
`ARG SWIFT_VERSION` (既定 6.3) を用意し、
[Server/Tools/run-in-container.sh](../Tools/run-in-container.sh) が
ローカルビルド時だけ `--build-arg SWIFT_VERSION=6.2` を渡すようにして
この問題を回避している。Google Cloud Build (`cloudbuild.yaml`) 側は
x86_64 ネイティブ環境で `swift:6.3` のまま問題なく動いているので、
そちらは変更していない (1 本の Containerfile を両環境で使い分けている)。

手で `container build` する場合も同様に指定できる:

```
container build --build-arg SWIFT_VERSION=6.2 -t tiledflipper-server -f Server/Containerfile Server
```

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
