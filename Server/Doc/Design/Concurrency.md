# 多重アクセスとタスクモデル

TiledFlipperServer に複数のクライアントから同時に繋がれたとき、要求が何に
分かれてどう捌かれるかをまとめたもの。

関連するドキュメント。

- `../RunningLocally.md` — 手元での起動と終了
- `CloudRun.md` — Cloud Run に載せたときの制約 (インスタンス、同時実行数、
  タイムアウト、ファイルシステム)
- `ServiceDesign.md` — gRPC サービスの設計 (メタデータ、双方向ストリーミング)

このリポジトリはデモンストレーションであり、クラウドでのコンテナ運用に
求められる要件をひととおり満たしてはいない。ここは「いま何がどうなって
いるか」の記録であって、本番運用の手引きではない。

## 結論

複数のリクエストは **同じプロセスに集約される**。アクセスごとにプロセスが
分かれることはない。

## プロセスとタスクの分かれ方

サーバーは単一プロセス・単一の `GRPCServer` として動く。

- `TiledFlipperTestServer.run()` は `HTTP2ServerTransport.Posix` で
  リスナーを 1 つ開き、`GRPCServer` を 1 つ `serve()` するだけ。
  fork もワーカープロセスの生成もしていない。
- RPC ごとに作られるのはプロセスでもスレッドでもなく、Swift Concurrency の
  Task。実行は SwiftNIO の EventLoopGroup (CPU コア数ぶんのスレッド) 上で
  多重化される。

NIO のトランスポートは、受け付けた HTTP/2 ストリーム 1 本ごとに
`group.addTask` で子タスクを立てる (`GRPCNIOTransportCore` の
`Server/CustomTransport.swift` で `handleStream` を回している箇所)。
gRPC では

    1 RPC = 1 HTTP/2 ストリーム = 1 タスク

という対応になる。

### 2 つのメソッドはそれぞれ別のタスク

このサーバーには 2 つのメソッドがある。ストリームを流し続ける `Flips` と、
要求に対して応答を 1 つ返す `GetDescriptions`。

- `getDescriptions` の 1 回の呼び出し → 1 タスク (応答を返して終わる)
- `flips` の 1 本のストリーム → 1 タスク (クライアントが切るまで生き続ける)

同じクライアントからの 2 つの呼び出しでも完全に別のタスクになる。ただし
これらは同一プロセス内の別タスクであって、別プロセスではない。

`TileFlipServiceConnection` は `GRPCClient` を 1 つしか持たないので、2 つの
RPC は 1 本の TCP/HTTP/2 接続の上に多重化されて飛び、サーバー側で 2 本の
ストリームに分かれてそれぞれタスクになる。

## `TileFlipFeedActor` が全ストリーム共通の直列点

供給元の内部状態はすべて `TileFlipFeedActor` の中でだけ触る作りなので、
1 プロセス内の全 RPC の生成処理がこの 1 つのアクターに直列化される。

1 件あたりの仕事は軽く、待ちはすべて `Task.sleep` の中断なので実用上は
詰まらない。ただし「同一プロセス内の並列度」は同時実行数の値どおりには
出ない。同時接続を大きく増やすなら、フィードごとに独立したアクターへ
分けるのが素直。

## 状態が RPC ローカルであること

- 供給元は `flips` の呼び出しごとに新しく作られる。
- 配布するコレクションの一覧は起動時に確定し、以後変わらない。

RPC をまたいで持ち越す状態が無いため、リクエストが別々のインスタンスへ
振り分けられても整合性の問題は起きない。この性質は水平スケールを安全に
している一方で、次の節のような RPC 間の連携を阻んでもいる。

## 2 つの RPC の間で状態を伝えられるか

一方のメソッドから、他方で走っているストリームへ変更を伝えられるか、
という話。

### いまは伝えられない

意図してそうしたというより、繋ぐものが何も置かれていない。

- `TileFlipService` が持つ状態は `descriptions` だけで、`init` で確定して
  以後は変わらない。
- 供給元は `flips` の呼び出しごとに `makeFeed` で新しく作られ、その参照を
  持っているのは `flips()` が内部で立てたタスクだけ。サービス側はどこにも
  保持していない。
- そもそも 2 つの RPC を結びつける鍵が無い。`GetDescriptionsRequest` に
  セッション ID の類は無く、認証も入っていないので、「いま来た
  `getDescriptions` は、動いているどの `flips` ストリームの持ち主か」を
  判定する手段が存在しない。

### やるとしたら

技術的には難しくない。足すのは 3 つ。

**(a) 共有の置き場。** `TileFlipService` は struct だが、そこに actor を 1 つ
持たせれば、生成コードが RPC ごとに扱う struct のコピーはすべて同じ actor の
実体を共有する。

```swift
actor FlipControlCenter {
    private var feeds: [String: any TileFlipFeed] = [:]
    func register(_ feed: any TileFlipFeed, for session: String) { ... }
    func feed(for session: String) -> (any TileFlipFeed)? { ... }
}
```

**(b) 対応付けの鍵。** `FlipsRequest` にセッション ID を足すか、Bearer の
subject を使う (`ServiceDesign.md` を参照)。認証を入れるなら後者が自然。

**(c) 走っているストリームへの反映。** ここは今の作りが有利で、供給元は
`@TileFlipFeedActor` 上のクラス (参照型) であり、`flips()` のループは毎ティック
自分のプロパティを読み直している。外から同じアクター上でプロパティを書き換え
れば、**次のティックで自然に反映される**。`AsyncStream` の continuation を
いじる必要はない。

```swift
@TileFlipFeedActor
func changeArtworkCount(_ count: Int) { self.artworkCount = count }
```

いまは `artworkCount` などが `let` なので、変えたいものを `var` にして
書き換え口を `TileFlipFeed` プロトコルへ足す、という改修になる。制御を
「別の指示ストリームとして混ぜる」より、こちらのほうがずっと簡単。

### ただし、単一プロセスの前提が崩れる

この設計はインスタンスが 1 つであることに依存している。Cloud Run では
`flips` を保持しているインスタンスと、あとから来た `getDescriptions` が
到達するインスタンスが別になり得るため、プロセス内の actor に置いた共有状態は
黙って空振りする。詳細と回避策は `CloudRun.md` の「ルーティングはリクエスト
単位」を参照。

そもそもこの壁を避ける手もある。`ServiceDesign.md` の双方向ストリーミングに
すると、共有状態そのものが要らなくなる。

## Task ごとの一時領域を分ける

入力ストリームで受け取ったバイナリを一時ファイルへ落とすような場合、
同じインスタンスに複数のリクエストが相乗りするため、置き場を RPC ごとに
分ける必要がある。

分離自体は難しくない。**固定パスを使わず、RPC ごとに一意なディレクトリを
掘る**だけ。

```swift
func flips(
    request: RPCAsyncSequence<...>,
    response: RPCWriter<...>,
    context: ServerContext
) async throws {
    let scratch = FileManager.default.temporaryDirectory
        .appending(path: "flips-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    ...
}
```

押さえるべき点。

- **PID やホスト名では分かれない。** 既定の同時実行数では 1 プロセスに最大
  80 リクエストが相乗りするので、分離の鍵は RPC ごとに振った UUID (または
  Bearer の subject と組み合わせたもの) になる。競合を厳密に避けたいなら
  `mkdtemp(3)` でアトミックに作れる。
- **`defer` での削除は必須。** Cloud Run では一時領域がメモリなので
  (`CloudRun.md` 参照)、消し忘れがそのままリークになる。クライアントが消えて
  RPC がキャンセルされた場合、ハンドラ内の `try await` が `CancellationError`
  を投げるので `defer` は走る。ただし待ちが非 throwing の箇所だけだと素通り
  するので、`context.cancellation` を明示的に見る箇所を作っておくと安全。
- **全体量はアクターで合算管理する。** 1 本あたりの上限だけでは、80 本同時の
  ときに守れない。インスタンス全体の使用量を持つアクターを 1 つ置き、超えたら
  新規ストリームを `RPCError(code: .resourceExhausted)` で拒否する。

### I/O のブロッキング

`FileHandle.write(contentsOf:)` は同期 syscall で、Swift Concurrency の
協調スレッドプールをブロックする。メモリ上のファイルシステム相手なら実害は
小さいが、ネットワーク越しのマウントや実ディスクだと、同居している他の
ストリームを巻き込んで詰まる。

swift-nio に `NIOFileSystem` モジュールがあり (既に推移的依存として入って
いる)、こちらはノンブロッキング。使うなら `Package.swift` に swift-nio を
直接の依存として追加する必要がある。
