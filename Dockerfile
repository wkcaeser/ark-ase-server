# syntax=docker/dockerfile:1
# =============================================================================
#  方舟：生存进化（ARK: Survival Evolved / ASE）专用服务器
#  基础镜像：Debian 12 slim + SteamCMD
#
#  设计说明：
#   1. 服务端本体（约 6~10 GB）与创意工坊模组**不打包进镜像**，而是在容器
#      启动时由 SteamCMD 下载到挂载卷中。好处：镜像只有几百 MB、重建镜像
#      不需要重新下载游戏、升级服务端只需重启容器。
#   2. 全部可调参数（模组、负重、孵化、驯养等）通过环境变量注入，容器每次
#      启动按模板重新生成 GameUserSettings.ini / Game.ini。
# =============================================================================
FROM debian:12-slim

LABEL org.opencontainers.image.title="ark-survival-evolved-server" \
      org.opencontainers.image.description="方舟生存进化（ASE）专用服务器，支持模组与倍率通过环境变量配置" \
      maintainer="ark-ase-server"

# DEBIAN_FRONTEND：apt 静默安装；LANG=C.UTF-8：保证中文会话名/配置为 UTF-8 编码
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    STEAMCMD_DIR=/opt/steamcmd \
    ARK_SERVER_DIR=/ark \
    BACKUP_DIR=/backup \
    USER_CONFIG_DIR=/etc/ark/config

# -----------------------------------------------------------------------------
# 1) 系统依赖
#    - lib32gcc-s1 / lib32stdc++6：SteamCMD 为 32 位程序，必需
#    - libsdl2 / libfontconfig1 / libcurl4：服务端运行所需运行库
#    - procps/iproute2：容器内排查进程与端口
# -----------------------------------------------------------------------------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      wget \
      tar \
      bzip2 \
      gzip \
      xz-utils \
      procps \
      iproute2 \
      tzdata \
      util-linux \
      lib32gcc-s1 \
      lib32stdc++6 \
      libsdl2-2.0-0 \
      libfontconfig1 \
      libcurl4 \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2) SteamCMD（构建期预装，容器启动时若挂载卷为空会再次自动补装）
# -----------------------------------------------------------------------------
RUN mkdir -p "${STEAMCMD_DIR}" \
 && curl -fsSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
      | tar -xz -C "${STEAMCMD_DIR}" \
 && ( "${STEAMCMD_DIR}/steamcmd.sh" +quit || true ) \
 && mkdir -p /root/.steam/sdk64 /root/.steam/sdk32 \
 && ln -sf "${STEAMCMD_DIR}/linux64/steamclient.so" /root/.steam/sdk64/steamclient.so \
 && ln -sf "${STEAMCMD_DIR}/linux32/steamclient.so" /root/.steam/sdk32/steamclient.so

# -----------------------------------------------------------------------------
# 3) 目录与入口脚本
# -----------------------------------------------------------------------------
RUN mkdir -p "${ARK_SERVER_DIR}" "${BACKUP_DIR}" "${USER_CONFIG_DIR}"

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# 兜底处理：Windows 下克隆项目时 Git 的 core.autocrlf=true 会把 entrypoint.sh
# 的 LF 自动转成 CRLF，导致容器内 shebang 变成 "#!/usr/bin/env bash\r"，
# 启动即报 `/usr/bin/env: 'bash\r': No such file or directory`。
# 这里在构建期统一剥掉行尾的 CR，保证脚本在任何构建环境下都能正常执行。
RUN sed -i 's/\r$//' /usr/local/bin/entrypoint.sh \
 && chmod +x /usr/local/bin/entrypoint.sh \
 && ln -sf /usr/local/bin/entrypoint.sh /usr/local/bin/ark-server

# -----------------------------------------------------------------------------
# 4) 端口
#    7777/udp 游戏主端口   7778/udp 原始套接字(Raw Socket)
#    27015/udp Steam 查询端口（Steam 收藏/服务器列表发现用）
#    32330/tcp RCON 远程管理端口
# -----------------------------------------------------------------------------
EXPOSE 7777/udp 7778/udp 27015/udp 32330/tcp

WORKDIR ${ARK_SERVER_DIR}
VOLUME ["${ARK_SERVER_DIR}", "${BACKUP_DIR}"]

# 首次启动需要下载服务端+模组，start-period 给足时间
# 注意模式写成 [S]hooterGameServer：若直接写 ShooterGameServer，pgrep -f 会匹配到
# 执行本命令的 `sh -c "pgrep -f ShooterGameServer ..."` 自身，永远返回 0 ——
# 服务端没起来也会被判定成 healthy。
HEALTHCHECK --interval=60s --timeout=10s --start-period=20m --retries=3 \
  CMD pgrep -f '[S]hooterGameServer' >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["start"]
