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
#       这正是「用 log 命令看不到新日志」最常见的原因，而且事后完全无迹可寻。
#    ② 启动失败若发生在 compose/守护进程层（镜像拉取、端口冲突、网络池冲突等），
#       错误信息只打印到终端，不会进 docker logs。
#    本脚本会记录启动前状态、compose 输出与退出码，等服务端进程真的出现，
#    起不来时自动 dump 诊断信息并自动重试一次。输出同时写入 start-<时间戳>.log
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
    --force) FORCE=1 ;;
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

# 等到入口脚本打印「服务端进程 PID=」。
# 这里刻意不用管道：本脚本开了 pipefail，而 grep -q 会在首次命中时立刻退出，
# 导致上游 tr 收到 SIGPIPE（退出码 141），整个管道被判失败 —— 会假阴性。
wait_ready() {
  local deadline=$(( $(date +%s) + WAIT ))
  local tmp; tmp="$(mktemp)"
  local clean; clean="${tmp}.clean"
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local st
    st="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)"
    if [ "$st" != "running" ]; then
      rm -f "$tmp" "$clean"
      say ">> 容器已不在 running（当前状态=${st:-不存在}）"
      return 1
    fi
    docker logs "$CONTAINER" >"$tmp" 2>/dev/null
    tr -d '\000' <"$tmp" >"$clean"
    if grep -q '服务端进程 PID=' "$clean"; then
      rm -f "$tmp" "$clean"
      return 0
    fi
    sleep 5
  done
  rm -f "$tmp" "$clean"
  say ">> 等待 ${WAIT} 秒后仍未看到服务端进程"
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
    if [ "$st" = "running" ]; then
      if [ "$FORCE" -eq 0 ] && server_alive; then
        say ""
        say ">> 服务端进程已在正常运行，本次不做任何操作。"
        say "   【重要】这种情况下直接跑 'docker compose up -d' 是空操作，"
        say "   docker logs 不会有任何新内容 —— 看到「没有新日志」时先确认这一点。"
        say "   想强制重启： ./start.sh --force"
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

  say ""
  say "--- [3] 等服务端进程出现（最多 ${WAIT} 秒）---"
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
  say "--- [4] 结果 ---"
  docker ps --filter "name=^/${CONTAINER}$" --format '{{.Names}} | {{.Status}}'
  say "· 服务端日志尾部："
  docker logs --tail 12 --timestamps "$CONTAINER" 2>&1 | tr -d '\000'
  say ""
  say "日志已保存：$LOG"
  say "实时看日志：docker logs -f $CONTAINER"
  say "探活：      python3 tools/a2s-probe.py localhost:27015"
} 2>&1 | tee "$LOG"
