#!/usr/bin/env bash
# =============================================================================
#  启动 ARK 服务端 —— 带取证、带等待、带自动重试
#
#  用法（在 WSL 里；任意目录都行，脚本会自己 cd 到项目目录）：
#      ./start.sh               # 启动（若已在正常运行则直接返回，不折腾）
#      ./start.sh --build       # 等价于 docker compose up -d --build
#      ./start.sh --force       # 强制重建（即使当前看起来是好的）
#
#  为什么不用裸的 docker compose up -d：
#    ① 对「已经在运行」的容器，up -d 是【空操作】，一行新日志都不会产生——
#       输出是 "Container xxx Running"（而不是 Started/Created）。
#    ② 输出确实是 "Started"、却照样看不到新日志 —— 容器日志文件被写坏了。
#       Docker 的 json-file 驱动「顺序解析，遇到第一条解不出来的行就停止」，
#       之后追加的内容全都读不出来，docker logs -f 永远停在旧内容上。
#       只有 down（删容器）才会重建日志，这就是「down 一下就好了」的真正原因。
#       注意：单纯「最后一行写成半截」并不会致命（Docker 会忽略尾部不完整行），
#       致命的是文件【中间】出现坏行。见 README FAQ 25。
#       另一条关键事实：全量读取和 --tail 是两条互不相干的路径（前者从头部
#       顺序解析、后者从末尾反向读），所以会分裂成「--tail 看得到本次新日志、
#       裸 docker logs 全是上一次的旧内容」。判定日志好坏必须两边对比，
#       只看 --tail 会漏检（本项目 2026-09-17 就漏过一次）。
#    ③ 启动失败若发生在 compose/守护进程层（镜像拉取、端口冲突、网络池冲突等），
#       错误信息只打印到终端，不会进 docker logs。
#  本脚本会记录启动前状态、compose 输出与退出码，等服务端进程真的出现，
#  并在上面 ①②③ 三种情况发生时自动处理/取证。输出同时写入 start-<时间戳>.log
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO" || { echo "无法进入项目目录：$REPO"; exit 9; }

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$REPO/start-$STAMP.log"
CONTAINER="${ARK_CONTAINER:-ark-server}"
WAIT="${START_WAIT_SECONDS:-150}"   # 等服务端进程出现的最长秒数

FORCE=0
ARGS=()
for a in "$@"; do
  case "$a" in
    # --force 必须真的转成 --force-recreate：裸 up -d 对已在运行的容器是空操作，
    # 不带上这个参数，“强制重建”就名不副实。
    --force) FORCE=1; ARGS+=("--force-recreate") ;;
    *)       ARGS+=("$a") ;;
  esac
done

say() { printf '%s\n' "$*"; }

# 容器里的 ARK 主进程是否活着。
# 两个坑（本项目各踩过一次）：
#   ① 不能用 pgrep -x ShooterGameServer：Linux 进程名（comm）最长 15 字符，
#      实际名字是 ShooterGameServe，写全名永远匹配不到。
#   ② 用 [S] 括号技巧：避免匹配到 pgrep 自己（以及 healthcheck 里 sh -c 的命令行）。
server_alive() {
  docker exec "$CONTAINER" pgrep -f '[S]hooterGameServer' >/dev/null 2>&1
}

# 日志流是否健康 —— 检测「中间出现坏行」这种损坏。
#
# 【关键】不能只用 --tail 判断，因为 Docker 的两条读取路径互不相干：
#   · 全量读取（裸 docker logs、logs -f）= 从头【顺序】解析，遇到第一条
#     解不出来的行就停 → 只能看到坏行之前的旧内容；
#   · --tail N = 从文件末尾【反向】读 → 能看到坏行之后的新内容。
# 于是会出现分裂状态：--tail 1 是本次启动的新日志，而裸 docker logs
# 全是上一次的旧内容（2026-09-17 本项目真实出现过：全量 257 行全是 09-15 的，
# 一行 09-17 都没有）。这也解释了「--since 明明给了正确时间却返回 0 行」——
# since 过滤后仍是从头扫，照样停在坏行。
#
# 所以探针必须【对比两条路径的最后一行】：全量读到的比末尾读到的还旧，
# 就说明全量被坏行截断了。
# 只比时间戳不比整行：两次调用之间服务端可能又写了新行，
# 那样全量只会【更新】，不会更旧，不会误判。
log_stream_ok() {
  local tail_last full_last tail_ts full_ts
  tail_last="$(docker logs --timestamps --tail 1 "$CONTAINER" 2>/dev/null | tr -d '\000' | tail -1)"
  full_last="$(docker logs --timestamps "$CONTAINER" 2>/dev/null | tr -d '\000' | tail -1)"
  # 两边都空：容器还没输出东西，不算坏
  if [ -z "$tail_last" ] && [ -z "$full_last" ]; then return 0; fi
  # 末尾能读到、全量一行都读不到 → 坏了
  if [ -n "$tail_last" ] && [ -z "$full_last" ]; then return 1; fi
  tail_ts="$(printf '%s' "$tail_last" | cut -c1-19)"
  full_ts="$(printf '%s' "$full_last" | cut -c1-19)"
  [[ "$full_ts" < "$tail_ts" ]] && return 1
  return 0
}

dump_diag() {
  say ""
  say "----------------------------------------------------------"
  say " [!] 诊断信息（把这段贴给排查的人）"
  say "----------------------------------------------------------"
  say "· 容器 State："
  docker inspect "$CONTAINER" --format \
    'Status={{.State.Status}} Running={{.State.Running}} ExitCode={{.State.ExitCode}} Error=[{{.State.Error}}]' 2>&1
  say "· 容器日志尾部 30 行："
  docker logs --tail 30 --timestamps "$CONTAINER" 2>&1 | tr -d '\000'
  say "· dockerd 最近 3 分钟的报错："
  journalctl -u docker --since '-3min' --no-pager 2>&1 \
    | grep -iE 'error|fail|denied|refus|timeout|cannot|unable|conflict|already' | tail -20
  say "· 端口占用（7777/7778/27015/32330）："
  ss -lunp 2>/dev/null | grep -E '7777|7778|27015|32330' || say "  (无)"
  ss -ltnp 2>/dev/null | grep -E '32330' || say "  (32330 tcp 无)"
  say "· 磁盘："
  df -h / /var/lib/docker 2>&1 | tail -3
}

# 等到容器里的 ARK 主进程真的起来。
#
# 【刻意不查日志】以前是 grep 日志里的「服务端进程 PID=」，有两个坑：
#   ① 容器不重建时日志是累积的，上一次的 PID 行还在 → 第一轮就命中，
#      秒返回「已出现」，哪怕本次其实卡在 Steam 下载（假阳性）；
#   ② 日志损坏时全量根本读不到新内容，而 --tail 窗口又可能整段都是旧内容。
# 进程在不在是硬事实，不依赖任何日志路径，所以直接查进程。
wait_ready() {
  local deadline=$(( $(date +%s) + WAIT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local st
    st="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"
    if [ "$st" != "running" ]; then
      say ">> 容器已不在 running（当前状态=${st:-不存在}）"
      return 1
    fi
    if server_alive; then
      return 0
    fi
    sleep 5
  done
  say ">> 等待 ${WAIT} 秒后容器内仍未出现 ARK 主进程"
  return 1
}

rebuild() {
  say ""
  say "--- 自动重建（compose down + up）---"
  say "   （就是你手工做的那一步；数据都在绑定目录里，不会丢）"
  docker compose down 2>&1
  say ">> down 退出码 = $?"
  docker compose up -d ${ARGS[@]+"${ARGS[@]}"} 2>&1
  say ">> up 退出码 = $?"
}

{
  say "=========================================================================="
  say " ARK 启动取证日志   $(date '+%Y-%m-%d %H:%M:%S')"
  say " 项目目录：$REPO"
  say " 参数：$*"
  say "=========================================================================="

  say ""
  say "--- [1] 启动前：容器状态 ---"
  if [ -z "$(docker ps -a -q --filter "name=^/${CONTAINER}$" 2>/dev/null)" ]; then
    say ">> 容器不存在，本次将全新创建"
  else
    st="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"
    say ">> $(docker ps -a --filter "name=^/${CONTAINER}$" --format '{{.Names}} | {{.Status}}')"
    if [ "$st" = "exited" ]; then
      ec="$(docker inspect -f '{{.State.ExitCode}}' "$CONTAINER" 2>/dev/null)"
      oom="$(docker inspect -f '{{.State.OOMKilled}}' "$CONTAINER" 2>/dev/null)"
      say ">> 上次退出码 = ${ec}（OOMKilled=${oom}）"
      case "$ec" in
        255)
          say "   （255 基本都不是 ARK 崩溃，而是被外部终止：Windows 关机/休眠、"
          say "    wsl --shutdown、dockerd 停止 —— 属于正常收尾，重新 up 即可）" ;;
        137) say "   （137 = 被 SIGKILL，常见于内存不足，需要看日志确认）" ;;
        139) say "   （139 = 段错误，服务端自身崩溃，需要看日志确认）" ;;
      esac
    fi
    if [ "$st" = "running" ]; then
      if [ "$FORCE" -eq 0 ] && server_alive; then
        say ""
        say ">> 服务端进程已在正常运行，本次不做任何操作。"
        say "   【重要】这种情况下直接跑 'docker compose up -d' 是空操作，"
        say "   docker logs 不会有任何新内容 —— 看到「没有新日志」时先确认这一点。"
        if ! log_stream_ok; then
          say ""
          say "   ⚠ 但检测到：这个容器的日志已经读不全了。"
          say "     --tail 能看到本次的新日志，可全量 docker logs / logs -f 会停在"
          say "     更早的旧内容上（json 日志中间有坏行）—— 也就是「看不到新日志」。"
          say "     服务端本身不受影响、可以正常进游戏，只是你看不到日志。"
          say "     要恢复日志： ./start.sh --force   （重建容器，存档不会丢）"
        fi
        docker ps --filter "name=^/${CONTAINER}$" --format '   {{.Names}} | {{.Status}}'
        say ""
        say "日志已保存：$LOG"
        exit 0
      fi
      say ">> 容器在跑，但里面没有 ARK 主进程（启动卡住 / 已崩溃）→ 需要重建"
      FORCE=1
    fi
  fi

  say ""
  say "--- [2] 执行 docker compose up -d ${ARGS[*]} ---"
  docker compose up -d ${ARGS[@]+"${ARGS[@]}"} 2>&1
  rc=$?
  say ">> compose 退出码 = $rc"
  if [ "$rc" -ne 0 ]; then
    say ""
    say ">> compose 本身报错了 —— 这就是「没有新日志」的原因之一："
    say "   容器压根没被创建/启动，docker logs 里当然什么都不会新增。"
    dump_diag
    say ""
    say "日志已保存：$LOG"
    exit "$rc"
  fi

  # 本次容器启动时刻（UTC）。之后的日志读取一律加 --since 限定到这个时刻之后。
  #
  # 为什么必须限定：容器不重建时 docker logs 是【累积】的，上一次启动的输出全在
  # 里面（本项目实测：9/16 那次的「服务端进程 PID=815」一直留在日志里）。
  # 不限定的话：
  #   ① wait_ready 第一轮就会 grep 到历史的 PID 行 → 秒返回「已出现」，
  #      即使本次其实卡在 Steam 下载也会误报成功；
  #   ② 最后打印的 tail 可能整屏都是上一次的内容，看着就像「日志是旧的」。
  # 打印本次容器启动时刻，方便判断日志是不是新的。
  # 注意 docker 的日志时间戳是 UTC：日志里的 15:17 对应本地 23:17（+8 小时）。
  BOOT_AT="$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER" 2>/dev/null \
             | sed 's/\.[0-9]*Z$/Z/')"
  [ -n "$BOOT_AT" ] && say ">> 本次容器启动于 ${BOOT_AT}（UTC，本地时间 = 该值 +8 小时）"

  say ""
  say "--- [3] 检查日志流是否可读 ---"
  # 入口脚本一进来就会打印带时间戳的横幅，所以 6 秒足够判断。
  sleep 6
  if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ] \
     && ! log_stream_ok; then
    say ">> 容器在跑，但日志流是坏的：--tail 能读到本次的新日志，"
    say "   全量 docker logs 却停在更早的旧内容上 —— 说明 json 日志中间有坏行。"
    say "   表现：docker logs -f（走全量路径）看不到任何新日志，--tail 却能看到。"
    say "   服务端本身不受影响、可以正常进游戏，只是日志读不全。"
    say "   处理：重建容器以拿到一份干净的日志（存档与模组都在卷里，不会丢）。"
    docker compose up -d --force-recreate ${ARGS[@]+"${ARGS[@]}"} 2>&1
    say ">> force-recreate 退出码 = $?"
    sleep 6
    if log_stream_ok; then
      say ">> 已恢复：日志可读"
    else
      say ">> 仍然读不出日志，继续下面的诊断流程"
    fi
  else
    say ">> 日志流正常"
  fi

  say ""
  say "--- [4] 等服务端进程出现（最多 ${WAIT} 秒）---"
  if ! wait_ready; then
    dump_diag
    rebuild
    if wait_ready; then
      say ">> 重建后成功：服务端进程已出现"
    else
      say ">> 重建后仍未起来"
      dump_diag
      say ""
      say "日志已保存：$LOG"
      exit 1
    fi
  else
    say ">> 服务端进程已出现"
  fi

  say ""
  say "--- [5] 结果 ---"
  docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}} | {{.Status}}'
  say "· 服务端日志尾部（--tail 路径，能看到最新内容）："
  say "  ⚠ 时间戳是 UTC：日志里的 15:17 就是本地 23:17（+8 小时），别误判成旧日志。"
  say "  容器内打印的中文时间戳（如 [2026-09-17 23:17:56]）才是本地时间。"
  docker logs --tail 12 --timestamps "$CONTAINER" 2>&1 | tr -d '\000'
  say ""
  say "日志已保存：$LOG"
  say "实时看日志：docker logs -f --tail 50 $CONTAINER"
  say "   （⚠ 别用裸的 logs -f：它会从头回放全部历史，实测 257 行就全量重放一遍，"
  say "    服务端跑得越久这段越长，新日志被压在最底下——看起来就像「没有新日志」）"
  say "探活：      python3 tools/a2s-probe.py localhost:27015"
} 2>&1 | tee "$LOG"
