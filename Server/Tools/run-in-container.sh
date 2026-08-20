#!/bin/bash
#
# TiledFlipperServer を Apple Container (`container` CLI, macOS 26+) の
# 中でビルド・起動し、TiledFlipperEndpoint.local.txt をコンテナの IP に
# 合わせて書き換える。
#
#   Server/Tools/run-in-container.sh
#
# 前提: `container system start` 済みであること (未起動なら自動で起動する)。
# Package.swift / Sources を変えた後は毎回このスクリプトを実行し直せば良い。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

IMAGE_NAME="tiledflipper-server"
CONTAINER_NAME="tiledflipper-server"
ENDPOINT_FILE="TiledFlipperEndpoint.local.txt"

echo "== container system の起動を確認 =="
container system start >/dev/null

echo "== イメージをビルド =="
container build -t "$IMAGE_NAME" -f Server/Containerfile Server

echo "== 既存のコンテナを片付ける =="
container rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "== コンテナを起動 =="
# ボリュームマウントはディレクトリ単位なので Server/ ごとマウントし、
# ArtworkPackages.local.json があれば --catalog で指す。
RUN_ARGS=(--host 0.0.0.0 --port 8080)
if [ -f Server/ArtworkPackages.local.json ]; then
    RUN_ARGS+=(--catalog /data/ArtworkPackages.local.json)
fi

container run -d --name "$CONTAINER_NAME" \
    -v "$REPO_ROOT/Server:/data:ro" \
    "$IMAGE_NAME" "${RUN_ARGS[@]}"

echo "== コンテナの IP を確認 =="
ADDRESS="$(container inspect "$CONTAINER_NAME" | python3 -c '
import json, sys
info = json.load(sys.stdin)[0]
address = info["networks"][0]["address"].split("/")[0]
print(address)
')"

ENDPOINT_URL="http://${ADDRESS}:8080"
echo "TiledFlipperServer: ${ENDPOINT_URL}"
container logs "$CONTAINER_NAME"

if [ -f "$ENDPOINT_FILE" ]; then
    printf '# run-in-container.sh が自動更新 (%s)\n%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$ENDPOINT_URL" >"$ENDPOINT_FILE"
    echo "== ${ENDPOINT_FILE} を更新しました。Xcode でアプリを再ビルドしてください =="
else
    echo "== ${ENDPOINT_FILE} が無いので手で作って上の URL を書いてください (${ENDPOINT_FILE}.example を参照) =="
fi
