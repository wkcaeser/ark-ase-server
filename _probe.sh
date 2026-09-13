#!/usr/bin/env bash
set -u

echo "=== compose project labels ==="
docker inspect ark-server --format 'dir={{index .Config.Labels "com.docker.compose.project.working_dir"}}'
docker inspect ark-server --format 'files={{index .Config.Labels "com.docker.compose.project.config_files"}}'

echo
echo "=== config override dir (/etc/ark/config) ==="
ls -la /mnt/c/Users/wk_home/projects/ark-ase-server/config

CFG=/home/wk_home/ark-data/server/ShooterGame/Saved/Config/LinuxServer
echo
echo "=== $CFG ==="
ls -la "$CFG" 2>&1

echo
echo "=== GameUserSettings.ini: 关键键 ==="
for f in GameUserSettings.ini Game.ini; do
  echo "--- $f ---"
  if [ -f "$CFG/$f" ]; then
    enc=$(file -b "$CFG/$f")
    echo "encoding: $enc"
    if iconv -f UTF-16LE -t UTF-8 "$CFG/$f" >/tmp/x.txt 2>/dev/null; then
      grep -nE 'ServerPVE|ShowFloatingDamageText|OverrideOfficialDifficulty|AllowHitMarkers|ServerHardcore|ServerCrosshair|RespawnInterval' /tmp/x.txt || echo "(关键键均未命中)"
    else
      grep -nE 'ServerPVE|ShowFloatingDamageText|OverrideOfficialDifficulty|AllowHitMarkers|ServerHardcore|ServerCrosshair|RespawnInterval' "$CFG/$f" || echo "(关键键均未命中)"
    fi
  else
    echo "不存在"
  fi
done

echo
echo "=== GameUserSettings.ini 头部（确认编码）==="
head -c 200 "$CFG/GameUserSettings.ini" | od -c | head -8

echo
echo "=== 容器内进程参数 ==="
ps -eo args | grep -m1 '[S]hooterGameServer'

echo
echo "=== 备份目录 ==="
ls -1t /home/wk_home/ark-data/backup/config 2>/dev/null | head -5
