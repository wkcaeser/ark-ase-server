#!/usr/bin/env bash
# =============================================================================
#  方舟：生存进化（ARK: Survival Evolved）专用服务器 —— 容器入口脚本
#
#  子命令：
#    start    安装/更新服务端与模组 -> 生成配置 -> 启动服务器（默认）
#    install  仅安装/更新服务端与模组（可配合 docker compose run --rm ark install）
#    install-mods  仅下载并部署模组（不动服务端本体）
#    render   仅根据环境变量重新生成 GameUserSettings.ini / Game.ini
#    backup   备份存档（ShooterGame/Saved）到 /backup
#    restore  从备份恢复，用法：restore <备份文件名>
#    mods     打印最终生效的模组列表
#    doctor   环境自检：挂载 / 权限 / 磁盘 / 代理 / SteamCMD 状态（排障用）
#    version  打印当前服务端 buildid
#    shell    进入容器 shell
# =============================================================================
set -Eeuo pipefail

# ------------------------------- 日志 ---------------------------------------
if [ -t 1 ]; then
  C_INFO=$'\033[1;34m'; C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'; C_OFF=$'\033[0m'
else
  C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_OFF=''
fi
_ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s[%s][信息]%s %s\n' "$C_INFO" "$(_ts)" "$C_OFF" "$*"; }
ok()   { printf '%s[%s][完成]%s %s\n' "$C_OK"   "$(_ts)" "$C_OFF" "$*"; }
warn() { printf '%s[%s][警告]%s %s\n' "$C_WARN" "$(_ts)" "$C_OFF" "$*" >&2; }
err()  { printf '%s[%s][错误]%s %s\n' "$C_ERR"  "$(_ts)" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }
to_lower() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'; }
# 布尔判断：自动忽略行内 # 注释与空白
is_true()  {
  local v="${1:-}"
  v="${v%%#*}"
  v="$(to_lower "$v" | tr -d '[:space:]')"
  case "$v" in 1|true|yes|y|on|启用) return 0 ;; *) return 1 ;; esac
}
# 数值净化：去掉行内注释与空白；非法值回退默认（避免 ENV 写成 "20  # 注释" 后污染 ini）
sanitize_num() {
  local name="$1" val="${2:-}" def="${3:-1}"
  val="${val%%#*}"
  val="$(printf '%s' "$val" | tr -d '[:space:]')"
  if printf '%s' "$val" | grep -qE '^-?[0-9]+(\.[0-9]+)?$'; then
    printf '%s' "$val"
  else
    warn "变量 ${name} 的值「${2}」不是合法数字，已回退为 ${def}（提示：注释请单独占一行）"
    printf '%s' "$def"
  fi
}

# 批量净化数值型环境变量（在生成配置前调用）
normalize_numbers() {
  local var val
  for var in DIFFICULTY_OFFSET OVERRIDE_OFFICIAL_DIFFICULTY MAX_PLAYERS PORT QUERY_PORT \
             RCON_PORT AUTO_SAVE_PERIOD_MINUTES KICK_IDLE_PLAYERS_PERIOD STOP_TIMEOUT \
             BACKUP_KEEP STEAMCMD_RETRIES XP_MULTIPLIER TAMING_SPEED_MULTIPLIER \
             EGG_HATCH_SPEED_MULTIPLIER BABY_MATURE_SPEED_MULTIPLIER MATING_INTERVAL_MULTIPLIER \
             MATING_SPEED_MULTIPLIER LAY_EGG_INTERVAL_MULTIPLIER \
             BABY_IMPRINTING_STAT_SCALE_MULTIPLIER BABY_FOOD_CONSUMPTION_SPEED_MULTIPLIER \
             PLAYER_WEIGHT_PER_LEVEL_MULTIPLIER DINO_WEIGHT_PER_LEVEL_MULTIPLIER \
             ITEM_WEIGHT_MULTIPLIER HARVEST_AMOUNT_MULTIPLIER HARVEST_HEALTH_MULTIPLIER \
             LOOT_QUALITY_MULTIPLIER CROP_GROWTH_SPEED_MULTIPLIER DINO_COUNT_MULTIPLIER \
             DINO_FOOD_DRAIN_MULTIPLIER DINO_STAMINA_DRAIN_MULTIPLIER \
             DINO_HEALTH_RECOVERY_MULTIPLIER PLAYER_FOOD_DRAIN_MULTIPLIER \
             PLAYER_WATER_DRAIN_MULTIPLIER POOP_INTERVAL_MULTIPLIER \
             FUEL_CONSUMPTION_INTERVAL_MULTIPLIER; do
    val="${!var}"
    printf -v "$var" '%s' "$(sanitize_num "$var" "$val" 1)"
  done
  if [ -n "${MAX_TAMED_DINOS// /}" ]; then
    MAX_TAMED_DINOS="$(sanitize_num MAX_TAMED_DINOS "$MAX_TAMED_DINOS" 0)"
    [ "$MAX_TAMED_DINOS" = "0" ] && MAX_TAMED_DINOS=""
  fi
}

# --------------------------- 路径与固定参数 ---------------------------------
APP_ID="${APP_ID:-376030}"                    # ARK: Survival Evolved Dedicated Server
WORKSHOP_APP_ID="${WORKSHOP_APP_ID:-346110}"  # ARK: Survival Evolved（创意工坊模组归属客户端）

# Steam 登录方式：默认匿名（大多数专用服务端够用）。
# 少数情况下 Steam 会**拒绝给匿名会话签发某个 App 的 access token**，此时 SteamCMD 报的
# 却是 "Missing file permissions" / "Missing configuration"（见 README FAQ 15）。
# 遇到这种情况就填一个真实 Steam 账号来绕开：
#   STEAM_USER=你的账号   STEAM_PASS=你的密码
# ⚠ 建议用专门建的小号，并注意密码会出现在 .env（记得别把它提交进 git）。
STEAM_USER="${STEAM_USER:-}"
STEAM_PASS="${STEAM_PASS:-}"

ARK_SERVER_DIR="${ARK_SERVER_DIR:-/ark}"
STEAMCMD_DIR="${STEAMCMD_DIR:-/opt/steamcmd}"
STEAMCMD_PATH="${STEAMCMD_PATH:-${STEAMCMD_DIR}/steamcmd.sh}"
BACKUP_DIR="${BACKUP_DIR:-/backup}"
USER_CONFIG_DIR="${USER_CONFIG_DIR:-/etc/ark/config}"

CONFIG_DIR="${ARK_SERVER_DIR}/ShooterGame/Saved/Config/LinuxServer"
MODS_DIR="${ARK_SERVER_DIR}/ShooterGame/Content/Mods"
SERVER_BIN="${ARK_SERVER_DIR}/ShooterGame/Binaries/Linux/ShooterGameServer"
SAVED_DIR="${ARK_SERVER_DIR}/ShooterGame/Saved"
STEAMCMD_RETRIES="${STEAMCMD_RETRIES:-3}"

# --------------------------- 运维开关 ---------------------------------------
AUTO_UPDATE="${AUTO_UPDATE:-true}"                  # 每次启动检查并更新服务端
STEAM_VALIDATE="${STEAM_VALIDATE:-false}"           # 更新时校验文件完整性（慢，排障用）
MOD_UPDATE="${MOD_UPDATE:-true}"                    # 每次启动检查并更新模组
CONFIG_REGENERATE="${CONFIG_REGENERATE:-true}"      # 每次启动按环境变量重写配置
CONFIG_BACKUP="${CONFIG_BACKUP:-true}"              # 重写前备份旧配置（保留最近 5 份）
BACKUP_KEEP="${BACKUP_KEEP:-10}"                    # backup 子命令保留的备份份数
STOP_TIMEOUT="${STOP_TIMEOUT:-90}"                  # 停机时等待世界保存的秒数
SKIP_INSTALL_ON_START="${SKIP_INSTALL_ON_START:-false}"  # true=启动时完全不碰 SteamCMD
STEAM_PRECHECK="${STEAM_PRECHECK:-true}"             # 更新前先探测 Steam 是否可达，不可达就跳过（省约 7 分钟）
ALLOW_WINDOWS_DATA_DIR="${ALLOW_WINDOWS_DATA_DIR:-false}" # true=数据目录在 Windows/网络挂载上也照常启动（不推荐）

# --------------------------- 服务器身份 -------------------------------------
SESSION_NAME="${SESSION_NAME:-方舟生存进化-专用服务器}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"
SERVER_ADMIN_PASSWORD="${SERVER_ADMIN_PASSWORD:-}"
MAP="${MAP:-TheIsland}"
PORT="${PORT:-7777}"
QUERY_PORT="${QUERY_PORT:-27015}"
RCON_ENABLED="${RCON_ENABLED:-true}"
RCON_PORT="${RCON_PORT:-32330}"
MAX_PLAYERS="${MAX_PLAYERS:-70}"
SERVER_PVE="${SERVER_PVE:-true}"
SERVER_HARDCORE="${SERVER_HARDCORE:-false}"
DIFFICULTY_OFFSET="${DIFFICULTY_OFFSET:-1.0}"
OVERRIDE_OFFICIAL_DIFFICULTY="${OVERRIDE_OFFICIAL_DIFFICULTY:-5.0}"
BATTLEYE_ENABLED="${BATTLEYE_ENABLED:-true}"
MAX_TAMED_DINOS="${MAX_TAMED_DINOS:-}"
AUTO_SAVE_PERIOD_MINUTES="${AUTO_SAVE_PERIOD_MINUTES:-15}"
KICK_IDLE_PLAYERS_PERIOD="${KICK_IDLE_PLAYERS_PERIOD:-0}"

# 玩法开关（true/false）
ALLOW_THIRD_PERSON="${ALLOW_THIRD_PERSON:-true}"
SHOW_MAP_PLAYER_LOCATION="${SHOW_MAP_PLAYER_LOCATION:-true}"
ALLOW_FLYER_CARRY_PVE="${ALLOW_FLYER_CARRY_PVE:-true}"
DISABLE_STRUCTURE_DECAY_PVE="${DISABLE_STRUCTURE_DECAY_PVE:-true}"
SERVER_CROSSHAIR="${SERVER_CROSSHAIR:-true}"
SHOW_FLOATING_DAMAGE_TEXT="${SHOW_FLOATING_DAMAGE_TEXT:-true}"
ALLOW_HIT_MARKERS="${ALLOW_HIT_MARKERS:-true}"

# --------------------------- 倍率配置 ---------------------------------------
XP_MULTIPLIER="${XP_MULTIPLIER:-1}"

# —— 驯养 / 繁殖 / 孵化 ——
TAMING_SPEED_MULTIPLIER="${TAMING_SPEED_MULTIPLIER:-1}"          # 驯养速度
EGG_HATCH_SPEED_MULTIPLIER="${EGG_HATCH_SPEED_MULTIPLIER:-1}"    # 蛋孵化速度
BABY_MATURE_SPEED_MULTIPLIER="${BABY_MATURE_SPEED_MULTIPLIER:-1}" # 幼体成长速度
MATING_INTERVAL_MULTIPLIER="${MATING_INTERVAL_MULTIPLIER:-1}"    # 交配间隔（越小越快）
MATING_SPEED_MULTIPLIER="${MATING_SPEED_MULTIPLIER:-1}"          # 交配过程速度
LAY_EGG_INTERVAL_MULTIPLIER="${LAY_EGG_INTERVAL_MULTIPLIER:-1}"  # 下蛋间隔（越小越快）
BABY_IMPRINTING_STAT_SCALE_MULTIPLIER="${BABY_IMPRINTING_STAT_SCALE_MULTIPLIER:-1}"
BABY_FOOD_CONSUMPTION_SPEED_MULTIPLIER="${BABY_FOOD_CONSUMPTION_SPEED_MULTIPLIER:-1}"

# —— 负重 ——（每级属性点加成倍率，写进 Game.ini）
PLAYER_WEIGHT_PER_LEVEL_MULTIPLIER="${PLAYER_WEIGHT_PER_LEVEL_MULTIPLIER:-1}"
DINO_WEIGHT_PER_LEVEL_MULTIPLIER="${DINO_WEIGHT_PER_LEVEL_MULTIPLIER:-1}"
# 物品自身重量倍率（1=原版；小于 1 为减重）
ITEM_WEIGHT_MULTIPLIER="${ITEM_WEIGHT_MULTIPLIER:-1}"

# —— 采集 / 成长 / 消耗 ——
HARVEST_AMOUNT_MULTIPLIER="${HARVEST_AMOUNT_MULTIPLIER:-1}"
HARVEST_HEALTH_MULTIPLIER="${HARVEST_HEALTH_MULTIPLIER:-1}"
LOOT_QUALITY_MULTIPLIER="${LOOT_QUALITY_MULTIPLIER:-1}"
CROP_GROWTH_SPEED_MULTIPLIER="${CROP_GROWTH_SPEED_MULTIPLIER:-1}"
DINO_COUNT_MULTIPLIER="${DINO_COUNT_MULTIPLIER:-1}"
DINO_FOOD_DRAIN_MULTIPLIER="${DINO_FOOD_DRAIN_MULTIPLIER:-1}"
DINO_STAMINA_DRAIN_MULTIPLIER="${DINO_STAMINA_DRAIN_MULTIPLIER:-1}"
DINO_HEALTH_RECOVERY_MULTIPLIER="${DINO_HEALTH_RECOVERY_MULTIPLIER:-1}"
PLAYER_FOOD_DRAIN_MULTIPLIER="${PLAYER_FOOD_DRAIN_MULTIPLIER:-1}"
PLAYER_WATER_DRAIN_MULTIPLIER="${PLAYER_WATER_DRAIN_MULTIPLIER:-1}"
POOP_INTERVAL_MULTIPLIER="${POOP_INTERVAL_MULTIPLIER:-1}"
FUEL_CONSUMPTION_INTERVAL_MULTIPLIER="${FUEL_CONSUMPTION_INTERVAL_MULTIPLIER:-1}"
USE_SINGLEPLAYER_SETTINGS="${USE_SINGLEPLAYER_SETTINGS:-false}"

# --------------------------- 模组 -------------------------------------------
# 默认模组（列表顺序 = 加载顺序）：
#   761535755   物品叠加（Ultra Stacks）—— 叠加/大修类模组放最前面，避免被内容模组盖掉
#   817096835   野人模组（Extinction Core / 起源2 灭绝野人）
#   1404697612  A镜（Awesome SpyGlass!）
DEFAULT_MODS="${DEFAULT_MODS:-761535755,817096835,1404697612}"
ENABLE_DEFAULT_MODS="${ENABLE_DEFAULT_MODS:-true}"   # 是否加载上面三个默认模组
EXTRA_MODS="${EXTRA_MODS:-}"                         # 追加模组，逗号或空格分隔
MODS="${MODS:-}"                                     # 完全自定义：设置后忽略默认模组与 EXTRA_MODS

# --------------------------- 集群 / 高级 -------------------------------------
CLUSTER_ID="${CLUSTER_ID:-}"
CLUSTER_DIR_OVERRIDE="${CLUSTER_DIR_OVERRIDE:-${ARK_SERVER_DIR}/ShooterGame/Saved/clusters}"
ALT_SAVE_DIR_NAME="${ALT_SAVE_DIR_NAME:-}"
EXTRA_ARGS="${EXTRA_ARGS:-}"                         # 追加任意启动参数（原样追加在最后）
# 追加 URL 参数：形如 `Key=Value`，多个用 ? 或 & 分隔，会被拼进地图 URL 里。
# 为什么需要它：本版 ASE 服务端只认命令行上的这些「会话级」设置，写进
# GameUserSettings.ini 会被它在启动时重写时丢弃（详见 launch_server 里的注释）。
# 例：EXTRA_URL_ARGS=ForceAllowCaveFlyers=true?bDisableFriendlyFire=true
EXTRA_URL_ARGS="${EXTRA_URL_ARGS:-}"

SERVER_PID=""
ACTIVE_MODS=""
ACTIVE_MOD_ARRAY=()

# =============================================================================
#  工具函数
# =============================================================================
ensure_dirs() {
  local d
  for d in "$ARK_SERVER_DIR" "$CONFIG_DIR" "$MODS_DIR" "$BACKUP_DIR" "$USER_CONFIG_DIR"; do
    mkdir -p "$d" 2>/dev/null || warn "无法创建目录 ${d}（权限不足？请检查挂载目录属主）"
  done
  check_data_dirs
}

# 数据目录自检：Windows 挂载（Docker Desktop 走 9p/DrvFs）不保留 Linux 权限语义，
# chmod 近似空操作，SteamCMD 会直接报 "Missing file permissions" 而一字节都装不上，
# 且因为 restart 策略会无限重启刷屏。这里主动、尽早把原因讲清楚。
check_data_dirs() {
  local fstype="" bad="false" why=""

  fstype="$(stat -f -c %T "$ARK_SERVER_DIR" 2>/dev/null || true)"
  case "$fstype" in
    9p|drvfs|vboxsf|cifs|smb2|nfs|msdos|ntfs|fuseblk)
      bad="true"; why="所在文件系统为 ${fstype}（Windows/网络挂载），不保留 Linux 权限" ;;
  esac

  # 功能自检：写入 -> chmod 600 -> 读回权限；权限没生效时会露馅
  local probe="${ARK_SERVER_DIR}/.perm_probe.$$"
  if printf 'x' > "$probe" 2>/dev/null; then
    chmod 600 "$probe" 2>/dev/null || true
    local mode; mode="$(stat -c %a "$probe" 2>/dev/null || true)"
    rm -f "$probe" 2>/dev/null || true
    if [ "$mode" != "600" ]; then
      bad="true"; why="${why:+${why}；}chmod 600 读回为 ${mode:-未知}，权限未生效"
    fi
  else
    bad="true"; why="${why:+${why}；}无法在 ${ARK_SERVER_DIR} 写入文件"
  fi

  if [ "$bad" = "false" ]; then
    log "数据目录自检通过（${ARK_SERVER_DIR}，文件系统 ${fstype:-未知}）"
    return 0
  fi

  if is_true "$ALLOW_WINDOWS_DATA_DIR"; then
    warn "数据目录自检未通过：${why}。因 ALLOW_WINDOWS_DATA_DIR=true 继续启动；若 SteamCMD 报 Missing file permissions，请把 DATA_DIR 改到 WSL 原生路径。"
    return 0
  fi

  err "数据目录不可用：${why}"
  cat >&2 <<TIPS

  ────────────────────────────────────────────────────────────────────────
  这会导致 SteamCMD 报：
      ERROR! Failed to install app '${APP_ID}' (Missing file permissions)
  服务端永远装不上，容器还会被 restart 策略反复拉起。

  修复：把数据放到 WSL 自己的文件系统（ext4），不要用 /mnt/c 下的路径。
    1) 在 WSL 里执行：echo \$HOME          # 例如 /home/wk_home
    2) 编辑 .env：
           DATA_DIR=/home/<你的用户名>/ark-data
    3) 重建容器：
           docker compose down
           mv ./data/* "\$HOME/ark-data/" 2>/dev/null || true
           docker compose up -d --build

  确实想用当前目录（不推荐）：在 .env 里设 ALLOW_WINDOWS_DATA_DIR=true
  ────────────────────────────────────────────────────────────────────────

TIPS
  exit 1
}

# 代理自检：容器出网若被指定走代理，SteamCMD 的下载链路一旦走不通，对外只报
# "Missing file permissions" / "Missing configuration"（完全与文件权限无关），极难自查。
# 这里顺便识别本项目最隐蔽的一个坑：改完 .env 只 restart、没重建 —— 容器里的代理
# 仍然是创建时固化的旧值，于是「怎么改 .env 都没用」。
warn_if_proxy() {
  local eff="${HTTP_PROXY:-${http_proxy:-}}"
  [ -n "$eff" ] || return 0
  warn "容器出网走代理：HTTP_PROXY=${eff}"
  if [ -z "${PROXY_HTTP:-}" ] && [ -z "${PROXY_HTTPS:-}" ]; then
    warn "  但 .env 里的 PROXY_HTTP / PROXY_HTTPS 是空的 → 容器里这个代理值是【创建时固化的旧值】。"
    warn "  说明改完 .env 只 restart 过、没有重建。环境变量在容器创建时固化，"
    warn "  docker compose restart 与 restart 策略的自动重启都不会重读 .env。执行："
    warn "      docker compose up -d --force-recreate"
  fi
  warn "  ⚠ 端口写错（Clash Verge 默认 7897，不是 7890）或代理不可达时，SteamCMD 会报"
  warn "    Missing file permissions / Missing configuration —— 那是代理问题，不是文件权限问题。"
  warn "  ⚠ 宿主机开着 TUN / 全局模式时，这一层代理应留空：TUN 已接管容器出网，叠加只会打架。"
}

# SteamCMD 自检（若挂载卷里没有则自动补装）
ensure_steamcmd() {
  if [ ! -x "$STEAMCMD_PATH" ]; then
    warn "未找到 SteamCMD（${STEAMCMD_PATH}），正在自动下载…"
    mkdir -p "$STEAMCMD_DIR"
    local url="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
    if ! curl -fsSL "$url" | tar -xz -C "$STEAMCMD_DIR"; then
      die "SteamCMD 下载失败，请检查容器网络（国内公网建议给 Docker 配置代理或换用国内镜像源）"
    fi
  fi
  local home="${HOME:-/root}"
  if [ -d "$home" ] && [ -w "$home" ]; then
    mkdir -p "$home/.steam/sdk64" "$home/.steam/sdk32" 2>/dev/null || true
    ln -sf "$STEAMCMD_DIR/linux64/steamclient.so" "$home/.steam/sdk64/steamclient.so" 2>/dev/null || true
    ln -sf "$STEAMCMD_DIR/linux32/steamclient.so" "$home/.steam/sdk32/steamclient.so" 2>/dev/null || true

    # —— 关键：SteamCMD 会把创意工坊内容下载到 $HOME/Steam/steamapps/workshop/...
    #    这里把 $HOME/Steam 固定成指向持久化卷的符号链接，
    #    否则容器一旦被重建（docker compose down/up），几百 MB ~ 数 GB 的模组就要重下。 ——
    local steam_root="${home}/Steam" steam_target="${STEAMCMD_DIR}/Steam"
    if [ -L "$steam_root" ]; then
      log "模组缓存目录已指向持久化卷：$(readlink "$steam_root")"
    else
      if [ -d "$steam_root" ]; then
        log "将已存在的 ${steam_root} 迁移到持久化卷 ${steam_target}"
        mkdir -p "$steam_target"
        cp -a "$steam_root/." "$steam_target/" 2>/dev/null || true
        rm -rf "$steam_root"
      else
        mkdir -p "$steam_target"
      fi
      ln -s "$steam_target" "$steam_root" 2>/dev/null \
        || warn "无法创建 ${steam_root} 符号链接，模组缓存将无法跨容器重建保留"
    fi
  fi
  mkdir -p "$STEAMCMD_DIR/steamapps" 2>/dev/null || true
}

# 定位 SteamCMD 下载下来的创意工坊模组内容目录（不同 steamcmd 版本落地位置不同）
locate_mod_src() {
  local id="$1" d
  for d in "${HOME:-/root}/Steam/steamapps/workshop/content/${WORKSHOP_APP_ID}/${id}" \
           "${STEAMCMD_DIR}/Steam/steamapps/workshop/content/${WORKSHOP_APP_ID}/${id}" \
           "${STEAMCMD_DIR}/steamapps/workshop/content/${WORKSHOP_APP_ID}/${id}" \
           "/root/Steam/steamapps/workshop/content/${WORKSHOP_APP_ID}/${id}"; do
    if [ -d "$d" ]; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

# 生成 +login 参数：默认匿名；填了 STEAM_USER 就走真实账号
steam_login_args() {
  if [ -n "$STEAM_USER" ] && [ "$STEAM_USER" != "anonymous" ]; then
    printf '%s\n' "+login" "$STEAM_USER" "$STEAM_PASS"
  else
    printf '%s\n' "+login" "anonymous"
  fi
}

# SteamCMD 执行包装（带重试）
steamcmd_run() {
  local attempt=1 desc="$*"
  # 用了真实账号时，别把密码打进日志
  if [ -n "$STEAM_PASS" ]; then desc="${desc//"$STEAM_PASS"/***}"; fi
  while [ "$attempt" -le "$STEAMCMD_RETRIES" ]; do
    log "SteamCMD 执行（第 ${attempt}/${STEAMCMD_RETRIES} 次）：${desc}"
    if "$STEAMCMD_PATH" "$@"; then
      return 0
    fi
    warn "SteamCMD 执行失败，10 秒后重试…"
    attempt=$((attempt + 1))
    sleep 10
  done
  return 1
}

# Steam 可达性预检：只回答「现在跑 SteamCMD 有没有意义」，几秒内出结果。
# 为什么需要它：SteamCMD 在「连不上 Steam」时不会立刻失败 —— 每次要连吃 2 次
# 60 秒超时（等待客户端配置 / 查询 AppID），配合 STEAMCMD_RETRIES=3 就是 ≈7 分钟，
# 而这段等待整段都在容器启动路径上，表现成「up -d 之后服务端迟迟不出来」。
#   ① Steam WebAPI：SteamCMD 取 CM 服务器列表也走它，最准的一枪；
#   ② 极端情况下 WebAPI 被单独阻断、CM 端口却通，再补一次 TCP 探测。
# 返回 0 = 认为可达（继续正常更新）；1 = 不可达（调用方跳过本次更新）
steam_reachable() {
  local url="${STEAM_PROBE_URL:-https://api.steampowered.com/ISteamWebAPIUtil/GetServerInfo/v1/}"
  local h
  if command -v curl >/dev/null 2>&1; then
    # 故意不加 -f：这里只关心「连得上」，HTTP 状态码是什么都算可达
    curl -sS -m "${STEAM_PROBE_HTTP_TIMEOUT:-6}" -o /dev/null "$url" 2>/dev/null && return 0
  fi
  for h in ${STEAM_PROBE_HOSTS:-cm-01-scl1.cm.steampowered.com cm-02-scl1.cm.steampowered.com}; do
    timeout "${STEAM_PROBE_TCP_TIMEOUT:-3}" bash -c "exec 3<>/dev/tcp/${h}/443" 2>/dev/null && return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# 排障：把「判断权限问题还是网络问题」需要的东西一次性打全
#   SteamCMD 的 "Missing file permissions" 是个**会骗人**的报错，它有两个成因：
#     A. 数据目录在 Windows/网络挂载上，chmod 不生效（check_data_dirs 会拦住）
#     B. 与 Steam 的连接不稳（国内公网极常见），SteamCMD 却仍报这句
#   区分办法就在下面的输出里：
#     - /ark/steamapps 是否被创建：没创建 = 安装根本没走到下载阶段
#     - SteamCMD 自己的 console_log.txt 最后几行
# -----------------------------------------------------------------------------
dump_install_diag() {
  warn "安装失败，以下为排障信息（可直接复制反馈）："
  err  "  id            : $(id 2>/dev/null || echo 未知)"
  err  "  HOME          : ${HOME:-未设置}"
  err  "  ${ARK_SERVER_DIR} 文件系统 : $(stat -f -c %T "$ARK_SERVER_DIR" 2>/dev/null || echo 未知)  可写=$([ -w "$ARK_SERVER_DIR" ] && echo 是 || echo 否)"
  err  "  ${ARK_SERVER_DIR} 属主/权限 : $(ls -ld "$ARK_SERVER_DIR" 2>/dev/null || echo 未知)"
  err  "  ${STEAMCMD_DIR} 属主/权限 : $(ls -ld "$STEAMCMD_DIR" 2>/dev/null || echo 未知)"
  err  "  磁盘剩余      : $(df -h "$ARK_SERVER_DIR" 2>/dev/null | tail -n 1 || echo 未知)"
  err  "  steamapps     : $([ -d "${ARK_SERVER_DIR}/steamapps" ] && echo '已创建' || echo '未创建（安装没走到下载阶段，多半是 Steam 侧而非权限）')"
  err  "  代理          : HTTP_PROXY=${HTTP_PROXY:-（未设置）} HTTPS_PROXY=${HTTPS_PROXY:-（未设置）}"
  if [ -n "${HTTP_PROXY:-}" ] && [ -z "${PROXY_HTTP:-}" ] && [ -z "${PROXY_HTTPS:-}" ]; then
    err  "                  ↑ 但 .env 里 PROXY_HTTP/PROXY_HTTPS 为空 → 这是旧容器固化的代理值。"
    err  "                    改完 .env 只 restart、没重建：docker compose up -d --force-recreate"
  fi
  err  "  登录方式      : $([ -n "$STEAM_USER" ] && [ "$STEAM_USER" != anonymous ] && echo "Steam 账号 ${STEAM_USER}" || echo '匿名（anonymous）')"
  # 关于 app access token：匿名会话 0 received / N denied 是【正常现象】，
  # 下载正常进行时也会出现，不能当作故障判据。这里只作参考输出。
  local ailog="${STEAMCMD_DIR}/Steam/logs/appinfo_log.txt"
  if [ -f "$ailog" ]; then
    local denied
    denied="$(grep -E 'app access tokens' "$ailog" 2>/dev/null | tail -n 2 || true)"
    if [ -n "$denied" ]; then
      err "  app access token（仅供参考，匿名会话 0 received/N denied 属正常）："
      while IFS= read -r line; do err "    ${line}"; done <<< "$denied"
    fi
  fi
  local clog="${STEAMCMD_DIR}/linux32/logs/console_log.txt"
  if [ -f "$clog" ]; then
    err "  最近 SteamCMD 输出："
    while IFS= read -r line; do err "    ${line}"; done < <(tail -n 12 "$clog" 2>/dev/null || true)
  fi
  err  "  需要完整报告时执行：docker compose run --rm ark doctor"
}

# 安装 / 更新服务端本体
install_server() {
  local -a args=()
  if is_true "$STEAM_VALIDATE"; then args+=(validate); fi
  # 首次安装（还没有 steamapps）时自动带上 validate。方舟 376030 的社区惯例是
  # 「第一次安装必须加 validate」：不带时部分网络环境下 SteamCMD 会在"建立更新任务"
  # 阶段直接报 Missing file permissions / Missing configuration，一个字节都不下载。
  if [ ! -d "${ARK_SERVER_DIR}/steamapps" ] && ! is_true "$STEAM_VALIDATE"; then
    args+=(validate)
    log "检测到首次安装（${ARK_SERVER_DIR}/steamapps 不存在），本次自动追加 validate"
  fi
  log "安装/更新服务端（AppID=${APP_ID}）到 ${ARK_SERVER_DIR}"
  local -a login_args=()
  mapfile -t login_args < <(steam_login_args)
  if [ -n "$STEAM_USER" ] && [ "$STEAM_USER" != "anonymous" ]; then
    log "使用 Steam 账号 ${STEAM_USER} 登录（非匿名）"
  fi
  if steamcmd_run +force_install_dir "$ARK_SERVER_DIR" "${login_args[@]}" \
                  +app_update "$APP_ID" "${args[@]}" +quit; then
    ok "服务端就绪，buildid=$(server_version)"
    return 0
  fi
  # 已有可用文件时不要因为一次更新失败就拒绝启动
  if [ -x "$SERVER_BIN" ]; then
    warn "服务端更新失败（Steam 网络异常？），检测到已有服务端文件，继续启动"
    warn "如需强制修复文件完整性：STEAM_VALIDATE=true docker compose run --rm ark install"
    return 0
  fi
  dump_install_diag
  die "服务端安装失败（对外报 Missing file permissions / Missing configuration）。

  排查顺序（按命中概率从高到低）：

    1) 容器里挂着代理，而且代理不通 / 端口写错 —— 实测最常见的真因。
       SteamCMD 只是把「下载链路走不通」笼统报成了 Missing file permissions，
       与文件权限、磁盘、挂载统统无关。看上面排障信息里的「代理」一行：
         · 若显示了 HTTP_PROXY 但 .env 里 PROXY_HTTP/PROXY_HTTPS 是空的
           → 这是【旧容器固化的值】，你改完 .env 只 restart 没重建。执行：
                 docker compose up -d --force-recreate
           （环境变量在容器创建时固化，restart 不重读 .env，这是最隐蔽的坑）
         · 若确实要用代理：端口别写错，Clash Verge 默认是 7897（不是 7890）。
               在 .env 里填（不是 HTTP_PROXY，名字必须用 PROXY_*）：
                   PROXY_HTTP=http://host.docker.internal:7897
                   PROXY_HTTPS=http://host.docker.internal:7897
               然后 docker compose up -d --force-recreate
         · 若宿主机开着 Clash / Surge 的 TUN 或全局模式：容器出网已被 TUN 整体接管，
           这一层代理应当【留空】，叠加只会打架（TUN 的 fake-ip 会把
           host.docker.internal 解析成 198.18.x.x，容器根本连不上代理端口，
           表现是无限 'Connecting anonymously to Steam Public...Retrying...'）。
       ⚠ 别把 app access token 的 '0 received, N denied' 当判据 —— 匿名会话本来就拿不到
         那些令牌，下载正常时也会打印这行（已实测证伪）。

    2) 换个登录方式 —— 用真实 Steam 账号替代匿名：
           STEAM_USER=你的账号
           STEAM_PASS=你的密码
       （建议专门建个小号；密码只留在本机 .env）

    3) 数据目录不在 Linux 文件系统上 —— 本容器启动时已自检，通过了就排除这条。
       （自检不通过会直接退出，不会走到这里）

    4) SteamCMD 自身状态损坏 —— 删掉缓存重建一份：
           docker compose down
           mv \$HOME/ark-data/steamcmd \$HOME/ark-data/steamcmd.bak
           docker compose up -d --build

    5) 上面都无效 —— 跑隔离矩阵，把责任方钉死：
           bash tools/diag-steamcmd.sh
       它用官方 cm2network/steamcmd 镜像（非 root 用户）做对照。Valve 官方明确不建议
       以 root 运行 SteamCMD；若官方镜像也失败，说明与本项目无关，属网络/Steam 侧。

  查看完整环境自检：docker compose run --rm ark doctor"
}

server_version() {
  local f="${ARK_SERVER_DIR}/steamapps/appmanifest_${APP_ID}.acf"
  if [ -f "$f" ]; then
    grep -oE '"buildid"[[:space:]]+"[0-9]+"' "$f" | head -n1 | grep -oE '[0-9]+' || echo "未知"
  else
    echo "未知"
  fi
}

# 解析模组列表：去空格、去重、校验纯数字
build_mod_list() {
  local raw=""
  MODS="${MODS%%#*}"; EXTRA_MODS="${EXTRA_MODS%%#*}"; DEFAULT_MODS="${DEFAULT_MODS%%#*}"
  if [ -n "${MODS// /}" ]; then
    raw="$MODS"
    log "检测到 MODS 变量，使用完全自定义模组列表（默认模组与 EXTRA_MODS 将被忽略）"
  else
    if is_true "$ENABLE_DEFAULT_MODS"; then
      raw="$DEFAULT_MODS"
    else
      warn "ENABLE_DEFAULT_MODS=false，本次不加载默认模组（叠加 / 野人模组 / A镜）"
    fi
    if [ -n "${EXTRA_MODS// /}" ]; then
      raw="${raw:+${raw},}${EXTRA_MODS}"
    fi
  fi

  raw="$(printf '%s' "$raw" | tr ' ' ',' | tr -s ',')"
  ACTIVE_MOD_ARRAY=()
  local id seen=","
  local -a _ids=()
  if [ -n "$raw" ]; then
    IFS=',' read -r -a _ids <<< "$raw" || true
  fi
  if [ "${#_ids[@]}" -gt 0 ]; then
    for id in "${_ids[@]}"; do
      id="$(printf '%s' "$id" | tr -d '[:space:]')"
      [ -z "$id" ] && continue
      if ! printf '%s' "$id" | grep -qE '^[0-9]+$'; then
        warn "模组 ID「${id}」不是纯数字，已跳过（正确格式：steamcommunity.com/sharedfiles/filedetails/?id=XXXXXXXX）"
        continue
      fi
      case "$seen" in *",${id},"*) log "模组 ${id} 重复，已去重" ;; *)
        seen="${seen}${id},"; ACTIVE_MOD_ARRAY+=("$id") ;; esac
    done
  fi

  if [ "${#ACTIVE_MOD_ARRAY[@]}" -gt 0 ]; then
    ACTIVE_MODS="$(IFS=','; echo "${ACTIVE_MOD_ARRAY[*]}")"
  else
    ACTIVE_MODS=""
  fi
}

# 下载并挂接模组
install_mods() {
  if [ -z "$ACTIVE_MODS" ]; then
    log "未配置任何模组，跳过模组下载"
    return 0
  fi
  log "需要处理的模组：${ACTIVE_MODS}"
  local id src dst
  for id in "${ACTIVE_MOD_ARRAY[@]}"; do
    if src="$(locate_mod_src "$id")" && ! is_true "$MOD_UPDATE"; then
      log "模组 ${id} 已存在（${src}），MOD_UPDATE=false 跳过更新"
    else
      log "下载/更新模组 ${id} …（大型模组可能几百 MB ~ 数 GB，首次下载请耐心等待）"
      local -a mod_login=()
      mapfile -t mod_login < <(steam_login_args)
      steamcmd_run "${mod_login[@]}" +workshop_download_item "$WORKSHOP_APP_ID" "$id" validate +quit \
        || warn "模组 ${id} 下载失败（可能是体积大导致网络超时、已下架或需要登录），稍后重试或改用 MODS 精简列表"
    fi

    dst="${MODS_DIR}/${id}"
    if ! src="$(locate_mod_src "$id")"; then
      warn "模组 ${id} 未下载成功，服务端启动时会尝试自动补下（-automanagedmods）"
      continue
    fi
    log "模组 ${id} 来源：${src}"

    # 先装到临时目录，确认完整后再原子替换；避免半成品目录导致模组加载失败
    tmp="${MODS_DIR}/.installing_${id}"
    rm -rf "$tmp" "$dst.disabled" 2>/dev/null || true
    local mode="${MOD_LINK_MODE:-auto}" label="" deployed=0
    case "$mode" in
      symlink)
        label="符号链接"
        ln -s "$src" "$tmp" 2>/dev/null && deployed=1 ;;
      copy)
        label="复制"
        cp -a "$src" "$tmp" 2>/dev/null && deployed=1 ;;
      *)
        # auto：同卷用硬链接（零额外占用），跨卷直接复制
        if [ "$(stat -c %d "$src" 2>/dev/null)" = "$(stat -c %d "$MODS_DIR" 2>/dev/null)" ] \
           && cp -al "$src" "$tmp" 2>/dev/null; then
          label="硬链接"
          deployed=1
        else
          rm -rf "$tmp"
          label="复制"
          cp -a "$src" "$tmp" 2>/dev/null && deployed=1
        fi ;;
    esac

    if [ "$deployed" = "1" ] && [ -e "$tmp" ]; then
      rm -rf "$dst"
      if mv "$tmp" "$dst" 2>/dev/null; then
        ok "模组 ${id} 已就绪（${label}）-> ${dst}"
      else
        rm -rf "$tmp"; warn "模组 ${id} 部署到 ${dst} 失败"
      fi
    else
      rm -rf "$tmp"
      warn "模组 ${id} 部署失败（磁盘空间或权限不足？）"
    fi
  done
}

# =============================================================================
#  配置生成
# =============================================================================

# 把 override 文件按「键」合并进主配置：
#   - 同名键：直接覆盖主配置中的值
#   - 新键：追加到对应小节末尾（缺少的小节自动创建）
# 这样即使 ARK 的 INI 解析不是简单的「后者优先」，覆盖也一定生效。
merge_ini() {
  local base="$1" override="$2"
  [ -s "$override" ] || { cat "$base"; return 0; }

  awk '
    function trim(s) { gsub(/^[ \t\r]+/, "", s); gsub(/[ \t\r]+$/, "", s); return s }
    function section_of(key,   p) { p = index(key, SUBSEP); return substr(key, 1, p - 1) }
    # 一个 base 小节结束时，把该小节里「base 原本没有」的覆盖键补在小节末尾
    function flush_pending(   i, key) {
      if (bcur == "") return
      bsections[bcur] = 1
      for (i = 1; i <= ovn; i++) {
        key = ovorder[i]
        if (section_of(key) != bcur) continue
        if (key in done) continue
        print ov[key]
        done[key] = 1
      }
      bcur = ""
    }
    # ---------- 第一遍：读 override（file 1）----------
    FNR == NR {
      line = $0; sub(/\r$/, "", line)
      t = trim(line)
      if (t == "" || t ~ /^[;#]/) next
      if (t ~ /^\[/) { ocur = t; next }
      if (ocur == "") next
      p = index(t, "=")
      if (p < 2) next
      k = trim(substr(t, 1, p - 1))
      key = ocur SUBSEP k
      if (!(key in ov)) ovorder[++ovn] = key
      ov[key] = line
      next
    }
    # ---------- 第二遍：读 base（file 2）----------
    {
      if (!bstarted) { bstarted = 1; bcur = "" }
      line = $0
      t = trim(line)
      if (t ~ /^\[/) {
        flush_pending()
        bcur = t
        print line
        next
      }
      if (bcur != "" && t !~ /^[;#]/) {
        p = index(t, "=")
        if (p >= 2) {
          key = bcur SUBSEP trim(substr(t, 1, p - 1))
          if (key in ov) { print ov[key]; done[key] = 1; next }
        }
      }
      print line
      next
    }
    END {
      flush_pending()
      # base 里完全不存在的小节：追加到文件末尾
      for (i = 1; i <= ovn; i++) {
        key = ovorder[i]
        if (key in done) continue
        s = section_of(key)
        if (!(s in bsections)) { print ""; print s; bsections[s] = 1 }
        print ov[key]
        done[key] = 1
      }
    }
  ' "$override" "$base"
}

# 生成 GameUserSettings.ini
write_game_user_settings() {
  local tmp; tmp="$(mktemp)"
  {
    printf '[ServerSettings]\n'
    printf 'SessionName=%s\n' "$SESSION_NAME"
    printf 'ServerPassword=%s\n' "$SERVER_PASSWORD"
    printf 'ServerAdminPassword=%s\n' "$SERVER_ADMIN_PASSWORD"
    printf 'Port=%s\n' "$PORT"
    printf 'QueryPort=%s\n' "$QUERY_PORT"
    printf 'RCONEnabled=%s\n' "$(is_true "$RCON_ENABLED" && echo True || echo False)"
    printf 'RCONPort=%s\n' "$RCON_PORT"
    printf 'MaxPlayers=%s\n' "$MAX_PLAYERS"
    printf 'ServerPVE=%s\n' "$(is_true "$SERVER_PVE" && echo True || echo False)"
    printf 'ServerHardcore=%s\n' "$(is_true "$SERVER_HARDCORE" && echo True || echo False)"
    printf 'DifficultyOffset=%s\n' "$DIFFICULTY_OFFSET"
    printf 'OverrideOfficialDifficulty=%s\n' "$OVERRIDE_OFFICIAL_DIFFICULTY"
    [ -n "$MAX_TAMED_DINOS" ] && printf 'MaxTamedDinos=%s\n' "$MAX_TAMED_DINOS"
    printf 'AutoSavePeriodMinutes=%s\n' "$AUTO_SAVE_PERIOD_MINUTES"
    printf 'KickIdlePlayersPeriod=%s\n' "$KICK_IDLE_PLAYERS_PERIOD"
    printf 'AllowThirdPersonPlayer=%s\n' "$(is_true "$ALLOW_THIRD_PERSON" && echo True || echo False)"
    printf 'ShowMapPlayerLocation=%s\n' "$(is_true "$SHOW_MAP_PLAYER_LOCATION" && echo True || echo False)"
    printf 'AllowFlyerCarryPvE=%s\n' "$(is_true "$ALLOW_FLYER_CARRY_PVE" && echo True || echo False)"
    printf 'DisableStructureDecayPvE=%s\n' "$(is_true "$DISABLE_STRUCTURE_DECAY_PVE" && echo True || echo False)"
    printf 'ServerCrosshair=%s\n' "$(is_true "$SERVER_CROSSHAIR" && echo True || echo False)"
    printf 'ShowFloatingDamageText=%s\n' "$(is_true "$SHOW_FLOATING_DAMAGE_TEXT" && echo True || echo False)"
    printf 'AllowHitMarkers=%s\n' "$(is_true "$ALLOW_HIT_MARKERS" && echo True || echo False)"
    printf '\n'
    printf '; ---------------------------------------------------------------------------\n'
    printf '; ⚠ 倍率类设置【不写在本文件里】。\n'
    printf ';   服务端启动时会用自己认识的那批 [ServerSettings] 键重写 GameUserSettings.ini，\n'
    printf ';   上面这些 XPMultiplier / HarvestAmountMultiplier / ... 不在其中，会被整行丢弃。\n'
    printf ';   它们的写入位置是 Game.ini 的 [/script/shootergame.shootergamemode]，见 README FAQ 21。\n'
    printf '; ---------------------------------------------------------------------------\n'
    printf '\n[/Script/Engine.GameSession]\n'
    printf 'MaxPlayers=%s\n' "$MAX_PLAYERS"
  } > "$tmp"

  merge_ini "$tmp" "${USER_CONFIG_DIR}/GameUserSettings.ini.extra" > "$CONFIG_DIR/GameUserSettings.ini"
  rm -f "$tmp"
  ok "已生成 ${CONFIG_DIR}/GameUserSettings.ini"
}

# 生成 Game.ini
write_game_ini() {
  local tmp; tmp="$(mktemp)"
  {
    printf '[/script/shootergame.shootergamemode]\n'
    printf '; bUseSingleplayerSettings=True 会启用单机模式加成（属性成长更快）\n'
    printf 'bUseSingleplayerSettings=%s\n' "$(is_true "$USE_SINGLEPLAYER_SETTINGS" && echo True || echo False)"
    printf '\n'
    printf '; ---------- 负重：每级属性点加成倍率（索引 7 = 负重 Weight）----------\n'
    printf 'PerLevelStatsMultiplier_Player[7]=%s\n' "$PLAYER_WEIGHT_PER_LEVEL_MULTIPLIER"
    printf 'PerLevelStatsMultiplier_DinoTamed[7]=%s\n' "$DINO_WEIGHT_PER_LEVEL_MULTIPLIER"
    printf '\n'
    printf '; ==========================================================================\n'
    printf ';  倍率设置（由 .env 注入）\n'
    printf ';  ⚠ 为什么全在这里、而不是 GameUserSettings.ini 的 [ServerSettings]：\n'
    printf ';    服务端启动时会用自己认识的 [ServerSettings] 键整体重写 GameUserSettings.ini，\n'
    printf ';    不认识的键（本段几乎全部）会被整行丢弃 —— 表现为 .env 改了没有任何反应。\n'
    printf ';    [/script/shootergame.shootergamemode] 里的同名键才是生效位置。详见 README FAQ 21。\n'
    printf ';  ⚠ 本段与 .env 一一对应，想改倍率请改 .env（改本文件会在下次启动被覆盖）。\n'
    printf '; ==========================================================================\n'
    printf '\n'
    printf '; ---------- 经验 ----------\n'
    printf 'XPMultiplier=%s\n' "$XP_MULTIPLIER"
    printf '\n'
    printf '; ---------- 驯养 / 繁殖 / 孵化 ----------\n'
    printf 'TamingSpeedMultiplier=%s\n' "$TAMING_SPEED_MULTIPLIER"
    printf 'EggHatchSpeedMultiplier=%s\n' "$EGG_HATCH_SPEED_MULTIPLIER"
    printf 'BabyMatureSpeedMultiplier=%s\n' "$BABY_MATURE_SPEED_MULTIPLIER"
    printf 'MatingIntervalMultiplier=%s\n' "$MATING_INTERVAL_MULTIPLIER"
    printf 'MatingSpeedMultiplier=%s\n' "$MATING_SPEED_MULTIPLIER"
    printf 'LayEggIntervalMultiplier=%s\n' "$LAY_EGG_INTERVAL_MULTIPLIER"
    printf 'BabyImprintingStatScaleMultiplier=%s\n' "$BABY_IMPRINTING_STAT_SCALE_MULTIPLIER"
    printf 'BabyFoodConsumptionSpeedMultiplier=%s\n' "$BABY_FOOD_CONSUMPTION_SPEED_MULTIPLIER"
    printf '\n'
    printf '; ---------- 采集 / 掉落 / 生长 / 刷新 ----------\n'
    printf 'HarvestAmountMultiplier=%s\n' "$HARVEST_AMOUNT_MULTIPLIER"
    printf 'HarvestHealthMultiplier=%s\n' "$HARVEST_HEALTH_MULTIPLIER"
    printf 'LootQualityMultiplier=%s\n' "$LOOT_QUALITY_MULTIPLIER"
    printf 'CropGrowthSpeedMultiplier=%s\n' "$CROP_GROWTH_SPEED_MULTIPLIER"
    printf 'DinoCountMultiplier=%s\n' "$DINO_COUNT_MULTIPLIER"
    printf '\n'
    printf '; ---------- 负重 / 消耗 / 恢复 ----------\n'
    printf 'ItemWeightMultiplier=%s\n' "$ITEM_WEIGHT_MULTIPLIER"
    printf 'DinoCharacterFoodDrainMultiplier=%s\n' "$DINO_FOOD_DRAIN_MULTIPLIER"
    printf 'DinoCharacterStaminaDrainMultiplier=%s\n' "$DINO_STAMINA_DRAIN_MULTIPLIER"
    printf 'DinoCharacterHealthRecoveryMultiplier=%s\n' "$DINO_HEALTH_RECOVERY_MULTIPLIER"
    printf 'PlayerCharacterFoodDrainMultiplier=%s\n' "$PLAYER_FOOD_DRAIN_MULTIPLIER"
    printf 'PlayerCharacterWaterDrainMultiplier=%s\n' "$PLAYER_WATER_DRAIN_MULTIPLIER"
    printf 'PoopIntervalMultiplier=%s\n' "$POOP_INTERVAL_MULTIPLIER"
    printf 'FuelConsumptionIntervalMultiplier=%s\n' "$FUEL_CONSUMPTION_INTERVAL_MULTIPLIER"
  } > "$tmp"

  merge_ini "$tmp" "${USER_CONFIG_DIR}/Game.ini.extra" > "$CONFIG_DIR/Game.ini"
  rm -f "$tmp"
  ok "已生成 ${CONFIG_DIR}/Game.ini"
}

# 按时间倒序保留最近 N 个文件，其余删除（可移植写法，不依赖 GNU xargs）
prune_old() {
  local pattern="$1" keep="${2:-10}" i=0 f
  while IFS= read -r f; do
    i=$((i + 1))
    [ "$i" -gt "$keep" ] && rm -f "$f"
  done < <(ls -1t $pattern 2>/dev/null || true)
  return 0
}

backup_configs() {
  is_true "$CONFIG_BACKUP" || return 0
  local ts f
  ts="$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "${BACKUP_DIR}/config"
  for f in GameUserSettings.ini Game.ini; do
    if [ -f "${CONFIG_DIR}/${f}" ]; then
      cp "${CONFIG_DIR}/${f}" "${BACKUP_DIR}/config/${f}.${ts}.bak"
    fi
  done
  prune_old "${BACKUP_DIR}/config/GameUserSettings.ini.*.bak" 5
  prune_old "${BACKUP_DIR}/config/Game.ini.*.bak" 5
}

render_configs() {
  ensure_dirs
  normalize_numbers
  if ! is_true "$CONFIG_REGENERATE"; then
    if [ -f "${CONFIG_DIR}/GameUserSettings.ini" ] && [ -f "${CONFIG_DIR}/Game.ini" ]; then
      warn "CONFIG_REGENERATE=false，跳过配置生成（沿用现有配置，适合手动改过 ini 的场景）"
      return 0
    fi
    warn "现有配置不存在，即使 CONFIG_REGENERATE=false 也会生成一次默认配置"
  fi
  backup_configs
  write_game_user_settings
  write_game_ini

  if [ -f "${USER_CONFIG_DIR}/GameUserSettings.ini.extra" ]; then
    log "已合并自定义覆盖文件：${USER_CONFIG_DIR}/GameUserSettings.ini.extra"
  fi
  if [ -f "${USER_CONFIG_DIR}/Game.ini.extra" ]; then
    log "已合并自定义覆盖文件：${USER_CONFIG_DIR}/Game.ini.extra"
  fi
}

# =============================================================================
#  备份 / 恢复
# =============================================================================
do_backup() {
  [ -d "$SAVED_DIR" ] || die "存档目录不存在：${SAVED_DIR}"
  mkdir -p "$BACKUP_DIR"
  local ts name
  ts="$(date '+%Y%m%d-%H%M%S')"
  name="${BACKUP_DIR}/ark-saved-${ts}.tar.gz"
  log "正在备份存档 -> ${name}"
  tar -czf "$name" -C "${ARK_SERVER_DIR}/ShooterGame" Saved || die "备份失败"
  ok "备份完成：$(du -h "$name" | cut -f1)  ${name}"
  prune_old "${BACKUP_DIR}/ark-saved-*.tar.gz" "$BACKUP_KEEP"
  log "当前保留的备份（最多 ${BACKUP_KEEP} 份）："
  ls -lht "${BACKUP_DIR}"/ark-saved-*.tar.gz 2>/dev/null | head -n "$BACKUP_KEEP" || true
}

do_restore() {
  local file="$1"
  [ -n "$file" ] || die "用法：restore <备份文件名或路径>"
  [ -f "$file" ] || file="${BACKUP_DIR}/${file}"
  [ -f "$file" ] || die "找不到备份文件：$file"
  log "正在从 ${file} 恢复存档…"
  tar -xzf "$file" -C "${ARK_SERVER_DIR}/ShooterGame" || die "恢复失败"
  ok "恢复完成，请重启服务器容器"
}

# =============================================================================
#  环境自检（排障）
# =============================================================================
doctor() {
  local d
  echo "────────────────────────────────────────────────────────────"
  echo " 容器环境自检"
  echo "────────────────────────────────────────────────────────────"
  echo "身份          : $(id 2>/dev/null || echo 未知)"  echo "HOME          : ${HOME:-未设置}"
  echo "内核          : $(uname -srm 2>/dev/null || echo 未知)"
  echo "目录挂载      :"
  for d in "$ARK_SERVER_DIR" "$STEAMCMD_DIR" "$BACKUP_DIR" "$USER_CONFIG_DIR"; do
    printf '  %-16s %s\n' "$d" "$(ls -ld "$d" 2>/dev/null || echo '不存在')"
    printf '  %-16s 文件系统=%s  可写=%s\n' "" \
      "$(stat -f -c %T "$d" 2>/dev/null || echo 未知)" \
      "$([ -w "$d" ] && echo 是 || echo 否)"
  done
  echo "磁盘空间      :"
  df -h "$ARK_SERVER_DIR" "$STEAMCMD_DIR" 2>/dev/null | sed 's/^/  /' || true
  echo "inode 余量    :"
  df -i "$ARK_SERVER_DIR" 2>/dev/null | sed 's/^/  /' || true
  echo "代理          : HTTP_PROXY=${HTTP_PROXY:-（未设置）}"
  echo "                HTTPS_PROXY=${HTTPS_PROXY:-（未设置）}  NO_PROXY=${NO_PROXY:-（未设置）}"
  if [ -n "${HTTP_PROXY:-}" ]; then
    echo "                ⚠ 容器出网走代理。若 .env 里 PROXY_HTTP/PROXY_HTTPS 已留空而这里仍有值，"
    echo "                  说明容器没重建（只 restart、不重读 .env）→ docker compose up -d --force-recreate"
    echo "                  代理端口写错或不可达时，SteamCMD 会报 Missing file permissions，与文件权限无关。"
  fi
  echo "SteamCMD      : ${STEAMCMD_PATH} $([ -x "$STEAMCMD_PATH" ] && echo '(可执行)' || echo '(缺失或不可执行)')"
  echo "服务端        : $([ -x "$SERVER_BIN" ] && echo "已安装 buildid=$(server_version)" || echo '未安装')"
  echo "steamapps     : $([ -d "${ARK_SERVER_DIR}/steamapps" ] && echo '已创建' || echo '未创建 → 安装没走到下载阶段，问题在 Steam 侧而非文件权限')"
  echo "数据目录内容  :"
  ls -la "$ARK_SERVER_DIR" 2>/dev/null | sed 's/^/  /' | head -n 20 || true
  echo "SteamCMD 日志 : $(ls -1t "${STEAMCMD_DIR}/linux32/logs" 2>/dev/null | tr '\n' ' ' || echo '（无）')"
  echo "────────────────────────────────────────────────────────────"
  echo " Steam 侧连通性（反映能否取到 Steam 的内容服务器配置）"
  local _u
  for _u in https://steamcdn-a.akamaihd.net/ \
            https://api.steampowered.com/ISteamWebAPIUtil/GetServerInfo/v1/ \
            https://store.steampowered.com/; do
    printf '  %-56s %s\n' "$_u" \
      "$(curl -s -o /dev/null -m 8 -w 'http=%{http_code} 用时=%{time_total}s' "$_u" 2>/dev/null || echo '失败或超时')"
  done
  local _c="${STEAMCMD_DIR}/linux32/logs/console_log.txt"
  if [ -f "$_c" ]; then
    echo " console_log.txt 末尾（安装失败点就在这里）："
    tail -n 8 "$_c" 2>/dev/null | sed 's/^/   /' || true
  fi
  local _f _p
  for _f in appinfo_log configstore_log; do
    _p="${STEAMCMD_DIR}/Steam/logs/${_f}.txt"
    if [ -f "$_p" ]; then
      echo " ${_f}.txt 末尾："
      tail -n 3 "$_p" 2>/dev/null | sed 's/^/   /' || true
    fi
  done
  # 关于 app access token：匿名会话拿不到大多数 App 的令牌，
  # appinfo_log 里出现 "0 received, N denied" 是【正常现象】，下载照样能进行，
  # 不要据它下判断。（曾经误把这条当根因，实测已证伪。）
  local _ai="${STEAMCMD_DIR}/Steam/logs/appinfo_log.txt"
  if [ -f "$_ai" ]; then
    local _den
    _den="$(grep -E 'app access tokens' "$_ai" 2>/dev/null | tail -n 2 || true)"
    if [ -n "$_den" ]; then
      echo " app access token（仅供参考：匿名会话 0 received/N denied 属正常，非故障判据）："
      while IFS= read -r _l; do echo "   ${_l}"; done <<< "$_den"
    fi
  fi
  echo "────────────────────────────────────────────────────────────"
  echo "值：check 全绿却仍报 Missing file permissions / Missing configuration 时，"
  echo "       看上面 console_log 末尾是否停在 'Waiting for user info...OK' —— 那说明卡在"
  echo "       「取内容服务器配置 / 建立更新任务」，是链路问题而非文件权限。"
  echo "       · 先看「代理」那一行：容器里若还挂着代理，就是它 —— 尤其 .env 已留空却仍有值"
  echo "         （旧容器固化的），务必 docker compose up -d --force-recreate"
  echo "       · app access token 那行的 0 received/N denied 是匿名会话的正常现象，别被它带偏"
  echo "       · 确定要配容器内代理时，端口别写错（Clash Verge 默认 7897 而非 7890），"
  echo "         且 compose 已声明 host.docker.internal:host-gateway，否则名字会被解析成假 IP。"
  echo "       详细判定与矩阵：bash tools/diag-steamcmd.sh（见 README FAQ 15）"
  echo "────────────────────────────────────────────────────────────"
}

# =============================================================================
#  启动服务端
# =============================================================================
print_summary() {
  cat <<EOF
────────────────────────────────────────────────────────────
 方舟：生存进化 专用服务器
────────────────────────────────────────────────────────────
 地图            : ${MAP}
 会话名称        : ${SESSION_NAME}
 玩家上限        : ${MAX_PLAYERS}
 游戏端口(UDP)   : ${PORT}      查询端口(UDP): ${QUERY_PORT}
 RCON            : $(is_true "$RCON_ENABLED" && echo "${RCON_PORT}/TCP 已启用" || echo "已关闭")
 服务器密码      : $([ -n "$SERVER_PASSWORD" ] && echo "已设置" || echo "无（公开）")
 管理员密码      : $([ -n "$SERVER_ADMIN_PASSWORD" ] && echo "已设置" || echo "⚠ 未设置，无法使用管理员指令")
 游戏模式        : $(is_true "$SERVER_PVE" && echo "PvE（玩家/建筑之间不可互相伤害）" || echo "PvP")
 伤害数值显示    : $(is_true "$SHOW_FLOATING_DAMAGE_TEXT" && echo "开（命中时飘伤害数字）" || echo "关")
 难度            : 偏移 ${DIFFICULTY_OFFSET} × 覆盖 ${OVERRIDE_OFFICIAL_DIFFICULTY}
 模组数量        : ${#ACTIVE_MOD_ARRAY[@]}
 模组列表        : ${ACTIVE_MODS:-无}
 负重(玩家/恐龙) : ${PLAYER_WEIGHT_PER_LEVEL_MULTIPLIER} / ${DINO_WEIGHT_PER_LEVEL_MULTIPLIER} 倍（每级）
 驯养速度        : ${TAMING_SPEED_MULTIPLIER} 倍
 孵化速度        : ${EGG_HATCH_SPEED_MULTIPLIER} 倍
 幼体成长速度    : ${BABY_MATURE_SPEED_MULTIPLIER} 倍
 采集倍率        : ${HARVEST_AMOUNT_MULTIPLIER} 倍
 经验倍率        : ${XP_MULTIPLIER} 倍
────────────────────────────────────────────────────────────
EOF
}

graceful_stop() {
  [ -n "$SERVER_PID" ] || return 0
  kill -0 "$SERVER_PID" 2>/dev/null || return 0
  warn "收到停止信号，向服务端发送 SIGINT（触发保存世界并优雅退出）…"
  kill -INT "$SERVER_PID" 2>/dev/null || true
  local waited=0
  while kill -0 "$SERVER_PID" 2>/dev/null && [ "$waited" -lt "$STOP_TIMEOUT" ]; do
    sleep 1; waited=$((waited + 1))
    [ $((waited % 15)) -eq 0 ] && log "等待世界保存中… 已等待 ${waited}s / ${STOP_TIMEOUT}s"
  done
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    warn "优雅退出超时，发送 SIGTERM"
    kill -TERM "$SERVER_PID" 2>/dev/null || true
    sleep 5
  fi
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    warn "进程未退出，强制结束（存档可能有少量回档）"
    kill -KILL "$SERVER_PID" 2>/dev/null || true
  fi
  ok "服务端已停止"
}

launch_server() {
  [ -x "$SERVER_BIN" ] || die "未找到服务端程序：${SERVER_BIN}，请先执行 install 子命令"

  # 会话名中的 ? & = 会破坏 URL 参数解析，直接剔除
  local safe_name="${SESSION_NAME//[\?\&\=]/}"
  if [ "$safe_name" != "$SESSION_NAME" ]; then
    warn "会话名称中不能包含 ? & = 这三个字符，已自动移除"
  fi

  local url="${MAP}?listen?SessionName=${safe_name}"
  url+="?Port=${PORT}?QueryPort=${QUERY_PORT}?MaxPlayers=${MAX_PLAYERS}"
  [ -n "$SERVER_PASSWORD" ] && url+="?ServerPassword=${SERVER_PASSWORD}"
  [ -n "$SERVER_ADMIN_PASSWORD" ] && url+="?ServerAdminPassword=${SERVER_ADMIN_PASSWORD}"
  is_true "$RCON_ENABLED" && url+="?RCONEnabled=True?RCONPort=${RCON_PORT}"
  [ -n "$ALT_SAVE_DIR_NAME" ] && url+="?AltSaveDirectoryName=${ALT_SAVE_DIR_NAME}"

  # ---------------------------------------------------------------------------
  # 玩法开关：必须拼在命令行上，写 ini 是【无效】的
  #
  # ⚠⚠ 这是踩过坑之后才搞明白的一条硬规则，别再把这些挪回 ini：
  #   ASE 服务端启动时，会用内置的默认模板【整体重写】GameUserSettings.ini，
  #   只保留它自己绑定为 config 属性的键（ServerCrosshair、AllowThirdPersonPlayer、
  #   ShowMapPlayerLocation、AllowHitMarkers、AutoSavePeriodMinutes、RCON*、
  #   ServerAdminPassword 等 —— 这些我们仍写在 ini 里，作为兜底）。
  #   而 ServerPVE / ServerHardcore / ShowFloatingDamageText / DifficultyOffset /
  #   OverrideOfficialDifficulty / AllowFlyerCarryPvE / DisableStructureDecayPvE
  #   这些【会话级】选项不在其中，重写时会被整行丢掉。
  #
  #   实测证据（2026-09-13）：启动前 GameUserSettings.ini 里确实写着 ServerPVE=True，
  #   服务端起来后该行消失、文件被换成 33 KB 的默认模板，游戏里仍是 PvP
  #   （死亡后出现 PvP 重复死亡的重生倒计时）；同理 ShowFloatingDamageText 丢失
  #   → 游戏内不显示伤害数值，OverrideOfficialDifficulty=5.0 丢失
  #   → 野生生物等级上不去。
  #   → 结论：这些设置唯一的可靠入口是命令行 URL，ini 里那几行只是摆设。
  #
  #   大小写有讲究：ShowFloatingDamageText 社区实测必须是小写 true，
  #   写成 True 有概率不生效；其余沿用 ARK 惯用的 True/False。
  # ---------------------------------------------------------------------------
  url+="?ServerPVE=$(is_true "$SERVER_PVE" && echo True || echo False)"
  url+="?ServerHardcore=$(is_true "$SERVER_HARDCORE" && echo True || echo False)"
  url+="?ShowFloatingDamageText=$(is_true "$SHOW_FLOATING_DAMAGE_TEXT" && echo true || echo false)"
  url+="?AllowHitMarkers=$(is_true "$ALLOW_HIT_MARKERS" && echo True || echo False)"
  url+="?AllowFlyerCarryPvE=$(is_true "$ALLOW_FLYER_CARRY_PVE" && echo True || echo False)"
  url+="?DisableStructureDecayPvE=$(is_true "$DISABLE_STRUCTURE_DECAY_PVE" && echo True || echo False)"
  url+="?DifficultyOffset=${DIFFICULTY_OFFSET}"
  url+="?OverrideOfficialDifficulty=${OVERRIDE_OFFICIAL_DIFFICULTY}"
  # 兜底逃生口：想加别的命令行设置（且不想重建镜像）时用 .env 的 EXTRA_URL_ARGS
  if [ -n "$EXTRA_URL_ARGS" ]; then
    local _extra_url="$EXTRA_URL_ARGS"
    _extra_url="${_extra_url#\?}"   # 开头带 ? 或 & 都容错
    _extra_url="${_extra_url#&}"
    [ -n "$_extra_url" ] && url+="?${_extra_url}"
  fi

  local -a args=("$url" "-server" "-log" "-automanagedmods")
  [ -n "$ACTIVE_MODS" ] && args+=("-mods=${ACTIVE_MODS}")
  is_true "$BATTLEYE_ENABLED" || args+=("-NoBattlEye")
  if [ -n "$CLUSTER_ID" ]; then
    args+=("-clusterid=${CLUSTER_ID}" "-ClusterDirOverride=${CLUSTER_DIR_OVERRIDE}" "-NoTransferFromFiltering")
  fi
  if [ -n "$EXTRA_ARGS" ]; then
    local -a _extra=(); read -r -a _extra <<< "$EXTRA_ARGS"
    args+=("${_extra[@]}")
  fi

  print_summary
  log "启动命令："
  printf '  %s %s\n' "$SERVER_BIN" "${args[*]}"
  echo

  cd "$ARK_SERVER_DIR"
  trap 'graceful_stop; exit 0' TERM INT
  "$SERVER_BIN" "${args[@]}" &
  SERVER_PID=$!
  log "服务端进程 PID=${SERVER_PID}，日志输出中…（首次启动需要加载大量资源，请耐心等待）"

  local rc=0
  while :; do
    wait "$SERVER_PID" || rc=$?
    kill -0 "$SERVER_PID" 2>/dev/null || break
  done
  [ "$rc" -eq 0 ] && ok "服务端已正常退出" || warn "服务端退出，返回码 ${rc}（139=段错误，1=参数/文件错误，请查看上方日志）"
  return "$rc"
}

# =============================================================================
#  主流程
# =============================================================================
do_start() {
  ensure_dirs
  warn_if_proxy
  build_mod_list
  render_configs

  # 更新前置检查：Steam 不可达时别让启动白等（详见 steam_reachable 的注释）
  #   探得到 → 正常更新
  #   探不到 + 服务端已在本地 → 跳过本次更新直接启动（几秒进入加载）
  #   探不到 + 服务端还没装 → 仍然真跑一次：install_server 失败时会给出完整排障信息，
  #                            比无声跳过有用得多
  local skip_update=""
  if is_true "$SKIP_INSTALL_ON_START"; then
    warn "SKIP_INSTALL_ON_START=true，跳过服务端与模组更新"
    skip_update="1"
  elif is_true "$STEAM_PRECHECK" && [ -x "$SERVER_BIN" ] \
       && { is_true "$AUTO_UPDATE" || is_true "$MOD_UPDATE"; }; then
    if steam_reachable; then
      log "Steam 预检通过，继续检查服务端/模组更新"
    else
      skip_update="1"
      warn "Steam 预检不通：本容器现在连不上 Steam（多为直连被阻断 / 代理对容器无效）"
      warn "  已跳过本次服务端与模组更新，直接启动 —— 省掉约 7 分钟的必败重试"
      warn "  · 想强制更新一次： docker compose run --rm ark install"
      warn "  · 让容器也能走代理：① 打开代理软件的 TUN 模式（网络层接管，推荐）"
      warn "                      ② 或在 .env 里配 PROXY_HTTP / PROXY_HTTPS 指向宿主机代理"
      warn "  · 完整自检：       docker compose run --rm ark doctor"
    fi
  fi

  if [ -z "$skip_update" ]; then
    ensure_steamcmd
    if [ ! -x "$SERVER_BIN" ] || is_true "$AUTO_UPDATE"; then
      install_server
    else
      log "服务端已存在（buildid=$(server_version)），AUTO_UPDATE=false 跳过更新"
    fi
    install_mods
  fi

  launch_server
}

main() {
  local cmd="${1:-start}"
  case "$cmd" in
    start)   do_start ;;
    install|update)
      ensure_dirs; warn_if_proxy; build_mod_list; ensure_steamcmd; install_server; install_mods; ok "安装/更新完成" ;;
    install-mods|mods-install)
      ensure_dirs; warn_if_proxy; build_mod_list; ensure_steamcmd; install_mods; ok "模组处理完成" ;;
    render)
      build_mod_list; render_configs ;;
    backup)  do_backup ;;
    restore) shift || true; do_restore "${1:-}" ;;
    mods)
      build_mod_list
      log "最终生效的模组列表：${ACTIVE_MODS:-无}（共 ${#ACTIVE_MOD_ARRAY[@]} 个）" ;;
    doctor)  build_mod_list; doctor ;;
    shell|bash) exec /bin/bash ;;
    version) echo "buildid=$(server_version)" ;;
    *) err "未知子命令：${cmd}"
       cat >&2 <<USAGE
可用子命令：
  start            安装/更新 -> 生成配置 -> 启动服务器（默认）
  install|update   安装/更新服务端与模组
  install-mods     仅下载并部署模组（不动服务端本体）
  render           仅重新生成 GameUserSettings.ini / Game.ini
  backup           备份存档到 ${BACKUP_DIR}
  restore <文件>   从备份恢复
  mods             打印最终生效的模组列表
  doctor           打印环境自检（挂载/权限/磁盘/代理/SteamCMD 状态），排障用
  version          打印服务端 buildid
  shell            进入 shell
USAGE
       exit 1 ;;
  esac
}

main "$@"
