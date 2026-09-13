#!/usr/bin/env bash
# =============================================================================
#  ark-ase-server 一键排障：定位「服务端装不上」的责任方
#
#  用法（在 WSL 里执行，不要 sudo；也可以把代理地址当参数传进来）：
#      bash tools/diag-steamcmd.sh
#      bash tools/diag-steamcmd.sh http://host.docker.internal:7897
#
#  ⚠ 不碰你的数据目录：所有探针目录都在 --rm 容器的内部文件系统里，宿主机零残留。
#  ⚠ 每组最多 60~180 秒。
#
#  判读要用的一句话：
#      成功的标志是出现   Update state (0x3) reconfiguring
#      失败永远是这两句之一 ERROR! Failed to install app '376030'
#                              (Missing file permissions | Missing configuration)
#     ——这两句话**与文件权限无关**，它们是 Steam 侧的 EAppUpdateError 错误码
#       （8 = MissingFilePermissions，3 = MissingConfiguration）。
#
#  配套文档：README 常见问题 FAQ 15
# =============================================================================
set -u
cd "$(dirname "$0")/.." 2>/dev/null || { echo "无法定位项目根目录"; exit 1; }
hr(){ printf '\n===== %s =====\n' "$1"; }

ARK=376030    # ARK: Survival Evolved 专用服务器（本次要装的目标）
TINY=1007     # Steamworks SDK Redist —— 体积小、匿名可下载，用作**对照组**

read_env(){ grep -E "^$1=" .env 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'" || true; }

run_case(){ # $1=描述  $2=超时秒  $3..=docker run 参数
  local desc="$1"; shift
  local tmo="$1"; shift
  echo
  echo "--- ${desc} ---"
  local out
  out="$(timeout "${tmo}" docker run --rm "$@" 2>&1)"
  local rc=$?
  printf '%s\n' "$out" | tail -n 16
  if printf '%s' "$out" | grep -q 'Update state (0x3)'; then
    echo ">>> 结论：通过（已进入更新任务，说明这条路能装）"
  elif [ "$rc" = "8" ]; then
    echo ">>> 结论：失败（Steam 侧拒绝安装，退出码 8）"
  elif [ "$rc" = "124" ]; then
    echo ">>> 结论：超时收尾（若上面出现过 Update state (0x3) 即为通过）"
  else
    echo ">>> 结论：异常退出码 ${rc}"
  fi
}

hr "0. 引擎与用户信息"
docker version --format '  client={{.Client.Version}}  server={{.Server.Version}}' 2>&1
docker info --format '  os={{.OperatingSystem}}  root={{.DockerRootDir}}  storage={{.Driver}}' 2>&1
echo "  context    : $(docker context show 2>&1)"
echo "  WSL 侧用户 : $(id 2>&1)"

DATA_DIR="$(read_env DATA_DIR)"; DATA_DIR="${DATA_DIR:-./data}"
case "$DATA_DIR" in /*) : ;; *) DATA_DIR="$(pwd)/${DATA_DIR#./}" ;; esac
echo "  数据目录   : ${DATA_DIR}"

PROXY="${1:-}"
[ -z "$PROXY" ] && PROXY="$(read_env HTTPS_PROXY)"
if [ -n "$PROXY" ]; then echo "  代理       : ${PROXY}"; else echo "  代理       : 未配置（T5 将跳过）"; fi

STEAM_USER="$(read_env STEAM_USER)"
if [ -n "$STEAM_USER" ]; then echo "  Steam 账号 : ${STEAM_USER}（非匿名）"; else echo "  Steam 账号 : 匿名"; fi

hr "1. WSL 侧：磁盘 / inode / 属主 / 权限"
df -h "$DATA_DIR" 2>&1 | sed 's/^/  /'
echo "  --- inode ---"; df -i "$DATA_DIR" 2>&1 | sed 's/^/  /'
echo "  --- 属主·权限（数字形式 uid:gid）---"
ls -ldn "$DATA_DIR" "$DATA_DIR/server" "$DATA_DIR/steamcmd" 2>&1 | sed 's/^/  /'
case "$DATA_DIR" in /mnt/*) echo "  ⚠ 数据目录在 /mnt 下 —— Windows 挂载不保留 Linux 权限语义（README FAQ 13）" ;; esac

hr "2. 出网环境：有没有代理/TUN 在接管（这轮事故的真凶排查点）"
echo "  --- 宿主机默认路由（若存在 198.18.x.x / utun / Meta 之类，说明有 TUN 抢路由）---"
ip route 2>/dev/null | sed 's/^/  /' || true
echo "  --- 容器里看 host.docker.internal 解析成什么 ---"
docker run --rm --entrypoint /bin/bash ark-ase-server:latest -c \
  'echo "    host.docker.internal -> $(getent hosts host.docker.internal | awk "{print \$1}" | tr "\n" " ")"' 2>&1 | tail -n 3
echo "  ⚠ 若解析结果是 198.18.x.x 之类的假地址，说明宿主机的代理在 fake-ip 抢答 DNS，"
echo "    容器里的代理配置必然失效（会卡在 Retrying...）。"

hr "3. ★ 对照组（最关键的一步）：小 AppID ${TINY} 能不能装"
echo "  同一环境、同一镜像、同一命令结构，只把 AppID 从 ${ARK} 换成 ${TINY}。"
echo "  1007 小到几十 MB，能很快给出结论。"
run_case "T0 本项目镜像 + ${TINY}（对照）" 120 \
  --entrypoint /opt/steamcmd/steamcmd.sh ark-ase-server:latest \
  +force_install_dir /root/tinyprobe +login anonymous +app_update "$TINY" +quit

run_case "T2 本项目镜像 + ${ARK}（复现故障）" 120 \
  --entrypoint /opt/steamcmd/steamcmd.sh ark-ase-server:latest \
  +force_install_dir /root/arkprobe +login anonymous +app_update "$ARK" +quit

hr "4. 目标 App 的 access token 是否被 Steam 拒绝（决定性证据）"
rm -rf "$HOME/arkdiag"; mkdir -p "$HOME/arkdiag"
timeout 90 docker run --rm --entrypoint /bin/bash \
  -v "$HOME/arkdiag:/diag" ark-ase-server:latest -c "
    /opt/steamcmd/steamcmd.sh +force_install_dir /root/arkprobe2 \
      +login anonymous +app_update ${ARK} +quit
    mkdir -p /diag/steamlogs
    cp -a /root/Steam/logs/. /diag/steamlogs/ 2>/dev/null
    cp -a /opt/steamcmd/linux32/logs/. /diag/ 2>/dev/null
  " 2>&1 | tail -n 6
echo "  --- appinfo_log.txt 里的 access token 记录 ---"
grep -E 'app access tokens' "$HOME/arkdiag/steamlogs/appinfo_log.txt" 2>&1 | tail -n 4 | sed 's/^/  /' || echo "  （没有记录）"
echo "  --- content_log.txt 末尾 ---"
tail -n 4 "$HOME/arkdiag/steamlogs/content_log.txt" 2>&1 | sed 's/^/  /' || true

hr "5. 官方 cm2network/steamcmd 镜像（非 root + 自有 HOME）做交叉验证"
docker pull cm2network/steamcmd:latest 2>&1 | tail -n 1
run_case "T1 官方镜像 + ${ARK}" 150 \
  --entrypoint /home/steam/steamcmd/steamcmd.sh cm2network/steamcmd:latest \
  +force_install_dir /home/steam/arkprobe +login anonymous +app_update "$ARK" +quit

hr "6. 强制平台类型（部分教程的写法，用于排除平台探测问题）"
run_case "T3 本项目镜像 + ${ARK} + @sSteamCmdForcePlatformType linux" 150 \
  --entrypoint /opt/steamcmd/steamcmd.sh ark-ase-server:latest \
  +@sSteamCmdForcePlatformType linux +force_install_dir /root/fptprobe \
  +login anonymous +app_update "$ARK" +quit

if [ -n "$PROXY" ]; then
  hr "7. 代理路径对照（只有当你的代理确实可用时才有意义）"
  run_case "T5 本项目镜像 + ${ARK} + 代理 ${PROXY}" 180 \
    -e "HTTP_PROXY=${PROXY}" -e "HTTPS_PROXY=${PROXY}" \
    -e "http_proxy=${PROXY}" -e "https_proxy=${PROXY}" \
    -e "NO_PROXY=localhost,127.0.0.1,host.docker.internal" \
    -e "no_proxy=localhost,127.0.0.1,host.docker.internal" \
    --entrypoint /opt/steamcmd/steamcmd.sh ark-ase-server:latest \
    +force_install_dir /root/proxyprobe +login anonymous +app_update "$ARK" +quit
else
  echo
  echo "--- 第 7 节跳过：没有提供代理地址 ---"
  echo "    想测代理：bash tools/diag-steamcmd.sh http://host.docker.internal:7897"
fi

hr "怎么读结果"
cat <<'EOT'
  T0（1007）成功 + T2（376030）失败
        -> 环境/镜像/权限全部无罪，是 Steam 拒绝了 376030 的安装请求。
           第 4 节若出现 "Requested N app access tokens, 0 received, N denied" 即坐实。
           处置顺序：
             a) 先把容器出口流量改回直连 —— 关掉代理软件的 TUN / 全局模式，
                或只让 Steam 相关域名直连。这是最常见的原因。
             b) 仍不行就在 .env 里填 STEAM_USER / STEAM_PASS，改用真实 Steam 账号登录。
             c) 顺带用别的机器/别的网络验证一次，确认不是本机链路被限。

  T0 也失败
        -> 与 AppID 无关，是所有应用都装不上：看第 2 节的默认路由与 DNS，
           大概率是代理/TUN 把出网搞坏了；先把代理完全关掉再跑一次。

  T1（官方镜像）成功、T2 失败
        -> 差异在「镜像 / root / HOME」：可按官方做法把容器改成非 root 运行。

  T3 成功、T2 失败
        -> 平台探测问题，给 app_update 固定加上 @sSteamCmdForcePlatformType linux。

  全部失败且日志里全是 No Connection / Retrying
        -> 链路被阻断，与项目无关：先修网络，再谈安装。
EOT
