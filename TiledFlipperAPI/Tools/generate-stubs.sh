#!/bin/bash
#
#  generate-stubs.sh
#  TiledFlipperAPI
#
#  Sources/TiledFlipperAPI/Generated/ のスタブを作り直す。
#
#  スタブは生成物だがリポジトリに入れてある。ビルドプラグイン
#  (GRPCProtobufGenerator) を Xcode プロジェクトへ持ち込むとプラグインの
#  信頼を毎回訊かれるので、アプリ側は生成済みのものを読むだけにしている。
#
#  proto の実体は Server が持っているものを 1 つだけ使う。写しは作らない。
#  protoc と 2 つのプラグインは Server をビルドしたときの生成物を借りる
#  (swift-protobuf に同梱されているので、別途入れる必要は無い)。
#
#  使い方:
#    swift build --package-path Server   # 初回だけ protoc のビルドで時間がかかる
#    TiledFlipperAPI/Tools/generate-stubs.sh
#
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
server_root="${repository_root}/Server"
products="${server_root}/.build/out/Products/Debug"
protos="${server_root}/Sources/TiledFlipperServerCore/Protos"
# google.protobuf.Duration などの定義。protoc に同梱されているものを使う。
well_known_protos="${server_root}/.build/checkouts/swift-protobuf/Sources/protobuf/include"
output="${repository_root}/TiledFlipperAPI/Sources/TiledFlipperAPI/Generated"

for tool in protoc protoc-gen-swift protoc-gen-grpc-swift-2; do
    if [ ! -x "${products}/${tool}" ]; then
        echo "error: ${tool} が無い。先に 'swift build --package-path Server' を実行すること。" >&2
        exit 1
    fi
done

mkdir -p "${output}"

# アプリからは別モジュールとして読むので、生成物は public で出す。
# サーバー側のスタブは要らない (アプリは呼ぶだけ)。
"${products}/protoc" \
    --plugin="protoc-gen-swift=${products}/protoc-gen-swift" \
    --plugin="protoc-gen-grpc-swift-2=${products}/protoc-gen-grpc-swift-2" \
    --proto_path="${protos}" \
    --proto_path="${well_known_protos}" \
    --swift_opt=Visibility=Public \
    --swift_out="${output}" \
    --grpc-swift-2_opt=Visibility=Public,Client=true,Server=false \
    --grpc-swift-2_out="${output}" \
    tiledflipper.proto

echo "generated:"
ls -1 "${output}"
