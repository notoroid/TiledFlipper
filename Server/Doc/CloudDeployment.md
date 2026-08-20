# 将来のクラウド移行: Google Cloud か AWS か

TiledFlipperServer は最終的に Google Cloud か AWS のコンテナサービス上で
動かすことを目指している。[Containerfile](../Containerfile) は OCI 標準の
マルチステージビルドなので、どちらのクラウドにもそのまま持っていける。
今すぐどちらかに確定させる必要はなく、実際にデプロイする段階で選べば良い。
以下は、先に選ぶ必要が出た場合の比較。

## 比較表

| 観点 | Google Cloud Run | AWS (ECS Fargate + ALB) |
|---|---|---|
| gRPC の公式サポート | ネイティブ対応 (`--use-http2` 一つ)。[WWDC26 #265](https://developer.apple.com/jp/videos/play/wwdc2026/265) のデモも実際に Cloud Run へデプロイしている | ALB は gRPC (HTTP/2) 対応済みだが、API Gateway は gRPC 非対応。App Runner の gRPC 対応は Cloud Run ほど枯れていない |
| セットアップの手間 | `gcloud run deploy` 一発。VPC や LB を自分で組む必要なし | VPC・ALB・ターゲットグループ・ECS サービス定義が必要で、初期構築の手間が大きい |
| スケール/課金 | リクエストが無ければ 0 までスケール、従量課金。個人/検証用途に向く | Fargate は基本常時課金 (Spot で多少節約可)。ゼロスケールは Cloud Run ほど簡単でない |
| 長時間ストリーミング | リクエストタイムアウトの上限あり (最大 60 分)。`flips` のような常時ストリーミング RPC は接続が定期的に切れる可能性 | ALB には Cloud Run のような総時間上限がなく、常時ストリーミングに強い |
| 将来の拡張性 (アートワーク zip 配信など) | Cloud Storage + Cloud CDN で同様に可能 | S3 + CloudFront など選択肢が豊富、他の AWS サービスとの統合がしやすい |

## 今の段階での推奨

**Google Cloud Run。** 理由は、参考にした [WWDC26 #265](https://developer.apple.com/jp/videos/play/wwdc2026/265)
のセッションが grpc-swift + Cloud Run で実際に動くパターンを示しており、
それに乗るのが一番近道だから。デプロイの具体例もセッション内にある:

```bash
gcloud run deploy tiledflipper-server \
  --image us-central1-docker.pkg.dev/<project>/<repo>/tiledflipper-server:latest \
  --region us-central1 \
  --use-http2 \
  --allow-unauthenticated
```

クライアント側 (アプリ) は TLS + DNS 名の HTTP/2 接続に切り替える:

```swift
try .http2NIOTS(
    target: .dns(host: "tiledflipper-server-xxxxxxxx.us-central1.run.app"),
    transportSecurity: .tls
)
```

## AWS を選ぶ方が良いケース

- `TileFlipFeed` のような常時ストリーミング RPC を本番でも使う設計にする場合。
  Cloud Run のリクエストタイムアウト上限 (最大 60 分) に引っかかる可能性があるため。
- 組織/プロジェクトで既に AWS の課金・IAM・VPC 基盤がある場合。
  ECS Fargate + ALB は構築の手間はかかるが、既存の AWS 資産 (S3, CloudFront,
  CloudWatch など) と統合しやすい。

## 参考: このリポジトリの現状

[TiledFlipperEndpoint.local.txt](../../TiledFlipperEndpoint.local.txt) に
`http://` (平文 h2c) の手元アドレスを書けばローカルの Apple Container /
`swift run` 環境に、`https://` の URL を書けば TLS 経由でクラウド上の
サーバーに、それぞれそのまま繋がる (scheme で自動的に切り替わる。
[EmbeddedEndpoints.swift](../../TiledFlipper/EmbeddedEndpoints.swift) 参照)。
どちらのクラウドを選んでも、アプリ側の変更は不要。
