#!/usr/bin/env python3
"""ARK 服务端存活探测（A2S_INFO / Source Engine Query）。

用法：
    python tools/a2s-probe.py 172.18.46.222:27015
    python tools/a2s-probe.py 172.18.46.222:27015 127.0.0.1:27015 192.168.10.10:7777

为什么需要它：
    判断 ARK 有没有真正起来，看日志和 CPU/IO 都不可靠 —— 启动时 ShooterGame.log
    会长时间保持 0 字节（用户态缓冲未 flush），进程空闲时 CPU/IO 也几乎不动。
    唯一可靠的判据是协议级探测：向查询端口发 A2S_INFO，有回包就是活着。

    注意填查询端口（默认 27015），不是游戏端口 7777。
"""

import socket
import sys

QUERY = b"\xff\xff\xff\xffTSource Engine Query\x00"


def probe(host, port, timeout=3.0):
    """返回原始响应字节；超时或无响应返回 None。"""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(QUERY, (host, port))
        data, _ = sock.recvfrom(4096)
        return data
    except Exception:
        return None
    finally:
        sock.close()


def parse(data):
    """解析 A2S_INFO 的固定前缀部分，失败返回 None。"""
    try:
        idx = data.index(b"\x00", 1) + 1
        name = data[1:idx - 1].decode("utf-8", "replace")
        rest = data[idx:]
        fields = []
        for _ in range(5):  # map, folder, game, game_desc(short), game_desc
            cut = rest.index(b"\x00")
            fields.append(rest[:cut].decode("utf-8", "replace"))
            rest = rest[cut + 1:]
        cut = rest.index(b"\x00")  # steam app id 之后
        rest = rest[cut + 1:]
        return {
            "name": name,
            "map": fields[0],
            "game": fields[2],
            "players": rest[0],
            "max": rest[1],
        }
    except Exception:
        return None


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 1

    failed = False
    for target in argv[1:]:
        host, _, port = target.rpartition(":")
        if not host or not port.isdigit():
            print(f"{target}: 格式应为 <ip>:<port>，例如 172.18.46.222:27015")
            failed = True
            continue

        data = probe(host, int(port))
        if data is None:
            print(f"{target:26s} TIMEOUT / NO REPLY")
            failed = True
            continue

        info = parse(data)
        if info is None:
            print(f"{target:26s} 收到 {len(data)} 字节（无法解析）")
            continue
        print(f"{target:26s} OK  地图={info['map']} "
              f"玩家={info['players']}/{info['max']}  名称={info['name']}")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
