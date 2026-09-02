# gRPC サービスの設計

TiledFlipperServer の gRPC まわりで、いまの作りがどうなっているかと、
機能を足すときにどこへ手を入れることになるかをまとめたもの。

API の形はリポジトリルートの `openapi.yaml` に書いてあり、proto は
`Sources/TiledFlipperServerCore/Protos/tiledflipper.proto` がその写し。

関連するドキュメント。

- `../RunningLocally.md` — 手元での起動と終了
- `Concurrency.md` — 多重アクセスとタスクモデル
- `CloudRun.md` — Cloud Run に載せたときの制約

## Bearer によるユーザーの判別

認証済みユーザーのトークンを `Authorization: Bearer <token>` で渡して、
サーバー側で誰からの呼び出しかを判別できるか、という話。

結論としては **技術的には可能**。ただし、いまのコードのままでは読めない。
塞いでいる箇所がはっきり 1 つある。

### 仕組み

gRPC のメタデータは HTTP/2 のヘッダーフレームそのもの。`authorization` は
特別扱いの必要がなく、ふつうのヘッダーとして往復する。キーは小文字化される
点だけ注意する。

クライアント側は既に用意ができている。生成スタブの各メソッドは `metadata:`
引数を持っていて、`TileFlipServiceConnection` がそれを既定値のまま渡して
いないだけ。

```swift
try await service.getDescriptions(
    request,
    metadata: ["authorization": "Bearer \(token)"]
)
```

### サーバー側が読めない理由

`TileFlipService` は `SimpleServiceProtocol` に適合している。これは生成
コードのコメントが明言しているとおり「リクエスト/レスポンスのメタデータに
アクセスできない」最上位の簡易プロトコルで、既定実装が `request.metadata`
を捨ててメッセージ本体だけをハンドラへ渡す。

`ServerContext` にもメタデータは無い。持っているのは `descriptor` /
`remotePeer` / `localPeer` / `transportSpecific` / `cancellation` だけ。

### 直し方

**(a) `ServiceProtocol` に降りる。** ハンドラの引数が `ServerRequest<T>` に
なり、`request.metadata` が読める。

```swift
extension TileFlipService: Tiledflipper_V1_TileFlipService.ServiceProtocol {
    func flips(
        request: ServerRequest<Tiledflipper_V1_FlipsRequest>,
        context: ServerContext
    ) async throws -> StreamingServerResponse<Tiledflipper_V1_TileFlip> {
        let bearer = request.metadata[stringValues: "authorization"].first { _ in true }
        ...
    }
}
```

**(b) `ServerInterceptor` を使う (こちらが素直)。** grpc-swift 2 の
`ServerInterceptor` の doc comment に、まさに `authorization` メタデータを
取り出す例が載っている。`GRPCServer(transport:services:interceptors:)` で
登録でき、全 RPC 横断で検証して、未認証は `RPCError(code: .unauthenticated)`
で弾ける。

ただし **interceptor で判別したユーザーをハンドラへ渡す方法には落とし穴が
ある**。TaskLocal に入れて `next(request, context)` を包む書き方は
`getDescriptions` では動くが、`flips` では動かない。`next` が返す
`StreamingServerResponse` の producer クロージャは interceptor を抜けたあとに
トランスポート側から呼ばれるので、TaskLocal のスコープから外れる。確実なのは
interceptor が `request.metadata` へ検証済みの subject を書き足し、(a) の
ハンドラで読む形。

### 検証は自前

JWT の署名検証は grpc-swift はやってくれない。JWKS の取得とキャッシュ、
`iss` / `aud` / `exp` の検証は自前で書く必要がある (Swift なら JWTKit)。
いまのサーバーの依存には入っていない。

また、検証はストリームを開くときの 1 回だけになる。`flips` には終端が無いので、
長く続くストリームの途中でトークンが失効しても切れない。`CloudRun.md` の
リクエストタイムアウトで定期的に張り直す設計にすると、そこで自然に再検証が
入る。

Cloud Run の IAM 認証と `Authorization` ヘッダーが衝突する件は
`CloudRun.md` を参照。

## 入力と出力を 1 つのメソッドにまとめる (双方向ストリーミング)

入力ストリームと出力ストリームを 1 つのメソッドで扱う方法はあるか、という話。
**双方向ストリーミング RPC** がまさにそれで、gRPC が最初から持っている
4 種類のうちの 1 つ。

| 種類 | proto の書き方 | いまの該当 |
| --- | --- | --- |
| Unary | `rpc F(Req) returns (Res)` | `GetDescriptions` |
| Server streaming | `rpc F(Req) returns (stream Res)` | `Flips` |
| Client streaming | `rpc F(stream Req) returns (Res)` | — |
| Bidirectional streaming | `rpc F(stream Req) returns (stream Res)` | — |

HTTP/2 のストリームはもともと全二重なので、これは追加の仕掛けではなく、
1 本のストリームの両方向を両方とも使うだけ。

### proto の変更は 1 語

```proto
rpc Flips(stream FlipsRequest) returns (stream TileFlip);
```

### 生成されるシグネチャ

`SimpleServiceProtocol` 側は、入力が単一メッセージから `RPCAsyncSequence` に
変わる。

```swift
func flips(
    request: RPCAsyncSequence<Tiledflipper_V1_FlipsRequest, any Error>,
    response: RPCWriter<Tiledflipper_V1_TileFlip>,
    context: ServerContext
) async throws
```

補足すると、**双方向の場合だけは `ServiceProtocol` と
`StreamingServiceProtocol` のシグネチャが一致する** (コード生成器が「両方
ストリーミングなら既定実装は要らない、署名が同じだから」と明示的に分岐して
いる)。つまり `ServiceProtocol` に適合すると引数が `StreamingServerRequest<T>`
になり、`request.metadata` がそのまま読める。前述の「(a) `ServiceProtocol` に
降りる」が、双方向では追加コストなしで手に入る。

### 実装は TaskGroup で 2 方向に分ける

受信ループと送信ループはどちらもブロックするので、片方ずつ子タスクにする。

```swift
func flips(
    request: RPCAsyncSequence<...>,
    response: RPCWriter<...>,
    context: ServerContext
) async throws {
    var iterator = request.makeAsyncIterator()
    guard let first = try await iterator.next() else { return }   // 最初の 1 通で設定
    let feed = try await Self.makeFeed(for: first, ...)

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {                       // 送信: いまの flips とほぼ同じ
            for await flip in await feed.flips() {
                try await response.write(.init(flip))
            }
        }
        group.addTask {                       // 受信: 変更指示を feed へ反映
            while let update = try await iterator.next() {
                await feed.apply(update)
            }
        }
        try await group.next()                // どちらかが終わったら畳む
        group.cancelAll()
    }
}
```

クライアント側の生成スタブは `requestProducer:` クロージャが増える形になる。

```swift
try await service.flips(metadata: [...]) { writer in
    try await writer.write(initialRequest)
    // 以降、必要になったタイミングで書き足す
} onResponse: { response in
    for try await flip in response.messages { ... }
}
```

### RPC 間の連携が要らなくなる

`Concurrency.md` に書いた「`getDescriptions` から走行中の `flips` へ変更を
伝える」ために必要だったもの — 共有 actor、セッション ID、インスタンスを
またぐための外部ブローカー — は、双方向にすると **すべて不要になる**。

同じ HTTP/2 ストリームなので、常に同じインスタンスの同じタスクへ届く。
ルーティングで別インスタンスへ飛ぶ心配が無く、状態は RPC ローカルのままで
(水平スケールの安全性を壊さない)、`feed` は関数内のローカル変数として共有
できる。デモの規模なら `--max-instances=1` で縛るより、こちらのほうが素直。

### 変わらない制約

- リクエストタイムアウトは同じく効く。双方向にしても無限には続かない。
- 同時実行数の枠を占有し続けるのも同じ。
- HTTP/2 エンドツーエンド (`--use-http2`) が必須なのも同じ。
- 順序保証は **方向ごと** にしか無い。「送った変更指示が、どの `TileFlip` の
  直後に効いたか」はプロトコル上決まらないので、必要なら明示的なシーケンス
  番号を持たせる。

### 設計上の注意

いまの `FlipsRequest` は `rows` / `columns` / `artworkCount` / `feedKind` など
**開始時の設定の塊**。そのまま `stream` にすると、2 通目以降のメッセージの
意味が曖昧になる (`rows` が来たらグリッドを作り直すのか?)。定石は `oneof` で
分けること。

```proto
message FlipsRequest {
  oneof kind {
    FlipsStart start = 1;    // 最初の 1 通だけ
    FlipsUpdate update = 2;  // 以降の変更指示
  }
}
```

## バイナリを分割して受け取る

入力ストリームでサイズ不定のバイナリをパーツに分けて送る場合。

### メッセージサイズの上限

gRPC のメッセージ上限は既定 4 MiB (`HTTP2ServerTransport` の
`RPC.defaults.maxRequestPayloadSize`)。パーツ 1 個をこれ以下に収めるか、設定で
引き上げる。「パーツに分けて送る」設計自体はこの制限に対して正しい方向。

Cloud Run のリクエストサイズ上限 (32 MiB) はストリーミングには適用されないと
されているが、実装前に現行のドキュメントで確認すること。

### join は「あとで結合」ではなく「追記」でよい

gRPC の順序保証は方向ごとにある。1 本の入力ストリームで送られたパーツは、
**送信順そのままの順序で届く**。したがってパーツを別ファイルに保存して
あとから結合する必要はなく、同じファイルハンドルへ追記していけば、受け終わった
時点で join 済みになる。

パーツごとにファイルを分ける意味があるのは、再送やリトライで順序が壊れうる
場合 (= 別々の RPC で送る場合) だけ。1 本の双方向ストリームに載せるなら不要。

### 置き場

保存先の選び方は `CloudRun.md` の「ファイルシステムはメモリ」を、RPC ごとに
分ける方法は `Concurrency.md` の「Task ごとの一時領域を分ける」を参照。

タイムアウトで途中で切られると中途半端なファイルが残るので、`defer` での
掃除に加えて、パーツにシーケンス番号を持たせて途中から再送できるように
しておくと安全。
