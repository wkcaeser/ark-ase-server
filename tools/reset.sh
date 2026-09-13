#!/usr/bin/env bash
# =============================================================================
#  ark-ase-server 一键重置：清掉容器 / 镜像 / 下载内容，从零重来
#
#  用法（在 WSL 里执行，不要 sudo）：
#      bash tools/reset.sh              # 只清 docker 层：停+删容器、删镜像（数据保留）
#      bash tools/reset.sh --purge      # 连数据目录一起删（会二次确认）
#      bash tools/reset.sh --purge --up # 清完直接重新构建并启动
#
#  为什么需要这个脚本：
#      docker compose restart 和 restart 策略都**不会**重读 .env —— 容器里的环境变量
#      是「创建那一刻」固化的。所以改完 .env 后必须 down + up --force-recreate，
#      否则改了也白改（典型症状：清空了代理变量，容器里却还在用旧代理）。
#
#  ⚠ --purge 会删掉 ${DATA_DIR}/server（服务端 21GB）、steamcmd（缓存）、backup（配置备份）。
#    server/ShooterGame/Saved 下的**存档**也在里面，脚本会先把它拷到 backup 再删。
# =============================================================================
set -u
cd "$(dirname "$0")/.." 2>/dev/null || { echo "无法定位项目根目录"; exit 1; }

PURGE=0
UP=0
for a in "$@"; do
  case "$a" in
    --purge|-p) PURGE=1 ;;
    --up|-u)    UP=1 ;;
    -h|--help)  sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "未知参数: $a（用 --help 看用法）"; exit 1 ;;
  esac
done

hr(){ printf '\n===== %s =====\n' "$1"; }

# 读 .env 里的数据目录（默认 ./data）
DATA_DIR="$(grep -E '^DATA_DIR=' .env 2>/dev/null | head -n1 | cut -d= -f2- | tr -d '"' | tr -d "'")"
DATA_DIR="${DATA_DIR:-./data}"
DATA_DIR="${DATA_DIR/#\~/$HOME}"

hr "1/4 停止并删除容器"
docker compose down --remove-orphans 2>&1 | tail -n 10

hr "2/4 删除本项目的镜像"
for img in $(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E 'ark-ase|ark_ase'); do
  echo "  删除镜像 $img"
  docker rmi -f "$img" 2>&1 | tail -n 2
done

hr "3/4 清理 docker 残留（悬空镜像 / 停止的容器 / 构建缓存）"
docker container prune -f 2>&1 | tail -n 2
docker image prune -f 2>&1 | tail -n 2
docker builder prune -f 2>&1 | tail -n 2

if [ "$PURGE" -eq 1 ]; then
  hr "4/4 清空数据目录"
  if [ ! -d "$DATA_DIR" ]; then
    echo "  数据目录不存在：$DATA_DIR（跳过）"
  else
    echo "  数据目录：$DATA_DIR"
    echo "  当前占用："
    du -sh "$DATA_DIR"/* 2>/dev/null | sed 's/^/    /'

    # 存档先备份，别跟着一起没了
    SAVED="$DATA_DIR/server/ShooterGame/Saved"
    if [ -d "$SAVED" ]; then
      STAMP="$(date +%Y%m%d-%H%M%S)"
      echo "  备份存档 -> $DATA_DIR/backup/saved-$STAMP"
      mkdir -p "$DATA_DIR/backup"
      cp -a "$SAVED" "$DATA_DIR/backup/saved-$STAMP" 2>/dev/null \
        || echo "  ⚠ 存档备份失败，继续前请手动确认"
    fi

    ans=""
    printf '\n  确认删除？这会丢掉服务端本体与 SteamCMD 缓存（约 21GB）。输入 yes 继续：'
    read -r ans || true
    if [ "$ans" = "yes" ]; then
      rm -rf "$DATA_DIR"
      echo "  已删除 $DATA_DIR"
    else
      echo "  已取消，数据保留"
    fi
  fi
else
  hr "4/4 保留数据目录"
  echo "  $DATA_DIR 未动（要连数据一起清：bash tools/reset.sh --purge）"
fi

hr "完成"
echo "  下一步：docker compose up -d --build"
echo "  看日志：docker compose logs -f"
echo

if [ "$UP" -eq 1 ]; then
  hr "重新构建并启动"
  docker compose up -d --build 2>&1 | tail -n 20
  echo
  echo "  跟踪日志：docker compose logs -f"
fi
