# Google Cloud Run への実際のデプロイ手順と、そこでハマった点

TiledFlipperServer を試験的に Google Cloud Run で動かすまでに、実際に
成功した手順と、途中で失敗した事例をまとめる。手順中のプロジェクト ID・
サービス URL などは公開時に問題が無いよう `<PROJECT_ID>` のような
プレースホルダに置き換えてある。GCP と AWS のどちらを選ぶかの検討は
[CloudDeployment.md](./CloudDeployment.md) を、Apple Container 自体の
知見は [AppleContainer.md](./AppleContainer.md) を参照。

## 前提

- Google Cloud プロジェクト (Firebase で使っているプロジェクトの流用で可。
  Firebase プロジェクトはそのまま GCP プロジェクトなので新規作成は不要)
- そのプロジェクトへの課金の有効化 (請求先アカウントのリンク)
- `gcloud` CLI (インストール済みであること)

## 実際に成功した手順

### 1. ログインとプロジェクト設定

```bash
gcloud init                                  # ブラウザでログイン
gcloud config set project <PROJECT_ID>
```

### 2. 課金の有効化

```bash
gcloud billing accounts list
gcloud billing projects link <PROJECT_ID> --billing-account=<BILLING_ACCOUNT_ID>
```

### 3. 必要な API を有効化

```bash
gcloud services enable run.googleapis.com artifactregistry.googleapis.com cloudbuild.googleapis.com
```

### 4. Artifact Registry に Docker リポジトリを作成

```bash
gcloud artifacts repositories create tiledflipper \
  --repository-format=docker --location=us-central1
```

### 5. イメージのビルドと push は Google Cloud Build に任せる

[Server/cloudbuild.yaml](../cloudbuild.yaml) を使う:

```bash
gcloud builds submit Server --config Server/cloudbuild.yaml \
  --substitutions=_IMAGE=us-central1-docker.pkg.dev/<PROJECT_ID>/tiledflipper/tiledflipper-server:latest
```

### 6. Cloud Run へデプロイ

```bash
gcloud run deploy tiledflipper-server \
  --image us-central1-docker.pkg.dev/<PROJECT_ID>/tiledflipper/tiledflipper-server:latest \
  --region us-central1 \
  --use-http2 \
  --allow-unauthenticated \
  --port 8080 \
  --max-instances 2
```

成功すると `https://<サービス名>-<ハッシュ>.<region>.run.app` の形の URL が
発行される。これを `TiledFlipperEndpoint.local.txt` に書けば、実機・
シミュレーターどちらも Wi-Fi 不要でこのサーバーに繋がる。

### 7. 疎通確認

gRPC 以外のリクエスト (素の GET) を投げると `415 Unsupported Media Type`
が返るのが正常。これはローカルの Apple Container 環境で確認したときと
同じ応答で、gRPC サーバーとして正しく動いている証拠になる。

## 途中で失敗した事例

### 失敗 1: ローカル (Apple Silicon) で amd64 イメージをビルドしようとして Rosetta がクラッシュ

Cloud Run は `linux/amd64` のイメージしか受け付けない。手元の Mac は
Apple Silicon なので、`container build --arch amd64` で x86_64 向けに
クロスビルドしようとしたところ、Swift のコンパイルの途中で次のエラーで
毎回失敗した:

```
rosetta error: rt_tgsigqueueinfo failed in runtime_signal_handler: 22
rosetta error: could not find free space for allocation size 2000
```

途中経過としては、ビルドがそのまま何十分も止まって見える (CPU 使用率が
ほぼ 0% のまま進まない) 状態にもなった。これは Rosetta 上で Swift の
ような重いコンパイラを x86_64 エミュレーションで動かすとクラッシュする
問題で、[AppleContainer.md](./AppleContainer.md) に書いたネストされた
runc のデッドロックと合わせて、同じ根っこ (Rosetta のクラッシュを
buildkit 側がうまく検知できず、ハングして見える) だった可能性がある。

**対策**: ローカルでのクロスビルドは諦め、Google Cloud Build
(GCP 側のネイティブ x86_64 マシン) でビルドする方式に切り替えた。
これなら Rosetta を一切経由しない。

### 失敗 2: ビルド成果物を丸ごとアップロードしてしまった

`gcloud builds submit Server ...` を初めて実行したとき、次のように
3GB 超のファイルをアップロードしようとした:

```
Creating temporary archive of 63440 file(s) totalling 3.1 GiB before compression.
```

原因は `Server/.build` (ローカルの SwiftPM ビルドキャッシュ) がそのまま
含まれていたこと。Apple Container 用に `.containerignore` は用意して
いたが、`gcloud` はそれを見ず、`.gcloudignore` (無ければ `.gitignore`)
しか見ない。ディレクトリ (`Server/`) 単位でこのファイルが必要になる。

**対策**: [Server/.gcloudignore](../.gcloudignore) を追加し、`.build/` や
ローカル専用ファイル (`*.local.json` など) を除外した。これでアップロード
サイズは 3GB から 数十 KB まで落ちた。

### 失敗 3: macOS 上のビルドツールと Cloud Build 上の docker で Dockerfile の解釈が違った

ローカルの Apple Container (buildkit ベース) では次の `COPY` が問題なく
通っていたが、

```dockerfile
COPY Package.swift Package.resolved .
```

Cloud Build 上 (`gcr.io/cloud-builders/docker` イメージ、レガシーな
docker ビルダー) では次のエラーで落ちた:

```
When using COPY with more than one source file, the destination must be a directory and end with a /
```

buildkit は複数ファイルを指定した `COPY` の宛先が `.` でも黙って
ディレクトリとして扱ってくれるが、従来の docker ビルダーはより厳密で、
宛先の末尾に `/` が無いとエラーにする。

**対策**: [Containerfile](../Containerfile) の該当行を
`COPY Package.swift Package.resolved ./` に変更した (`/` を付けるだけで
両方のビルド環境で通る)。

## 教訓

- **ローカルのビルド環境 (Apple Container) と、実際にクラウド側で使う
  ビルド環境 (Cloud Build / 標準 docker) は完全には同じではない。**
  ローカルで通ったからといって Cloud Build でも通るとは限らないので、
  初回は必ずクラウド側でも一度ビルドを通して確認する。
- **Apple Silicon から amd64 イメージを作る必要があるなら、ローカルでの
  クロスビルドより、クラウド側のネイティブビルド (Cloud Build 等) に
  任せた方が速く確実。** 重いコンパイラを Rosetta 経由で動かすのは
  現時点では避けた方が良い。
- ビルドツールが違うと、`.dockerignore` 相当のファイルもツールごとに
  別名 (`.containerignore` / `.gcloudignore` / `.dockerignore`) になる
  ことがあるので、使うツールに合わせて用意する。
