# 方舟：生存进化（ASE）Docker 专用服务器

开箱即用的《方舟：生存进化》（**ARK: Survival Evolved**，非"生存飞升"ASA）专用服务器，
默认加载 **野人模组 + A镜模组**，并支持通过环境变量追加模组、调整负重 / 孵化 / 驯养等全部倍率。

- 服务端与模组在**容器首次启动时自动下载**，镜像只有几百 MB，重建镜像不用重新下游戏
- 所有配置写进 `.env` 一个文件，改完 `docker compose up -d` 即可生效
- 停机时自动**优雅保存世界**（先发 SIGINT，超时才强杀），避免回档
- 内置存档备份 / 恢复 / 配置渲染等运维子命令

---

## 目录

1. [快速开始](#一快速开始)
2. [目录与数据说明](#二目录与数据说明)
3. [模组管理](#三模组管理)
4. [配置项总表](#四配置项总表)
5. [倍率说明书](#五倍率说明书负重--孵化--驯养)
6. [进阶：直接改 ini](#六进阶直接改-ini)
7. [常用运维命令](#七常用运维命令)
8. [端口与网络](#八端口与网络)
9. [常见问题 FAQ](#九常见问题-faq)
10. [免责声明](#十免责声明)

---

## 一、快速开始

### 1. 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Linux（推荐 Ubuntu 22.04 / Debian 12）、Windows + WSL2、NAS（支持 Docker 即可） |
| Docker | Docker 20.10+ 与 Docker Compose v2 |
| 内存 | 最低 4 GB，**建议 8 GB 起**；带大型模组或 30 人以上建议 16 GB |
| 磁盘 | 40 GB 起（服务端约 10 GB + 野人模组 3.1 GB + 存档 + 备份 + 模组副本） |
| CPU | 2 核起，方舟吃**单核性能**，主频越高越流畅 |
| 网络 | 需要能访问 Steam（国内公网环境建议给 Docker 配代理，见 [FAQ 2](#9-steamcmd-下载慢或失败)） |

> 家庭宽带 / 云服务器都可以。云服务器记得在**安全组**里放行下方端口。

### 2. 三步启动

```bash
# 1) 进入项目目录，生成配置文件
cd ark-ase-server
cp .env.example .env

# 2) 编辑 .env —— 至少改这三项（非常重要）
#    SERVER_ADMIN_PASSWORD=换成你自己的管理员密码
#    SESSION_NAME=你的服务器名字
#    MAP=TheIsland   # 想换地图改这里
vim .env

# 3) 构建并启动
docker compose up -d --build

# 看启动日志（首次启动要下载约 10 GB，请耐心等待）
docker compose logs -f
```

首次启动大致流程（日志里能看到对应提示）：

```
[信息] 安装/更新服务端（AppID=376030）到 /ark      <-- 约 10 分钟，取决于网速
[信息] 需要处理的模组：817096835,1404697612        <-- 野人（3.1GB）+ A镜（3.3MB）
[完成] 模组 817096835 已就绪（复制）-> /ark/ShooterGame/Content/Mods/817096835
[完成] 已生成 .../GameUserSettings.ini
[完成] 已生成 .../Game.ini
[信息] 服务端进程 PID=xx，日志输出中…
```

> 首次启动总计要下载 **约 14 GB**（服务端 10 GB + 野人模组 3.1 GB），
> 中途 Ctrl+C 或重启容器都没关系，SteamCMD 会接着下完。

看到 `Server has completed startup` / `Server started` 之类的日志，就说明起来了。

### 3. 玩家如何进入游戏

1. 打开《方舟：生存进化》，进入「加入 ARK」→ 顶部搜索框输入你的**服务器名称**
   （服务器要在 Steam 服务器列表里能被搜到，需要 `QUERY_PORT` 对外可达）
2. 或者直接用 IP 连接：游戏内按 `Tab` 打开控制台，输入
   ```
   open 你的公网IP:7777
   ```
3. Steam 用户也可以收藏服务器：`Steam → 查看 → 游戏服务器 → 收藏 → 添加服务器 → 你的公网IP:27015`
4. 管理员权限：进游戏后按 `Tab`，输入 `enablecheats 你在 .env 里设置的服务器管理员密码`
5. 常用管理员指令：
   ```
   SaveWorld                     # 立刻存档（重要操作前先存一次）
   ListPlayers                   # 查看在线玩家
   GiveItemToPlayer <玩家ID> <物品蓝图路径> <数量>
   Summon <恐龙蓝图路径>          # 在自己位置刷一只生物
   ```

---

## 二、目录与数据说明

```
ark-ase-server/
├── Dockerfile                                    # 镜像定义（Debian 12 + SteamCMD）
├── entrypoint.sh                                 # 容器入口：安装/更新/生成配置/启动/备份
├── docker-compose.yml                            # 编排文件（含多地图集群示例）
├── .env.example                                  # 环境变量模板  ->  复制为 .env
├── config/
│   ├── GameUserSettings.ini.extra.example        # 自定义 ini 覆盖示例  ->  去掉 .example 使用
│   └── Game.ini.extra.example                    # 同上
└── data/                                         # 运行时生成（不要提交到 git）
    ├── server/                                   # 服务端本体 + 存档 + 模组（务必备份）
    │   └── ShooterGame/Saved/
    │       ├── Config/LinuxServer/               # 生成的 GameUserSettings.ini / Game.ini
    │       ├── SavedArks/                        # 地图存档（TheIsland.ark 等）
    │       ├── Config/LinuxServer/Game.ini
    │       └── SaveGames/                        # 部分模组的存档
    ├── steamcmd/                                 # SteamCMD 与创意工坊模组缓存（持久化，别删）
    └── backup/                                   # 存档备份 / 配置历史备份
```

> **重要**：`data/server` 里是全部游戏进度，请定期备份（见 [备份与恢复](#7-备份与恢复)）。
> 删除容器不会丢数据，但删除 `data/` 就等于删号。

---

## 三、模组管理

### 默认加载的两个模组

| 模组 | 说明 | Mod ID | 体积 |
| --- | --- | --- | --- |
| 野人模组 | Extinction Core（中文圈常称「起源2：灭绝野人」），新增彩色系野人 NPC 部落、世界 BOSS 等 | `817096835` | **约 3.1 GB** |
| A镜 | Awesome SpyGlass!（超级望远镜），显示生物属性、等级、坐标、描边 | `1404697612` | 约 3.3 MB |

> 如果你要的"野人"是**原始 NPC Primal NPCs（1803395040）**或**人类 NPC Human NPCs（1443404076）**，
> 直接改 `.env` 里的 `DEFAULT_MODS` 即可，例如：
> `DEFAULT_MODS=1803395040,1404697612`

> ⚠ 野人模组有 3.1 GB，加上服务端本体约 10 GB，**首次启动总共要下载 14 GB 左右**，
> 加上磁盘上模组的"缓存 + 部署副本"两份，建议预留 **40 GB 以上**磁盘空间。
> 空间紧张时把 `.env` 的 `MOD_LINK_MODE` 改成 `symlink`（详情见下方模组章节）。

### 三种配置方式（优先级从低到高）

**① 用默认模组（什么都不用改）**

```env
ENABLE_DEFAULT_MODS=true
```

**② 在默认模组基础上追加自己的模组（最常用）**

```env
EXTRA_MODS=761535755,955655993
```
- 逗号或空格分隔都可以
- 重复的 ID 会自动去重，非数字的 ID 会被跳过并给出警告
- 最终加载顺序 = `默认模组 -> EXTRA_MODS`（**后面的模组会覆盖前面的**，改数值类的模组建议放后面）

**③ 完全自定义（不再加载默认模组）**

```env
MODS=817096835,1404697612,761535755,955655993
```
只要 `MODS` 不为空，`ENABLE_DEFAULT_MODS` 和 `EXTRA_MODS` 就全部失效。

### 怎么查 Mod ID

打开创意工坊物品页面，地址类似：

```
https://steamcommunity.com/sharedfiles/filedetails/?id=1404697612
                                                    ^^^^^^^^^^ 这串数字就是 Mod ID
```

### 模组加载的几个坑

- **服务器端不用手动下载**：容器会通过 SteamCMD 把模组下到 `data/steamcmd`（缓存），
  再挂接到 `ShooterGame/Content/Mods/<ModID>`（服务端实际加载的位置）；
  服务端启动时还会带 `-automanagedmods` 兜底补下漏掉的模组。
  缓存与部署位置都在挂载卷里，**重建容器不会重下模组**。
- **磁盘占用约为模组体积的 2 倍**（缓存一份 + 部署副本一份）。空间紧张时设置：
  ```env
  MOD_LINK_MODE=symlink
  ```
  改成符号链接后几乎不占额外空间；若发现模组加载异常，改回 `auto` 即可。
- **玩家也要订阅同样的模组**，否则进不去（客户端缺少模组会被踢回主菜单）。
- **加载顺序**会影响互相覆盖的效果，数值类 / 汉化类模组建议排在后面。
- 模组更新后建议重启容器：`docker compose restart`（`MOD_UPDATE=true` 时会在启动时检查更新）。
- 下载失败（已下架、作者设为私密、网络超时）日志里会给出提示，把该 ID 从列表里删掉即可。
  只想单独重试模组而不动服务端：`docker compose run --rm ark install-mods`。
- 自定义编码的模组名 / 中文模组在服务器列表里可能显示异常，属客户端行为，不影响加载。

---

## 四、配置项总表

所有配置都写在 `.env` 里（模板见 `.env.example`，每一项都有中文注释）。

### 1. 服务器身份

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SESSION_NAME` | `方舟生存进化-专用服务器` | 服务器显示名，支持中文；**不能包含 `?` `&` `=`**（会被自动移除） |
| `SERVER_PASSWORD` | 空 | 进服密码，留空 = 公开服务器 |
| `SERVER_ADMIN_PASSWORD` | 空 | **管理员密码，强烈建议设置**；不设置就用不了管理员指令 |
| `MAP` | `TheIsland` | 地图：`TheIsland` `TheCenter` `ScorchedEarth_P` `Ragnarok` `Extinction` `Valguero_P` `Genesis` `Gen2` `CrystalIsles` `LostIsland` `Fjordur` |
| `MAX_PLAYERS` | `70` | 玩家上限（超过 70 人需注意内存与 `nofile` 限制） |
| `SERVER_PVE` | `true` | `true`=PVE，`false`=PVP |
| `SERVER_HARDCORE` | `false` | 硬核模式（死亡即转生） |
| `DIFFICULTY_OFFSET` | `1.0` | 难度偏移 |
| `OVERRIDE_OFFICIAL_DIFFICULTY` | `5.0` | 覆盖官方难度；`1.0 + 5.0` = 野生最高 150 级 |
| `BATTLEYE_ENABLED` | `true` | 反作弊；设为 `false` 会加 `-NoBattlEye`，部分模组/客户端兼容性更好 |
| `MAX_TAMED_DINOS` | 空 | 全服驯养生物上限，留空 = 用游戏默认规则 |
| `AUTO_SAVE_PERIOD_MINUTES` | `15` | 自动存档间隔（分钟） |
| `KICK_IDLE_PLAYERS_PERIOD` | `0` | 挂机踢出时间（秒），`0`=不踢 |

### 2. 玩法开关（`true` / `false`）

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ALLOW_THIRD_PERSON` | `true` | 允许第三人称 |
| `SHOW_MAP_PLAYER_LOCATION` | `true` | 地图上显示玩家位置 |
| `ALLOW_FLYER_CARRY_PVE` | `true` | PvE 中允许飞行生物被抓起 |
| `DISABLE_STRUCTURE_DECAY_PVE` | `true` | PvE 关闭建筑腐朽 |
| `SERVER_CROSSHAIR` | `true` | 显示准星 |
| `SHOW_FLOATING_DAMAGE_TEXT` | `true` | 显示浮动伤害数字 |
| `ALLOW_HIT_MARKERS` | `true` | 命中标记 |

### 3. 模组

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `ENABLE_DEFAULT_MODS` | `true` | 是否加载默认模组（野人 + A镜） |
| `DEFAULT_MODS` | `817096835,1404697612` | 默认模组列表（想换野人模组就改这里） |
| `EXTRA_MODS` | 空 | 追加模组 |
| `MODS` | 空 | 完全自定义列表（一填就忽略上面两个） |
| `MOD_LINK_MODE` | `auto` | 模组挂接方式：`auto` / `copy` / `symlink` |
| `MOD_UPDATE` | `true` | 每次启动更新模组 |

### 4. 运维行为

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `AUTO_UPDATE` | `true` | 每次启动检查更新服务端 |
| `STEAM_VALIDATE` | `false` | 更新时校验完整性（很慢，排障用） |
| `CONFIG_REGENERATE` | `true` | 每次启动按 `.env` 重写 ini；设 `false` 后可放心手改 ini |
| `CONFIG_BACKUP` | `true` | 重写前备份旧 ini（保留最近 5 份到 `data/backup/config`） |
| `BACKUP_KEEP` | `10` | `backup` 子命令保留的备份份数 |
| `STOP_TIMEOUT` | `90` | 停机时等待世界保存的秒数 |
| `SKIP_INSTALL_ON_START` | `false` | `true`=启动时完全不执行 SteamCMD（离线环境） |
| `STEAMCMD_RETRIES` | `3` | SteamCMD 失败重试次数 |

### 5. 集群（多地图互通，可选）

| 变量 | 说明 |
| --- | --- |
| `CLUSTER_ID` | 集群 ID，多台服务器填同样的值即可互通（自动附加 `-clusterid` / `-ClusterDirOverride` / `-NoTransferFromFiltering`） |
| `ALT_SAVE_DIR_NAME` | 每张地图用**不同的**存档目录名，避免互相覆盖 |
| `EXTRA_ARGS` | 追加任意启动参数，例如 `EXTRA_ARGS=-ForceAllowCaveFlyers` |

多地图示例见 `docker-compose.yml` 底部注释部分：注意 **端口、存档目录名都要错开**，并共用同一个 `data/server` 卷。

---

## 五、倍率说明书（负重 / 孵化 / 驯养）

所有倍率**默认值都是 1（= 官方原版）**。改完 `.env` 后 `docker compose up -d` 生效。

### 常用倍率对照

| 中文名 | `.env` 变量 | 写入的 ini 键 | 备注 |
| --- | --- | --- | --- |
| 驯养速度 | `TAMING_SPEED_MULTIPLIER` | `TamingSpeedMultiplier` | 数值越大驯得越快，**20** 大概几分钟驯好一只霸王龙 |
| 蛋孵化速度 | `EGG_HATCH_SPEED_MULTIPLIER` | `EggHatchSpeedMultiplier` | 数值越大孵化越快 |
| 幼体成长速度 | `BABY_MATURE_SPEED_MULTIPLIER` | `BabyMatureSpeedMultiplier` | 数值越大长得越快，孵完留痕记得调 |
| 交配间隔 | `MATING_INTERVAL_MULTIPLIER` | `MatingIntervalMultiplier` | **数值越小越快** |
| 交配过程速度 | `MATING_SPEED_MULTIPLIER` | `MatingSpeedMultiplier` | 数值越大越快 |
| 下蛋间隔 | `LAY_EGG_INTERVAL_MULTIPLIER` | `LayEggIntervalMultiplier` | **数值越小越快** |
| 印记加成 | `BABY_IMPRINTING_STAT_SCALE_MULTIPLIER` | `BabyImprintingStatScaleMultiplier` | 主要影响留痕给的加成 |
| 幼体食量 | `BABY_FOOD_CONSUMPTION_SPEED_MULTIPLIER` | `BabyFoodConsumptionSpeedMultiplier` | 幼体吃得快不快 |
| **玩家每级负重** | `PLAYER_WEIGHT_PER_LEVEL_MULTIPLIER` | `PerLevelStatsMultiplier_Player[7]` | 每点属性加的负重 = 原版 × 该倍率 |
| **恐龙每级负重** | `DINO_WEIGHT_PER_LEVEL_MULTIPLIER` | `PerLevelStatsMultiplier_DinoTamed[7]` | 同上，作用于驯养后的恐龙 |
| 物品重量 | `ITEM_WEIGHT_MULTIPLIER` | `ItemWeightMultiplier` | `<1` 表示物品变轻；部分服务端版本会忽略此项，最稳的减重方式是叠加/减重类模组 |
| 经验倍率 | `XP_MULTIPLIER` | `XPMultiplier` | |
| 采集倍率 | `HARVEST_AMOUNT_MULTIPLIER` | `HarvestAmountMultiplier` | |
| 资源血量（采集手感） | `HARVEST_HEALTH_MULTIPLIER` | `HarvestHealthMultiplier` | `<1` 时敲一下出更多资源 |
| 补给箱品质 | `LOOT_QUALITY_MULTIPLIER` | `LootQualityMultiplier` | |
| 作物生长 | `CROP_GROWTH_SPEED_MULTIPLIER` | `CropGrowthSpeedMultiplier` | |
| 生物刷新数量 | `DINO_COUNT_MULTIPLIER` | `DinoCountMultiplier` | 调高会明显吃内存 |
| 恐龙饱食度消耗 | `DINO_FOOD_DRAIN_MULTIPLIER` | `DinoCharacterFoodDrainMultiplier` | |
| 恐龙耐力消耗 | `DINO_STAMINA_DRAIN_MULTIPLIER` | `DinoCharacterStaminaDrainMultiplier` | |
| 恐龙回血 | `DINO_HEALTH_RECOVERY_MULTIPLIER` | `DinoCharacterHealthRecoveryMultiplier` | |
| 玩家饱食度消耗 | `PLAYER_FOOD_DRAIN_MULTIPLIER` | `PlayerCharacterFoodDrainMultiplier` | |
| 玩家水分消耗 | `PLAYER_WATER_DRAIN_MULTIPLIER` | `PlayerCharacterWaterDrainMultiplier` | |
| 便便间隔 | `POOP_INTERVAL_MULTIPLIER` | `PoopIntervalMultiplier` | |
| 燃料消耗间隔 | `FUEL_CONSUMPTION_INTERVAL_MULTIPLIER` | `FuelConsumptionIntervalMultiplier` | 数值越大烧得越慢 |
| 单机模式加成 | `USE_SINGLEPLAYER_SETTINGS` | `bUseSingleplayerSettings` | `true` 时属性成长整体加快，小规模好友服常用 |

### 一套"休闲娱乐服"参考配置

```env
XP_MULTIPLIER=5
TAMING_SPEED_MULTIPLIER=20
EGG_HATCH_SPEED_MULTIPLIER=30
BABY_MATURE_SPEED_MULTIPLIER=50
MATING_INTERVAL_MULTIPLIER=0.2
HARVEST_AMOUNT_MULTIPLIER=3
PLAYER_WEIGHT_PER_LEVEL_MULTIPLIER=5
DINO_WEIGHT_PER_LEVEL_MULTIPLIER=5
DINO_FOOD_DRAIN_MULTIPLIER=0.5
AUTO_SAVE_PERIOD_MINUTES=10
```

### 属性点索引对照（进阶）

`PerLevelStatsMultiplier_*[索引]` 里的索引含义固定：

| 索引 | 属性 | 索引 | 属性 |
| --- | --- | --- | --- |
| 0 | 生命 | 6 | 温度 |
| 1 | 耐力 | **7** | **负重** |
| 2 | 眩晕 | 8 | 近战伤害 |
| 3 | 氧气 | 9 | 移动速度 |
| 4 | 食物 | 10 | 防御 |
| 5 | 水 | 11 | 制作速度 |

想调**移速**、**近战伤害**等其他属性，用下面的 [自定义覆盖文件](#六进阶直接改-ini) 写一行即可，例如：

```ini
[/script/shootergame.shootergamemode]
PerLevelStatsMultiplier_Player[9]=2
```

---

## 六、进阶：直接改 ini

容器每次启动都会按 `.env` 重新生成两份配置，因此**不要直接改 `data/server/.../Config/LinuxServer/` 里的文件**（会被覆盖）。有两种正确做法：

### 做法 A：用覆盖文件（推荐，改一行写一行）

```bash
cd ark-ase-server/config
cp GameUserSettings.ini.extra.example GameUserSettings.ini.extra
cp Game.ini.extra.example Game.ini.extra
vim GameUserSettings.ini.extra     # 只写你想改的项
docker compose run --rm ark render # 立刻重新生成配置（或 docker compose up -d）
```

覆盖规则：
- 与容器生成的**同名键** → 直接覆盖该行的值
- **新键** → 追加到对应小节末尾
- **新小节** → 自动追加到文件末尾

### 做法 B：完全自己管

```env
CONFIG_REGENERATE=false
```
之后容器不再覆盖 ini，你可以随便手改。
> 注意：首次启动如果文件不存在，仍会生成一次默认配置。

### 两种配置文件的分工

| 文件 | 存放内容 |
| --- | --- |
| `GameUserSettings.ini` | 服务器基础设置与绝大多数倍率（`[ServerSettings]`）、最大人数（`[/Script/Engine.GameSession]`） |
| `Game.ini` | 玩法/模式类设置（`[/script/shootergame.shootergamemode]`）：每级属性倍率、单机模式加成、模组相关的数值覆盖等 |

> 同一个设置同时出现在两个文件里时，以 `Game.ini` 为准；服务端不认识的键会被静默忽略。

---

## 七、常用运维命令

在 `ark-ase-server` 目录下执行。

```bash
# 启动 / 停止 / 重启（重启 = 触发一次模组与服务端更新检查）
docker compose up -d
docker compose stop
docker compose restart

# 实时看日志（Ctrl+C 只退出查看，不会停服务器）
docker compose logs -f
docker compose logs -f --tail=200

# 只看最近 500 行并过滤关键字
docker compose logs --tail=500 | grep -iE 'error|mod|started'

# 进容器排查（进程 / 端口 / 文件）
docker compose exec ark bash
# 容器里可以执行：ark-server mods / ark-server render / ark-server backup

# 手动触发一次服务端 + 模组更新（不启动服务器）
docker compose run --rm ark install

# 只重新下载/部署模组（不动服务端本体）
docker compose run --rm ark install-mods

# 只重新生成配置
docker compose run --rm ark render

# 查看当前服务端版本（buildid）
docker compose run --rm ark version
```

### 备份与恢复

```bash
# 备份存档到 data/backup/ark-saved-<时间>.tar.gz
docker compose run --rm ark backup

# 查看有哪些备份
ls -lht data/backup/

# 恢复（把文件名换成你要恢复的那一份；建议先停服）
docker compose stop
docker compose run --rm ark restore ark-saved-20260912-120000.tar.gz
docker compose start
```

**建议**：把备份同步到机器之外（对象存储 / 另一台机器 / 网盘同步目录），
宿主机整盘挂掉时本地备份会一起没。也可以配一个定时任务：

```bash
# 每天 4:00 备份一次
(crontab -l 2>/dev/null; echo "0 4 * * * cd $(pwd) && docker compose run --rm ark backup") | crontab -
```

### 修改配置的标准流程

```bash
vim .env                     # 改倍率 / 模组 / 密码
docker compose up -d         # 重建并启动，配置自动重新生成
docker compose logs -f       # 确认识别到了新的倍率与模组
```

---

## 八、端口与网络

| 端口 | 协议 | 用途 | 是否必须 |
| --- | --- | --- | --- |
| 7777 | UDP | 游戏主端口（玩家连接用） | **必须** |
| 7778 | UDP | 原始套接字（Raw Socket），提高连接稳定性 | 建议放行 |
| 27015 | UDP | Steam 查询端口（服务器列表发现） | 想被搜到就**必须** |
| 32330 | TCP | RCON 远程管理 | 仅内网/白名单开放 |

- 云服务器需在**安全组 / 防火墙**放行上述端口，宿主机如开启 `ufw`/`firewalld` 也要放行。
- **端口内外一致**：方舟服务器会把自己监听的端口对外宣告，所以容器映射写成 `${PORT}:${PORT}`。
  改端口只需改 `.env` 的 `PORT`，但**记得把 `RAW_PORT` 同步改成 `PORT+1`**（原始套接字固定为游戏端口+1），
  例如 `PORT=7788` 时 `RAW_PORT=7789`。
- 家庭宽带无公网 IP：可用 frp / 花生壳等内网穿透，**UDP 必须一起转发**，否则玩家连不上。
- 想改服务器名字、地图后，客户端搜索可能要等几分钟才刷新，用 `open IP:7777` 直接连最快。

---

## 九、常见问题 FAQ

### 1. 首次启动很久，日志停在下载处

正常。服务端本体约 10 GB，模组几百 MB，网速决定耗时。用
`docker compose logs -f` 观察即可；中断也没关系，重新 `up -d` 会**断点续传**。

### 2. SteamCMD 下载慢或失败

Steam 在国内公网经常抽风，给 Docker 配代理是最有效的办法。示例（`/etc/docker/daemon.json`）：

```json
{
  "proxies": {
    "http-proxy": "http://127.0.0.1:7890",
    "https-proxy": "http://127.0.0.1:7890",
    "no-proxy": "localhost,127.0.0.1"
  }
}
```
改完执行 `sudo systemctl restart docker`（注意 `127.0.0.1` 要换成宿主机在容器网络里可达的地址，
例如 `http://host.docker.internal:7890` 或宿主机的内网 IP）。

临时排障也可以进容器手动重试：

```bash
docker compose exec ark bash
/opt/steamcmd/steamcmd.sh +login anonymous +force_install_dir /ark +app_update 376030 validate +quit
```

### 3. 模组没生效 / 玩家被踢

- 确认日志里有 `模组 xxx 已就绪`，且启动命令带上了正确的 `-mods=` 列表（日志里会完整打印启动命令）。
- 玩家客户端必须**订阅相同的模组**（含同一个 Mod ID），否则会被踢回主菜单。
- 模组顺序有讲究：数值类/汉化类建议放列表后面。
- 检查 `data/server/ShooterGame/Content/Mods/<ModID>` 目录是否存在、里面是否有 `.mod` 文件。

### 4. 玩家搜不到服务器

- `27015/UDP` 没放行（最常见）。
- 服务器还没完全启动完（首次启动要几分钟）。
- 用 `open 公网IP:7777` 直接连，能连上就说明只是列表发现的问题。
- 家里多台机器共用一条宽带、端口没做映射。

### 5. 服务器启动后崩溃、返回码 139

`139` = 段错误，绝大多数是**文件损坏或内存不足**：

```bash
docker compose stop
# 开启校验后重装
STEAM_VALIDATE=true docker compose run --rm ark install
docker compose start
```
同时检查宿主机内存余量（模组服建议 16 GB）、`dmesg` 里有没有 OOM 记录。

### 6. 存档在哪？怎么迁移到别的机器

存档在 `data/server/ShooterGame/Saved/`。整机迁移时把**整个 `data/` 目录**拷走即可
（`data/server` 里有存档与模组，`data/steamcmd` 可以不带，容器会重新下载）。

### 7. 中文服务器名显示乱码

镜像已设置 `LANG=C.UTF-8`，一般不会乱码。若仍有问题，检查：
- `.env` 文件本身保存为 **UTF-8 无 BOM** 编码
- 客户端语言与服务器字符串表一致（原版服务器对中文名的支持是正常的）
- 极端情况改用英文名：`SESSION_NAME=My ARK Server`

### 8. 改完配置不生效

- `CONFIG_REGENERATE` 被设成了 `false` → 容器不再覆盖 ini。
- 改的是 `data/server/.../Config/LinuxServer/` 里的文件 → 会被下次启动覆盖，请用 `config/*.extra` 或关掉 `CONFIG_REGENERATE`。
- 忘了重启：改 `.env` 后必须 `docker compose up -d`。
- 提示 `会话名称中不能包含 ? & = 这三个字符` —— 这是正常行为，服务端启动参数用 URL 传参，这三个字符必须去掉。

### 9. 长时间没重启后突然回档

停机时容器会先发 SIGINT 让服务端保存世界（`stop_grace_period` 已设为 150 秒）。
若被 `docker kill` / 宿主机断电强杀，就会回档到上一次自动存档（默认 15 分钟一次）。
建议把 `AUTO_SAVE_PERIOD_MINUTES` 设小一点（如 10），并开启定时备份。

### 10. 这个镜像能跑《方舟：生存飞升》(ASA) 吗？

不能。ASA 是重制版，AppID 是 `2430930`，启动方式与模组体系（CurseForge）都不同。
本项目针对的是《方舟：生存进化》(ASE)，AppID `376030`。

### 11. 想用非 root 用户运行

容器默认以 root 运行（最省心，不会出现挂载目录权限问题）。如果你有安全合规要求，
在 `docker-compose.yml` 的 `ark` 服务里加上：

```yaml
    user: "1000:1000"
```

并确保宿主机目录属主一致：

```bash
sudo chown -R 1000:1000 data/
```

入口脚本会自动适配非 root 环境（用户的 `~/.steam`、目录创建失败都会降级处理，不再中断启动）。

---

## 十、免责声明

- 本项目仅提供容器化部署工具与文档，**不包含任何游戏本体文件**，游戏资源由 SteamCMD 从 Valve 官方渠道下载。
- 请在遵守 [Steam 订阅者协议](https://store.steampowered.com/subscriber_agreement/) 与游戏厂商条款的前提下自行架设服务器，
  公网开服产生的一切后果由使用者自负。
- 模组版权归各自作者所有，本项目仅提供 Mod ID 配置能力，不分发模组文件。
- `SERVER_ADMIN_PASSWORD` / `SERVER_PASSWORD` 等敏感信息保存在 `.env` 中，请勿提交到公开仓库（`.gitignore` 已默认忽略）。
