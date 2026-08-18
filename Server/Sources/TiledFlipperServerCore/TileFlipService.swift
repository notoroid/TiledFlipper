//
//  TileFlipService.swift
//  TiledFlipperServerCore
//

import GRPCCore
import SwiftProtobuf

/// `tiledflipper.v1.TileFlipService` の実装。
///
/// - `getDescriptions` は起動時に読んだ一覧をそのまま返す。
/// - `flips` は `TileFlipFeeds/` の供給元が作った指示を、そのままストリームへ流す。
struct TileFlipService {

    /// 配っているコレクションの一覧。起動時に決まり、以後は変わらない。
    private let descriptions: [Tiledflipper_V1_NetworkArtworkDescription]

    init(catalog: ArtworkPackageCatalog) {
        // 受け取った時点で proto のメッセージにしておく。RPC のたびに作り直さない。
        self.descriptions = catalog.descriptions.map { description in
            Tiledflipper_V1_NetworkArtworkDescription.with {
                $0.url = description.url.absoluteString
                $0.name = description.name
                $0.revision = Int32(description.revision)
                $0.uniqueIdentifier = description.uniqueIdentifier
                $0.artworkListFile = description.artworkListFile
            }
        }
    }
}

extension TileFlipService: Tiledflipper_V1_TileFlipService.SimpleServiceProtocol {

    /// 配られているアートワークコレクションの一覧を返す。
    ///
    /// アートワークの実体 (zip) はここでは返さない。返すのは「どこに何があるか」だけで、
    /// コレクションが選ばれたときにクライアントが `url` から取りに行く。
    /// 配布先を用意していなければ空の一覧を返す。openapi.yaml の通り、これはエラーではない。
    func getDescriptions(
        request: Tiledflipper_V1_GetDescriptionsRequest,
        context: ServerContext
    ) async throws -> Tiledflipper_V1_GetDescriptionsResponse {
        Tiledflipper_V1_GetDescriptionsResponse.with {
            $0.descriptions = self.descriptions
        }
    }

    /// 差し替え指示を `step_interval` ごとに 1 件ずつ流し続ける。
    ///
    /// 終端は無い。クライアントが読むのをやめる (ストリームをキャンセルする) と
    /// このタスクもキャンセルされ、供給元のループも止まる。
    func flips(
        request: Tiledflipper_V1_FlipsRequest,
        response: RPCWriter<Tiledflipper_V1_TileFlip>,
        context: ServerContext
    ) async throws {
        let rows = Int(request.rows)
        let columns = Int(request.columns)

        guard rows > 0, columns > 0 else {
            throw RPCError(
                code: .invalidArgument,
                message: "rows と columns は 1 以上であること (rows: \(rows), columns: \(columns))"
            )
        }
        // 差し替え先が無いときは流すものが無いので、そのまま終える。
        guard request.artworkCount > 0 else { return }

        for await flip in try await Self.flipStream(for: request, rows: rows, columns: columns) {
            try await response.write(
                Tiledflipper_V1_TileFlip.with {
                    $0.row = Int32(flip.row)
                    $0.column = Int32(flip.column)
                    $0.artwork = Int32(flip.artwork)
                }
            )
        }
    }

    /// 頼まれた流し方で差し替え指示を作り、そのストリームを返す。
    ///
    /// 供給元そのものはアクターの中に置いたままにする。ストリームを作るときの
    /// タスクが供給元を掴んでいるので、読み終える (キャンセルされる) まで生き続ける。
    @TileFlipFeedActor
    private static func flipStream(
        for request: Tiledflipper_V1_FlipsRequest,
        rows: Int,
        columns: Int
    ) throws -> AsyncStream<TileFlip> {
        try makeFeed(for: request, rows: rows, columns: columns).flips()
    }

    /// 頼まれた流し方の供給元を作る。
    ///
    /// 演出ごとにしか効かない設定 (`flips_per_turn` など) は、openapi.yaml の通り
    /// その演出のときだけ読む。未指定のものは供給元の既定値に任せる。
    @TileFlipFeedActor
    private static func makeFeed(
        for request: Tiledflipper_V1_FlipsRequest,
        rows: Int,
        columns: Int
    ) throws -> any TileFlipFeed {
        let artworkCount = Int(request.artworkCount)
        let stepInterval = request.hasStepInterval ? Duration(request.stepInterval) : .milliseconds(90)
        let flipDuration = request.hasFlipDuration ? Duration(request.flipDuration) : .milliseconds(600)

        switch request.feedKind {
        case .randomWalk:
            return RandomWalkTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                stepInterval: stepInterval
            )

        case .clockwiseSpiral:
            return ClockwiseSpiralTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                stepInterval: stepInterval,
                flipDuration: flipDuration
            )

        case .fallingColumn:
            return FallingColumnTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                stepInterval: stepInterval,
                columnsPerDrop: request.hasColumnsPerDrop ? Int(request.columnsPerDrop) : 3
            )

        case .zigzag:
            return ZigzagTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                stepInterval: stepInterval
            )

        // 未指定は RANDOMIZED と同じ扱い。
        case .unspecified, .randomized:
            return RandomizedTileFlipFeed(
                rows: rows,
                columns: columns,
                artworkCount: artworkCount,
                flipsPerTurn: request.hasFlipsPerTurn ? Int(request.flipsPerTurn) : nil,
                handoverFlips: request.hasHandoverFlips ? Int(request.handoverFlips) : 6,
                flipDuration: flipDuration,
                stepInterval: stepInterval
            )

        case .UNRECOGNIZED(let value):
            // こちらが知らない演出。黙って別のもので流すと、頼んだ側から見て
            // 何が起きたのか分からないので、そのまま返す。
            throw RPCError(code: .invalidArgument, message: "知らない feed_kind (\(value))")
        }
    }
}

extension Duration {
    /// `google.protobuf.Duration` から作る。
    fileprivate init(_ duration: SwiftProtobuf.Google_Protobuf_Duration) {
        self = .seconds(duration.seconds) + .nanoseconds(duration.nanos)
    }
}
