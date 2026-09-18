#!/usr/bin/env bash
# =============================================================================
#  关闭 ARK 服务端 —— 优雅保存世界（与 start.sh 对称）
#
#  用法（在 WSL 里，任意目录都行，脚本会自己 cd 到项目目录）：
#      ./stop.sh                # 优雅停止（保留容器与日志；下次 ./start.sh 很快起来）
#      ./stop.sh --down         # 停止并【删除容器】（连 json 日志一起删；
#                               #  日志读不到时用这个重置。存档在卷里，不会丢）
#      ./stop.sh --timeout 240  # 自定义等待上限秒数（默认 180）
#      ./stop.sh --help
#
#  为什么必须"优雅"停：
#    服务端要收到 SIGINT 才会把世界写盘。`docker kill` / 直接关机 = 最近的进度丢失，
#    而且效果等同于硬断电 —— json 日志会被撕裂出坏行，之后 docker logs 永远读不到
#    新内容（这正是 README FAQ 25 那个「看不到新日志」的来源）。
#
#  为什么不直接用 docker compose stop：
#    它默认只等 10 秒就 SIGKILL，而 ARK 保存一个大世界可能要几十秒。
#    本脚本把超时显式放到 180 秒，留足余量。时间关系：
#      stop.sh -t 180  >  stop_grace_period 150s  >  容器内 STOP_TIMEOUT 90s
#    即：容器内部最多等 90 秒保存世界，Docker 在最外层最多等 180 秒。
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO" || { echo "无法进入项目目录：$REPO"; exit 9; }

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$REPO/stop-$STAMP.log"
CONTAINER="${ARK_CONTAINER:-ark-server}"
TIMEOUT=180
MODE="stop"

while [ $# -gt 0 ]; do
  case "$1" in
    --down)    MODE="down"; shift ;;
    --timeout) TIMEOUT="${2:-180}"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *)         echo "未知参数：$1（用 --help 看用法）"; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }

# 把 docker 日志的 UTC 时间戳前缀换算成本地时间（与 start.sh 同一套逻辑）
logs_local() {
  docker logs --timestamps "$@" "$CONTAINER" 2>&1 | tr -d '\000' \
  | while IFS= read -r line; do
      ts="${line%% *}"
      case "$ts" in
        *Z)
          ts_clean="$(printf '%s' "$ts" | sed 's/\.[0-9]*Z$/Z/')"
          lt="$(TZ="${TZ_NAME:-Asia/Shanghai}" date -d "$ts_clean" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
          if [ -n "$lt" ]; then
            printf '%s  %s\n' "$lt" "${line#* }"
            continue
          fi
          ;;
      esac
      printf '%s\n' "$line"
    done
}

{
  say "=========================================================================="
  say " ARK 关停取证日志   $(date '+%Y-%m-%d %H:%M:%S')"
  say " 项目目录：$REPO"
  say " 模式：${MODE}    等待上限：${TIMEOUT}s"
  say "=========================================================================="

  say ""
  say "--- [1] 关闭前状态 ---"
  if [ -z "$(docker ps -a -q --filter "name=^/${CONTAINER}$" 2>/dev/null)" ]; then
    say ">> 容器不存在，无需关闭。"
    say ""
    say "日志已保存：$LOG"
    exit 0
  fi
  say ">> $(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.Names}} | {{.Status}}')"
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
    say ">> 容器当前未在运行，无需关闭。"
    say "   （若想连容器一起清掉： ./stop.sh --down）"
    say ""
    say "日志已保存：$LOG"
    exit 0
  fi

  QPORT="$(grep -E '^QUERY_PORT=' .env 2>/dev/null | cut -d= -f2 | tr -d '\r')"
  QPORT="${QPORT:-27015}"
  say "· 关服前在线状态（$QPORT）："
  python3 tools/a2s-probe.py "localhost:${QPORT}" 2>&1 | tail -2 || say "  (探测失败，可能仍在加载中)"

  say ""
  say "--- [2] 优雅停止（SIGTERM → 容器内转 SIGINT → 服务端保存世界）---"
  say "     ⚠ 大世界保存可能要几十秒，这期间别关终端、别关机。"
  t0="$(date +%s)"
  if [ "$MODE" = "down" ]; then
    docker compose down -t "$TIMEOUT" 2>&1
  else
    docker compose stop -t "$TIMEOUT" 2>&1
  fi
  rc=$?
  elapsed=$(( $(date +%s) - t0 ))
  say ">> compose 退出码 = $rc，耗时 ${elapsed}s"

  say ""
  say "--- [3] 结果 ---"
  docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.Names}} | {{.Status}}'
  say ""
  if [ "$MODE" = "down" ]; then
    say ">> 容器与它的 json 日志都已删除（存档在卷里，不受影响）。"
    say "   下次 ./start.sh 会重新创建，日志从此是干净的。"
  else
    say "· 关服过程的关键日志（应能看到「收到停止信号」「服务端已停止」）："
    saved="$(logs_local --tail 40 2>/dev/null | grep -E '停止信号|保存|已停止|超时|强制' || true)"
    if [ -n "$saved" ]; then
      printf '%s\n' "$saved"
    else
      say "  （读不到这些标志 —— 可能是日志已损坏，见 README FAQ 25；"
      say "    但服务端自身仍可能已正常保存。可用 ./stop.sh --down 重置日志。）"
    fi
  fi

  say ""
  say "★ 关机 / 休眠前请先跑本脚本 ★"
  say "  直接关机 = 世界来不及保存 + json 日志被撕裂出坏行，"
  say "  之后 docker logs 就读不到新日志了。"
  say ""
  say "日志已保存：$LOG"
} 2>&1 | tee "$LOG"
