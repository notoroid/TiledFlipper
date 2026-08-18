#!/usr/bin/env python3
"""ローカルテストサーバー (TiledFlipperServer) を手元から叩いて中身を確かめるクライアント。

アプリを動かさずに `tiledflipper.v1.TileFlipService` の応答を見るためのもの。
gRPC のライブラリは使わず、HTTP/2 は curl に任せ、Protocol Buffers の読み書きは
このファイルの中だけで済ませている (追加のインストールが要らないようにするため)。

    # サーバーを別のターミナルで起動しておく
    $ swift run TiledFlipperServer

    # 配られているコレクションの一覧を見る
    $ Tools/tileflip_probe.py descriptions

    # 差し替え指示を 2 秒ぶん受け取り、流れ方を並べて見る
    $ Tools/tileflip_probe.py flips --kind clockwise-spiral --rows 6 --columns 8 --trace

対応しているのは openapi.yaml に書いてある 2 つのメソッドで、
メッセージの形も openapi.yaml (と Sources/.../Protos/tiledflipper.proto) に合わせてある。
片方を変えたらこちらも直すこと。
"""

import argparse
import struct
import subprocess
import sys
import tempfile
import urllib.parse

SERVICE = "tiledflipper.v1.TileFlipService"

# openapi.yaml の FeedKind。コマンドラインでは読みやすい名前で受け取る。
FEED_KINDS = {
    "unspecified": 0,
    "random-walk": 1,
    "clockwise-spiral": 2,
    "falling-column": 3,
    "zigzag": 4,
    "randomized": 5,
}


# --- Protocol Buffers の最低限の読み書き ---------------------------------

def _varint(value):
    out = b""
    while True:
        byte = value & 0x7F
        value >>= 7
        out += bytes([byte | (0x80 if value else 0)])
        if not value:
            return out


def _varint_field(number, value):
    return _varint(number << 3) + _varint(value)


def _message_field(number, payload):
    return _varint((number << 3) | 2) + _varint(len(payload)) + payload


def _duration(milliseconds):
    """google.protobuf.Duration。秒 (1) とナノ秒 (2) に分けて持つ。"""
    payload = b""
    if milliseconds >= 1000:
        payload += _varint_field(1, milliseconds // 1000)
    payload += _varint_field(2, (milliseconds % 1000) * 1_000_000)
    return payload


def _parse(payload):
    """メッセージを {フィールド番号: [値, ...]} に開く。

    値は varint なら int、長さ前置きなら bytes。この道具で読むのは
    数値と文字列と入れ子のメッセージだけなので、他の型は扱わない。
    """
    fields = {}
    index = 0
    while index < len(payload):
        key, index = _read_varint(payload, index)
        number, wire = key >> 3, key & 0x07
        if wire == 0:
            value, index = _read_varint(payload, index)
        elif wire == 2:
            length, index = _read_varint(payload, index)
            value, index = payload[index:index + length], index + length
        else:
            raise ValueError(f"扱えない wire type {wire} (フィールド {number})")
        fields.setdefault(number, []).append(value)
    return fields


def _read_varint(payload, index):
    value = shift = 0
    while True:
        byte = payload[index]
        index += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, index
        shift += 7


# --- gRPC の呼び出し (HTTP/2 は curl 任せ) --------------------------------

class RPCError(Exception):
    pass


def call(method, request, host, port, timeout):
    """1 つの RPC を呼び、届いたメッセージの一覧と grpc-status を返す。

    ストリームは終端が無いので、`timeout` 秒ぶん受け取ったところで打ち切る。
    その場合 curl は時間切れ (28) で終わるが、それはこちらの都合なのでエラーにしない。
    """
    with tempfile.NamedTemporaryFile() as headers:
        completed = subprocess.run(
            [
                "curl", "--silent", "--show-error", "--no-buffer",
                "--http2-prior-knowledge",
                "--request", "POST",
                f"http://{host}:{port}/{method}",
                "--header", "content-type: application/grpc+proto",
                "--header", "te: trailers",
                "--data-binary", "@-",
                "--max-time", str(timeout),
                "--dump-header", headers.name,
                "--output", "-",
            ],
            input=b"\x00" + struct.pack(">I", len(request)) + request,
            capture_output=True,
        )
        if completed.returncode not in (0, 28):   # 28 = こちらから打ち切った
            raise RPCError(completed.stderr.decode(errors="replace").strip())

        status, message = _status(headers.name)

    if status not in (0, None):
        raise RPCError(f"grpc-status {status}: {message}")

    return _messages(completed.stdout)


def _status(header_file):
    """trailer の grpc-status / grpc-message を読む。

    gRPC は正常もエラーも HTTP 200 で返し、結果は trailer に入る。
    打ち切ったときは trailer が届かないので、その場合は None。
    """
    status = message = None
    with open(header_file, "r", errors="replace") as file:
        for line in file:
            name, _, value = line.partition(":")
            if name.strip().lower() == "grpc-status":
                status = int(value.strip())
            elif name.strip().lower() == "grpc-message":
                # 非 ASCII は percent encoding で入っている
                message = urllib.parse.unquote(value.strip())
    return status, message


def _messages(body):
    """長さ前置きの gRPC フレームを 1 件ずつのメッセージに切り出す。"""
    messages = []
    index = 0
    while index + 5 <= len(body):
        length = struct.unpack(">I", body[index + 1:index + 5])[0]
        if index + 5 + length > len(body):
            break                      # 打ち切りで途中まで届いたフレーム
        messages.append(body[index + 5:index + 5 + length])
        index += 5 + length
    return messages


# --- サブコマンド ---------------------------------------------------------

def descriptions(args):
    messages = call(f"{SERVICE}/GetDescriptions", b"", args.host, args.port, args.timeout)
    if not messages:
        print("応答がありません")
        return 1

    found = _parse(messages[0]).get(1, [])
    if not found:
        print("配られているコレクションはありません (クライアントは同梱ぶんだけで動きます)")
        return 0

    print(f"{len(found)} 件:")
    for payload in found:
        fields = _parse(payload)

        def text(number):
            return fields.get(number, [b""])[0].decode()

        print(f"  {text(2)} (revision {fields.get(3, [0])[0]})")
        print(f"    url:               {text(1)}")
        print(f"    unique_identifier: {text(4)}")
        print(f"    artwork_list_file: {text(5)}")
    return 0


def flips(args):
    request = (
        _varint_field(1, args.rows)
        + _varint_field(2, args.columns)
        + _varint_field(3, args.artwork_count)
        + _varint_field(4, FEED_KINDS[args.kind])
    )
    if args.step_interval is not None:
        request += _message_field(5, _duration(args.step_interval))
    if args.flip_duration is not None:
        request += _message_field(6, _duration(args.flip_duration))
    if args.flips_per_turn is not None:
        request += _varint_field(7, args.flips_per_turn)
    if args.handover_flips is not None:
        request += _varint_field(8, args.handover_flips)
    if args.columns_per_drop is not None:
        request += _varint_field(9, args.columns_per_drop)

    messages = call(f"{SERVICE}/Flips", request, args.host, args.port, args.seconds)

    received = []
    for payload in messages:
        fields = _parse(payload)
        received.append((
            fields.get(1, [0])[0],     # row
            fields.get(2, [0])[0],     # column
            fields.get(3, [0])[0],     # artwork
        ))

    out_of_range = [
        flip for flip in received
        if not (0 <= flip[0] < args.rows
                and 0 <= flip[1] < args.columns
                and 0 <= flip[2] < args.artwork_count)
    ]

    print(f"{args.kind}: {args.seconds} 秒で {len(received)} 件"
          f" ({len(received) / args.seconds:.1f} 件/秒)、範囲外 {len(out_of_range)} 件")

    if args.trace and received:
        # 流れた順に (row,column) を並べる。演出の形はこれを見れば分かる。
        print("  " + " ".join(f"({row},{column})" for row, column, _ in received))

    return 1 if out_of_range else 0


def main(argv):
    parser = argparse.ArgumentParser(
        description=__doc__.splitlines()[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--host", default="127.0.0.1", help="サーバーのホスト (既定: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=31415, help="サーバーのポート (既定: 31415)")
    subcommands = parser.add_subparsers(dest="command", required=True)

    listing = subcommands.add_parser("descriptions", help="GetDescriptions を呼んで一覧を見る")
    listing.add_argument("--timeout", type=float, default=10, help="待つ秒数 (既定: 10)")
    listing.set_defaults(run=descriptions)

    stream = subcommands.add_parser("flips", help="Flips を呼んで差し替え指示を受け取る")
    stream.add_argument("--kind", choices=sorted(FEED_KINDS), default="randomized", help="流し方")
    stream.add_argument("--rows", type=int, default=12, help="グリッドの行数 (既定: 12)")
    stream.add_argument("--columns", type=int, default=8, help="グリッドの列数 (既定: 8)")
    stream.add_argument("--artwork-count", type=int, default=100, help="選べるアートワークの数")
    stream.add_argument("--seconds", type=float, default=2.0, help="受け取り続ける秒数 (既定: 2)")
    stream.add_argument("--step-interval", type=int, metavar="MS", help="次のマスへ進む間隔 (ミリ秒)")
    stream.add_argument("--flip-duration", type=int, metavar="MS", help="フリップ 1 回分の長さ (ミリ秒)")
    stream.add_argument("--flips-per-turn", type=int, help="randomized: 1 つの演出が流す枚数")
    stream.add_argument("--handover-flips", type=int, help="randomized: 残り何枚で次を始めるか")
    stream.add_argument("--columns-per-drop", type=int, help="falling-column: 何カラムに 1 本落とすか")
    stream.add_argument("--trace", action="store_true", help="流れた順に (row,column) を並べる")
    stream.set_defaults(run=flips)

    args = parser.parse_args(argv)
    try:
        return args.run(args)
    except RPCError as error:
        print(f"失敗しました: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
