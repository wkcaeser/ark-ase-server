# 方舟：生存进化（ASE）Docker 专用服务器

开箱即用的《方舟：生存进化》（**ARK: Survival Evolved**，非"生存飞升"ASA）专用服务器，
默认加载 **物品叠加 + 野人模组 + A镜模组**，并支持通过环境变量追加模组、调整负重 / 孵化 / 驯养等全部倍率。

- 服务端与模组在**容器首次启动时自动下载**，镜像只有几百 MB，重建镜像不用重新下游戏
- 所有配置写进 `.env` 一个文件，改完 `docker compose up -d` 即可生效
- 停机时自动**优雅保存世界**（先发 SIGINT，超时才强杀），避免回档
- 内置存档备份 / 恢复 / 配置渲染等运维子命令

> 项目地址：<https://github.com/wkcaeser/ark-ase-server> ｜ 基于 [MIT 许可证](LICENSE) 开源

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
11. [开源许可证](#十一开源许可证)

---

## 一、快速开始

### 1. 获取代码

```bash
git clone https://github.com/wkcaeser/ark-ase-server.git
cd ark-ase-server
```

> 没有 Git 环境的话，也可以直接下载
> [ZIP 压缩包](https://github.com/wkcaeser/ark-ase-server/archive/refs/heads/main.zip) 解压使用。

### 2. 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Linux（推荐 Ubuntu 22.04 / Debian 12）、Windows + WSL2、NAS（支持 Docker 即可） |
| Docker | Docker 20.10+ 与 Docker Compose v2 |
| 内存 | 最低 4 GB，**建议 8 GB 起**；带大型模组或 30 人以上建议 16 GB |
| 磁盘 | 40 GB 起（服务端约 10 GB + 野人模组 3.1 GB + 存档 + 备份 + 模组副本） |
| CPU | 2 核起，方舟吃**单核性能**，主频越高越流畅 |
| 网络 | 需要能访问 Steam（国内公网环境建议给 Docker 配代理，见 [FAQ 2](#2-steamcmd-下载慢或失败)） |

> 家庭宽带 / 云服务器都可以。云服务器记得在**安全组**里放行下方端口。

### 3. 三步启动

```bash
# 1) 进入项目目录，生成配置文件
cd ark-ase-server
cp .env.example .env

# 2) 编辑 .env —— 至少改这三项（非常重要）
#    SERVER_ADMIN_PASSWORD=换成你自己的管理员密码
#    SESSION_NAME=你的服务器名字
#    MAP=TheIsland   # 想换地图改这里
#    ⚠ Windows/WSL 用户再加一项（否则服务端装不上，见 FAQ 13）：
#    DATA_DIR=/home/<你的用户名>/ark-data
vim .env

# 3) 构建并启动
docker compose up -d --build

# 看启动日志（首次启动要下载约 10 GB，请耐心等待）
docker compose logs -f
```

首次启动大致流程（日志里能看到对应提示）：

```
[信息] 安装/更新服务端（AppID=376030）到 /ark      <-- 约 10 分钟，取决于网速
[信息] 需要处理的模组：761535755,817096835,1404697612  <-- 叠加（1.6MB）+ 野人（3.1GB）+ A镜（3.3MB）
[完成] 模组 817096835 已就绪（复制）-> /ark/ShooterGame/Content/Mods/817096835
[完成] 已生成 .../GameUserSettings.ini
[完成] 已生成 .../Game.ini
[信息] 服务端进程 PID=xx，日志输出中…
```

> 首次启动总计要下载 **约 14 GB**（服务端 10 GB + 野人模组 3.1 GB，叠加与 A镜各几 MB），
> 中途 Ctrl+C 或重启容器都没关系，SteamCMD 会接着下完。

看到 `Server has completed startup` / `Server started` 之类的日志，就说明起来了。

### 4. 玩家如何进入游戏

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

> **重要**：`data/server` 里是全部游戏进度，请定期备份（见 [备份与恢复](#备份与恢复)）。
> 删除容器不会丢数据，但删除 `data/` 就等于删号。

---

## 三、模组管理

### 默认加载的三个模组

| 模组 | 说明 | Mod ID | 体积 |
| --- | --- | --- | --- |
| 物品叠加 | Ultra Stacks，大幅提高物品堆叠上限并降低单个物品重量，仓库和背包不再爆格 | `761535755` | 约 1.6 MB |
| 野人模组 | Extinction Core（中文圈常称「起源2：灭绝野人」），新增彩色系野人 NPC 部落、世界 BOSS 等 | `817096835` | **约 3.1 GB** |
| A镜 | Awesome SpyGlass!（超级望远镜），显示生物属性、等级、坐标、描边 | `1404697612` | 约 3.3 MB |

> **加载顺序有讲究**：叠加 / 大修类模组（Ultra Stacks）排在列表**最前面**，
> 大型内容模组与地图模组排在后面 —— 反过来排的话，叠加模组的物品定义可能被内容模组覆盖而不生效。
> 默认顺序 `761535755 -> 817096835 -> 1404697612` 已经按这个规则排好，通常不需要改动。

> 如果你要的"野人"是**原始 NPC Primal NPCs（1803395040）**或**人类 NPC Human NPCs（1443404076）**，
> 直接改 `.env` 里的 `DEFAULT_MODS` 即可，例如：
> `DEFAULT_MODS=761535755,1803395040,1404697612`

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
EXTRA_MODS=955655993
```
- 逗号或空格分隔都可以
- 重复的 ID 会自动去重（比如把已经在默认列表里的 `761535755` 又写进 `EXTRA_MODS`），非数字的 ID 会被跳过并给出警告
- 最终加载顺序 = `默认模组 -> EXTRA_MODS`
- ⚠ 追加**叠加类**模组时要留意：它会被排在默认的 Ultra Stacks 之后，两个叠加模组会互相冲突。
  叠加模组同一时间只启用一个，改用下面的 `MODS` 完全自定义、把它排到最前面即可。

**③ 完全自定义（不再加载默认模组）**

```env
MODS=761535755,817096835,1404697612,955655993
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
- **加载顺序**很重要：`-mods=` 里靠前的先加载，靠后的优先生效（后面的会覆盖前面的）
  - **叠加 / 大修 / 建筑类模组放最前面**（如 Ultra Stacks、S+），否则物品定义可能被内容模组覆盖而不生效
  - **数值 / 汉化 / 内容类模组放后面**，让它们的改动最终生效
  - **叠加模组之间互不兼容**，同一个服务器只保留一个
  - 默认顺序 `761535755(叠加) -> 817096835(野人) -> 1404697612(A镜)` 就是按这个规则排的
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
| `ENABLE_DEFAULT_MODS` | `true` | 是否加载默认模组（叠加 + 野人 + A镜） |
| `DEFAULT_MODS` | `761535755,817096835,1404697612` | 默认模组列表（想换野人模组就改这里；叠加类模组保持在最前） |
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
| `STEAM_USER` | 空 | Steam 账号；留空=匿名登录。通常不需要，仅在容器/网络都确认干净、匿名确实被挡时才试（见 FAQ 15 修复四） |
| `STEAM_PASS` | 空 | 上面的密码；日志里会自动打码成 `***`。**别把 `.env` 提交进 git** |

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
| 物品重量 | `ITEM_WEIGHT_MULTIPLIER` | `ItemWeightMultiplier` | `<1` 表示物品变轻；部分服务端版本会忽略此项，最稳的减重方式是叠加/减重类模组（本项目默认已加载 Ultra Stacks） |
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
# 容器里可以执行：ark-server mods / ark-server doctor / ark-server render / ark-server backup

# 环境自检：挂载/文件系统/权限/属主/磁盘/代理/SteamCMD 状态（装不上服务端时先跑这个）
docker compose run --rm ark doctor

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

**先别急着配代理 —— 先确认你现在的出口是什么样。**

如果宿主机开着代理软件的 **TUN 模式 / 全局模式**（Clash、Surge、v2rayN…），
WSL 与容器的出网流量已经被整体接管，**这时再配一层容器代理不是加速而是打架**：
TUN 的 fake-ip 会把 `host.docker.internal` 解析成 `198.18.x.x` 之类的假地址，
容器连不过去，SteamCMD 会卡在 `Connecting anonymously to Steam Public...Retrying...`
无限重试。判据很简单：**配了代理反而比不配更差 ⇒ 清空它。**

**方式一（本项目内置）：填 `.env` 里的代理变量**

```env
PROXY_HTTP=http://host.docker.internal:7897
PROXY_HTTPS=http://host.docker.internal:7897
PROXY_NO=localhost,127.0.0.1,host.docker.internal
```

改完必须**重建容器**：`docker compose up -d --force-recreate`（**不用重启 Docker**）。

> ⚠ **变量名是 `PROXY_*`，不是 `HTTP_PROXY`。** 这不是笔误：`docker compose` 插值的优先级是
> **「宿主机 shell 环境 > `.env`」**，若直接叫 `HTTP_PROXY`，宿主机上只要存在同名变量
> （Windows 系统代理、Clash 的「系统代理」开关等）就会盖掉 `.env`，把宿主机那份代理
> 塞进容器。容器里最终生效的仍是标准名 `HTTP_PROXY` / `http_proxy`，无需在别处改动。

> ⚠ 四个常见的坑：
> 1. **端口别想当然**：Clash Verge 的 HTTP/SOCKS 混合端口默认是 **7897**（老版本才是 7890）。
>    填错 = 代理等于没配，还会把本来通的直连一起弄坏。
> 2. 代理跑在宿主机（Windows/WSL）上时，容器里的 `127.0.0.1` 指的是**容器自己**，
>    写了也连不上，必须用 `host.docker.internal`（compose 已加 `host-gateway` 声明）。
> 3. 代理软件要打开「允许局域网连接 / Allow LAN」，否则宿主机之外连不进来。
> 4. **改完 `.env` 必须 `--force-recreate` 重建容器**：环境变量在容器创建时固化，
>    `docker compose restart` 和 restart 策略的自动重启都**不会**重读 `.env`。
>    只重启不重建 = 改了等于没改（这是本项目最隐蔽的坑，详见 FAQ 15 判据三）。
>
> ⚠ 还有一层：**代理配错或不可达时，会把本来能装的应用弄成装不上** —— SteamCMD 下载链路
> 走不通，对外只报一句 `Missing file permissions`。这种情形详见
> [FAQ 15](#15-自检通过容器也能正常写文件但-steamcmd-仍报-missing-file-permissions)。

**方式二：给整个 Docker 守护进程配代理**（只适用于 **WSL 里原生安装的 docker**）

```json
{
  "proxies": {
    "http-proxy": "http://127.0.0.1:7890",
    "https-proxy": "http://127.0.0.1:7890",
    "no-proxy": "localhost,127.0.0.1"
  }
}
```

写进 `/etc/docker/daemon.json` 后执行 `sudo systemctl daemon-reload && sudo systemctl restart docker`。

> 为什么这里能用 `127.0.0.1`？因为 WSL 原生 docker 的守护进程就跑在 WSL 里，
> 和你的代理是同一台机器。
> **Docker Desktop 用户不能这么写**——它的守护进程跑在一个独立的虚拟机里，
> 那里的 `127.0.0.1` 指向虚拟机自己。请用 Settings → Resources → Proxies，
> 详见 [FAQ 14](#14-构建时报-eof拉不到-debian12-slim-基础镜像)。

临时排障也可以进容器手动重试：

```bash
docker compose exec ark bash
/opt/steamcmd/steamcmd.sh +login anonymous +force_install_dir /ark +app_update 376030 validate +quit
```

### 3. 模组没生效 / 玩家被踢

- 确认日志里有 `模组 xxx 已就绪`，且启动命令带上了正确的 `-mods=` 列表（日志里会完整打印启动命令）。
- 玩家客户端必须**订阅相同的模组**（含同一个 Mod ID），否则会被踢回主菜单。
- 模组顺序有讲究：叠加/大修类放最前面，数值/汉化/内容类放后面；叠加模组只保留一个。
- **叠加模组不生效**的典型症状是堆叠上限仍是原版数值。除了顺序问题，还要确认：
  改完 `.env` 后确实执行了 `docker compose up -d`、玩家客户端也订阅了 `761535755`；
  若之前用过别的叠加模组，存档里已转换过的物品可能需要在游戏内重新堆叠一次。
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

### 12. 容器起来就疯狂重启，日志刷 `/usr/bin/env: 'bash\r': No such file or directory`

**Windows / WSL 环境最常见的问题**，和代码无关，是**行尾符**（EOL）导致的。

Windows 版 Git 默认 `core.autocrlf=true`，克隆代码时会把 `entrypoint.sh` 的 LF 自动
改成 CRLF。文件进了镜像后，第一行就成了：

```
#!/usr/bin/env bash\r
```

内核会把 `bash\r` 当成解释器名字去找，自然找不到，于是容器启动即退出；
又因为 `restart: unless-stopped`，就变成日志刷屏的无限重启。

**修复方式（本仓库 v1 已自带 `.gitattributes` + Dockerfile 兜底，正常不会再遇到）**

如果是**旧版本代码**或别人给你的压缩包，手动做一次即可：

```bash
# 方式一：装 dos2unix（推荐）
sudo apt-get install -y dos2unix && dos2unix entrypoint.sh

# 方式二：用 sed 剥掉行尾的 CR
sed -i 's/\r$//' entrypoint.sh

# 方式三：Git 层面根治（在仓库根目录执行一次）
printf '* text=auto\n*.sh text eol=lf\nDockerfile text eol=lf\n' > .gitattributes
git add --renormalize .
git commit -m "chore: 统一行尾为 LF"
```

改完**必须重建镜像**（脚本是打进镜像里的，只改文件不重新构建不生效）：

```bash
docker compose up -d --build
docker compose logs -f
```

**自查命令**（返回 0 说明文件是干净的 LF）：

```bash
grep -c $'\r' entrypoint.sh      # 输出 0 就正常；输出等于行数说明是 CRLF
file entrypoint.sh               # 期望看到 "ASCII text"，若带 "CRLF" 则有问题
```

> 顺带提一句：Windows 上编辑脚本建议把编辑器设置为「LF」换行符，
> 或把 Git 全局配置改成 `git config --global core.autocrlf input`。

### 13. 日志刷 `ERROR! Failed to install app '376030' (Missing file permissions)`

**Windows + WSL 用户装不上服务端的头号原因**，和代码、和网络都无关，是**数据目录所在的文件系统**。

Windows 的 C 盘（`/mnt/c/...`）被 Docker Desktop 映射进容器时走 9p/DrvFs，这种挂载
**不保留 Linux 权限语义**，`chmod` 近似空操作。SteamCMD 要创建并设置权限的文件因此被拒：

- 日志停在 `Waiting for user info... OK` 之后**立刻**报 `Missing file permissions`
  （注意：**连下载进度都不会出现**，说明不是下载中断，是安装一开始就被拒）
- 反复重试同样失败，最后 `[错误] 服务端安装失败`，容器退出又被 `restart` 拉起，无限循环
- 有时报 `Missing configuration`；也可能撑到一半变成 `No Connection` / 超时
  ——那是 Steam 网络抖动，属于[另一个问题](#2-steamcmd-下载慢或失败)

判据：`data/server/steamapps` 是空的、`data/server/ShooterGame/Binaries` 不存在，
说明一个字节都没装上。

**修复：把数据放到 WSL 自己的文件系统（ext4）里**

```bash
# 1) 在 WSL 里查自己的家目录，例如 /home/wk_home
echo $HOME

# 2) 编辑 .env，改掉 DATA_DIR
#    DATA_DIR=/home/wk_home/ark-data

# 3) 迁移旧数据并重建容器
docker compose down
mkdir -p "$HOME/ark-data"
mv ./data/* "$HOME/ark-data/" 2>/dev/null || true
docker compose up -d --build
```

**容器现在会自己检测这件事**：启动时对数据目录做一次「文件系统类型 + 权限实测」，
不通过就直接打印修复指引并退出，省得你对着 SteamCMD 的报错猜。
确实要用 Windows 目录时，在 `.env` 里设 `ALLOW_WINDOWS_DATA_DIR=true` 强制放行（不推荐）。

Linux 服务器 / macOS 不存在这个问题，保持 `DATA_DIR=./data` 即可。

> ⚠ **别把这句话当成万能解释。** 容器启动时会自检数据目录：**自检通过了，就说明
> 这条不是你的病因**，请直接看 [FAQ 15](#15-自检通过容器也能正常写文件但-steamcmd-仍报-missing-file-permissions)。
> `Missing file permissions` 是 SteamCMD 最爱乱报的一句话，还有一个成因是**网络**。

### 14. 构建时报 EOF，拉不到 debian:12-slim 基础镜像

典型报错：

```
=> ERROR [internal] load metadata for docker.io/library/debian:12-slim
failed to solve: failed to do request:
  Head "https://registry-1.docker.io/v2/library/debian/manifests/12-slim": EOF
```

**先记住一件事：这跟 `.env` 里的代理没有半点关系，删掉代理也修不好。**
`env_file` 只注入容器运行时的环境变量，**不参与** `docker build`。

关键是分清两层，它们的出口完全不同：

| 阶段 | 谁发起的请求 | 该在哪里配代理 / 加速 |
| --- | --- | --- |
| **构建**：拉 `debian:12-slim`、`apt-get`、下载 SteamCMD | Docker 引擎 + BuildKit | 引擎级：Docker Desktop 的 Proxies / Docker Engine JSON |
| **运行**：SteamCMD 下服务端与模组、服务端联网 | 容器里的进程 | `.env` 的 `PROXY_HTTP` / `PROXY_HTTPS` |

你现在卡在**构建层**，所以要在引擎上动手。

**第 1 步：看看引擎当前的真实配置**

```powershell
# Windows PowerShell
docker info | Select-String -Pattern "Proxy|Registry Mirrors"

# WSL / Linux
docker info | grep -Ei "proxy|registry mirrors"
```

**第 2 步：按结果对症处理**

**情况 A：`HTTP Proxy:` 有值，且是 `http://127.0.0.1:7890`** —— 大概率就是它。

Docker Desktop 的引擎跑在一个独立虚拟机里，那里的 `127.0.0.1` 指向虚拟机自己，
不是你的 Windows 宿主机，连接会被立刻丢弃（表现正是 `EOF`）。

- 打开 Docker Desktop → **Settings → Resources → Proxies**
- 把地址改成 `http://host.docker.internal:7890`（端口换成你自己的），
  或先**关掉 "Use system proxy"** 验证是不是它的问题
- 顺手确认代理软件开了「允许局域网连接 / Allow LAN」
- Apply & Restart 后回到第 1 步复查

**情况 B：`Registry Mirrors:` 是空的** —— 国内直连 Docker Hub 本来就时通时断。

Docker Desktop → **Settings → Docker Engine**，在 JSON 里补上（保留原有字段）：

```json
{
  "registry-mirrors": [
    "https://docker.xuanyuan.me",
    "https://docker.1ms.run",
    "https://docker.m.daocloud.io"
  ]
}
```

Apply & Restart。多填几个是为了容灾——加速器都是社区服务，会失效、会变动，
某个不通就换列表里的下一个。

**第 3 步：验证**

```powershell
docker pull debian:12-slim            # 能拉下来就说明通了
docker compose up -d --build
```

**如果构建期也要走代理**（例如 `apt-get` 或下载 SteamCMD 被卡住）：

代理要传给**构建进程**，而不是写进 `.env`。注意 `RUN` 步骤跑在 Docker 虚拟机的容器里，
所以同样要用 `host.docker.internal`：

```bash
# bash（Windows Git Bash / WSL / Linux）
HTTP_PROXY=http://host.docker.internal:7897 \
HTTPS_PROXY=http://host.docker.internal:7897 \
docker compose build
```

```powershell
# Windows PowerShell
$env:HTTP_PROXY="http://host.docker.internal:7897"
$env:HTTPS_PROXY="http://host.docker.internal:7897"
docker compose build
```

> 构建成功后这两个变量就可以关掉，容器运行时用的是 `.env` 里那一组，互不干扰。
> 端口按你自己的代理软件填（Clash Verge 默认 7897）。

### 15. 自检通过、容器也能正常写文件，但 SteamCMD 仍报 `Missing file permissions`

这是最容易把人带偏的一种情况。先说结论：**这句话不是操作系统的权限错误**，
按判据查清是哪一类，再对症处理。

| 成因 | 判据 | 怎么办 |
| --- | --- | --- |
| ① **容器里挂着代理，但代理不通 / 端口写错**（实测命中率最高） | 容器内 `HTTP_PROXY` 有值（尤其 `.env` 里 `PROXY_HTTP` 却是空的） | 见下「修复一」 |
| ② 数据目录在 Windows/网络挂载上，`chmod` 不生效 | 启动日志里**没有**「数据目录自检通过」，或自检直接报错退出 | [FAQ 13](#13-日志刷-error-failed-to-install-app-376030-missing-file-permissions) |
| ③ 确实连不上 Steam（无代理也一样） | 日志里大面积 `Retrying...` / `No Connection` / `Timed out`，连 `Connecting anonymously...` 都过不去 | 先修网络，再谈安装 |
| ④ 容器运行时细节（以 root 跑 SteamCMD / 隔离策略 / 内核） | 官方 `cm2network/steamcmd` 镜像**也失败** ⇒ 属环境层；**它成功而你失败** ⇒ 属本镜像 | 见下「修复五」隔离矩阵 |

**判据一：先确认失败卡在哪一步**

去 `data/steamcmd/linux32/logs/console_log.txt` 看每个会话的结尾。**决定性的一条是：
`Waiting for user info...OK` 之后有没有 `Update state (0x...)`。**

- **没有** `Update state`，直接就 `ERROR! Failed to install app ...` →
  连「建立更新任务」这一步都没成功（还没拿到内容服务器配置），**与文件权限无关**。
- **有** `Update state` 才进入下载/校验；此时再失败才可能是磁盘、权限这类本地问题。

**判据二：`Missing file permissions` 这个字符串的真实含义**

它**不是操作系统的权限错误**，而是 Steam 自己的「应用更新错误」枚举文本
（SteamCMD 进程退出码实测就是 **8**）：

| 字符串 | 大致含义 |
| --- | --- |
| `Missing configuration` | 拿不到该 App 的安装配置（depot / 更新计划） |
| `Missing file permissions` | 更新计划构建失败，被归到这一类；**与 chmod 无关** |

同族还有 `No subscription`（账号没有许可）等。共同点是：**它们说的是 Steam 侧的态度，
不是本地文件系统。** 所以看到这句话，第一个该怀疑的不是 `chmod`，而是
**这一路请求为什么没走通**。

**判据三：先看「代理」这一行 —— 实测最常见的真因**

项目在启动日志和 `doctor` 里都会打印容器内的 `HTTP_PROXY`，并且同时打印 `.env` 的原始意图
（`PROXY_HTTP`）。**只要容器里还有代理值，就先怀疑它**：代理端口写错
（Clash Verge 默认 **7897**，不是 7890）或代理不可达时，SteamCMD 的下载链路走不通，
对外就报成 `Missing file permissions` / `Missing configuration`。

这里有个**最隐蔽的坑**：**环境变量在容器「创建」时固化**，`docker compose restart`
和 `restart: unless-stopped` 的自动重启**都不会重读 `.env`**。于是会出现：

> `.env` 里代理明明清空了，容器里却还挂着旧代理 → 你会觉得「怎么改都没用」。

一条命令看出真相：

```bash
docker exec ark-server sh -c 'env | grep -i proxy'
```

- 输出为空 → 没有代理干扰，跳判据四。
- 输出里有 `HTTP_PROXY=...`，而 `.env` 里 `PROXY_HTTP` 是空的
  → **就是它**，重建容器即可：

```bash
docker compose up -d --force-recreate
```

`ark doctor` 会把这条直接点出来；容器启动时若检测到代理，日志里也会给同样的提示。

**判据四（曾经误用，已证伪）：`app access token ... 0 received, N denied` 是正常现象**

`data/steamcmd/Steam/logs/appinfo_log.txt` 里经常能看到：

```
Requested 67 app access tokens, 0 received, 67 denied
```

**这行不是故障判据。** 匿名会话本来就拿不到那 67 个 App 的 access token，
而在下载**正常进行**的探测容器里，这行照样出现 —— 实测同一容器同时打印：

```
Requested 67 app access tokens, 0 received, 67 denied
Update state (0x11) preallocating, progress: 88.67 (20340409257 / 22938933947)
```

即「令牌全拒」与「下载到 88%」并存。本项目早期文档曾把它当成根因，**已证伪**，
请不要据此排查。（`doctor` 仍会把它打出来，但只作参考。）

**修复一：让容器彻底不带代理（实测真因）**

`.env` 里这一组留空即可 —— 注意变量名是 **`PROXY_*`**，不是 `HTTP_PROXY`：

```env
PROXY_HTTP=
PROXY_HTTPS=
PROXY_NO=
```

```bash
docker compose up -d --force-recreate
```

> **为什么变量名不叫 `HTTP_PROXY`？** 因为 `docker compose` 做变量插值时，
> 优先级是 **「宿主机 shell 环境 > `.env` 文件」**。若 compose 里直接写 `${HTTP_PROXY:-}`，
> 那么宿主机（Windows 系统代理、Clash 的「系统代理」开关、WSL 的 `/etc/environment`）
> 只要存在同名变量，就会**盖掉** `.env` 里的空值，把宿主机那份代理硬塞进容器 ——
> 而且通常是错的端口。用 `PROXY_*` 这种专属名字可彻底切断这条泄漏路径。
> 容器里最终生效的仍然是标准名 `HTTP_PROXY` / `http_proxy`，其它地方无需改动。

**确实需要容器内代理时**（宿主机没有 TUN，就是想让容器单独走代理）：

```env
PROXY_HTTP=http://host.docker.internal:7897
PROXY_HTTPS=http://host.docker.internal:7897
```

- ⚠ **端口别想当然**：Clash Verge 的 HTTP/SOCKS 混合端口默认是 **7897**（老版本才是 7890）。
  填错端口 = 代理等于没配，还会把本来通的直连一起弄坏。
- ⚠ 容器里的 `127.0.0.1` 指容器自己，一定写 `host.docker.internal`。
  compose 已声明 `host.docker.internal:host-gateway` —— WSL 原生 dockerd **不会**自动提供
  这个名字（只有 Docker Desktop 会），不声明就会被代理的 fake-ip 抢答成假地址。
- ⚠ **只填大写这一组就行**：compose 会同时注入小写的 `http_proxy` / `https_proxy`。
  这一步是必需的 —— curl 与 SteamCMD 内部的下载链路**只认小写变量名**，只配大写等于没走代理。
- ⚠ **改完必须 `docker compose up -d --force-recreate`**，只 restart 不生效（见判据三）。
- 验证：`docker compose run --rm ark doctor`，看代理变量与「Steam 侧连通性」。

**宿主机开着 TUN / 全局模式时，这一层更要留空**

TUN 的默认路由（metric 抢在物理网卡之前）已经把 WSL 与容器的出网整体接管。
此时再叠一层代理只会打架：TUN 的 fake-ip 会把 `host.docker.internal` 解析成
`198.18.x.x` 之类的假地址，容器根本连不过去，SteamCMD 会卡在
`Connecting anonymously to Steam Public...Retrying...` 无限重试 —— **配了反而更差。**

判据很简单：**配了代理比不配更差，就是这种情况，清空并重建即可。**

**修复二：把 SteamCMD 整个重建一份**

从 Windows 目录搬过来的 SteamCMD 可能残留了状态不一致的文件：

```bash
docker compose down
mv "$HOME/ark-data/steamcmd" "$HOME/ark-data/steamcmd.bak"
docker compose up -d --build      # 容器会重新下载一份干净的 SteamCMD
```

**修复三：首次安装自动带 `validate`（项目已内置）**

方舟 376030 的社区惯例是「第一次安装必须加 validate」。entrypoint 在检测到
`<DATA_DIR>/server/steamapps` 不存在时会自动追加 `validate`，无需手动操作。
需要强制全量校验时：`STEAM_VALIDATE=true docker compose run --rm ark install`。

**修复四：改用真实 Steam 账号登录（兜底）**

匿名路径在全球范围是通的（中文教程普遍用 `+login anonymous`），所以**先做修复一**。
只有在确认容器/环境一切都干净、确实是匿名会话被 Steam 侧挡下时，才换成真实账号：

```env
STEAM_USER=你的账号
STEAM_PASS=你的密码
```

- 建议专门建一个服务端小号；密码明文存在 `.env`，**别把 `.env` 提交进 git**。
- 容器日志里会自动把密码替换成 `***`，不会泄漏到日志。

**修复五：一轮隔离矩阵，把责任方钉死**

```bash
bash tools/diag-steamcmd.sh        # 可带代理参数：bash tools/diag-steamcmd.sh http://host.docker.internal:7897
```

| 组 | 变量 | 读法 |
| --- | --- | --- |
| **T0** | 小 AppID **1007**（对照组，最先跑） | **成功 ⇒ 网络、镜像、权限全部无罪**，重点回到容器配置（尤其代理） |
| T2 | 我们的镜像 + 376030 | 复现故障 |
| T1 | 官方 `cm2network/steamcmd` 镜像（非 root + 自有 HOME） | 成功 ⇒ 我们的镜像 / root 有问题；失败 ⇒ 环境或 Steam 侧 |
| T3 | 我们的镜像 + 376030 + `@sSteamCmdForcePlatformType linux` | 成功 ⇒ 平台探测问题 |
| T5 | 我们的镜像 + 376030 + 指定代理 | 只有当代理确实可用时才有意义 |

> ⚠ 注意：`tools/diag-steamcmd.sh` 里的探测用的是 `docker run`，**不会带上 compose 的
> `environment`**。所以它跑通、而 `docker compose` 起的主容器失败，这一点本身就是
> 「问题出在容器环境变量（代理）」的强证据 —— 主容器多出来的正好是那一层代理。

> Valve 官方文档明确写着 **不要在 root 用户下运行 SteamCMD**，主流服务端镜像也都用独立的
> `steam` 用户。T1 就是为这条准备的对照 —— 它跑通，就说明该把镜像改成非 root 运行。

**先跑自检，别再猜**

```bash
docker compose run --rm ark doctor
```

一次性打印身份、挂载点、文件系统类型、属主与权限、磁盘/inode 余量、**代理变量
（含「是不是旧容器固化的」判定）**、`steamapps` 是否创建、SteamCMD 日志末尾。
另外安装失败时，`docker compose logs` 里会**自动附带一版精简诊断**，可直接复制反馈。

**一键重置，从零重来**

```bash
bash tools/reset.sh               # 停+删容器、删镜像（数据保留）
bash tools/reset.sh --purge       # 连数据目录一起删（会先备份存档，再二次确认）
bash tools/reset.sh --purge --up  # 清完直接重新构建并启动
```

⚠ **改完 `.env` 后必须用这个脚本（或 `docker compose down && up --force-recreate`）** ——
`docker compose restart` 和 restart 策略都**不会**重读 `.env`，容器里的环境变量是
「创建那一刻」固化的。这正是「`.env` 里代理已经清空、容器却还在用旧代理」的成因。

### 16. 容器里 `steamcommunity.com` 解析成 `198.18.x.x`，是出问题了吗？

**大概率不是。** 这是宿主机代理软件（Clash / Surge / v2rayN 等）开启 **TUN + fake-ip**
后的正常现象。

**现象**

```bash
docker compose exec ark getent hosts steamcommunity.com
# 198.18.1.94     steamcommunity.com     ← 真实地址应该是 23.x 这类公网 IP
```

**为什么会拿到假 IP**

`198.18.0.0/15` 是 RFC 保留网段，**公网不路由**。fake-ip 模式下，代理软件对任何 DNS
查询都不返回真实 IP，而是从这个段里发一个假地址，同时自己记一张 `假IP → 域名` 的映射表。
等你真去连它时，虚拟网卡（Windows 上的 `Meta` 适配器）把包拦下来，查表还原出域名，
再按规则决定直连还是走代理。

这么做是为了**省掉真实 DNS 往返**（更快）和**避免 DNS 查询外泄**。

**唯一可靠的判据：实测能不能通**

```bash
docker compose exec ark curl -sS -o /dev/null -w '%{http_code}\n' --max-time 10 https://steamcommunity.com/
```

- 返回 `200` / `3xx`，甚至 `404`（根路径本来就没内容）⇒ **链路是通的**，假 IP 被正确接管，**不用管**
- 卡到超时 / `Could not resolve` / `Connection timed out` ⇒ 这才是真出问题

> ⚠ **别拿 `getent hosts` / `nslookup` 的结果当故障证据。** 看到 `198.18.x.x` 就断定
> 「网络有问题」是常见误判 —— 本项目排查过程中就踩过一次。

**什么时候假 IP 真的会坏事**

同样是拿到假 IP，两类名字的后果相反：

| 名字 | 拿到假 IP 的后果 |
| --- | --- |
| 公网域名（`steamcommunity.com`、`api.steampowered.com`…） | 通常**没事**，虚拟网卡会接管并还原 |
| `host.docker.internal` | **必坏** —— 它要真实回连宿主机，假地址连不回去 |

`host.docker.internal` 这条，正是 [FAQ 2](#2-steamcmd-下载慢或失败) 里「配了代理反而更差」
的原因之一。

**顺带：`[S_API FAIL] SteamAPI_Init() failed` 是什么**

它跟 fake-ip 无关。专用服务器上没有 Steam 客户端进程，这个初始化失败是**常态**，
成功启动的日志里同样有这一行。实际影响是**服务器不会出现在游戏内官方列表**，
玩家需要用直连 IP 加入（见 [FAQ 4](#4-玩家搜不到服务器)）。局域网直连与查询端口不受影响。

---

### 17. 服务端每隔几分钟就被重启一次，永远连不上

**现象**

- `docker ps` 里 `ark-server` 的存活时间永远停在几秒 / 一两分钟
- 日志里反复出现同一句：

  ```
  收到停止信号，向服务端发送 SIGINT（触发保存世界并优雅退出）…
  ```

- 服务端刚启动、端口刚监听，就被停掉了；下次开起来又要重新校验模组（大模组可能
  3 GB 以上），还没启动完就又被停
- `docker inspect` 里 `RestartCount=0`、`ExitCode=0`、`OOMKilled=false` —— 看起来
  完全"正常退出"，所以很难往 docker 身上想

**真因：WSL2 的空闲自动关机（跟本项目、跟 docker 都无关）**

WSL2 有两层独立的空闲计时器：

| 计时器 | 默认值 | 触发后做什么 |
| --- | --- | --- |
| 实例空闲（instance） | 约 8 秒 | 没有终端会话后终止该发行版实例，dockerd 随之停止 |
| **虚拟机空闲（VM）** | **60 秒** | 所有实例都终止后，把整个 WSL2 虚拟机**关机** |

只要最后一个 WSL 终端关闭，约一分钟后整个 VM 就被关掉。dockerd 停 → 所有容器
收到 `SIGTERM` → 本项目 entrypoint 的 `graceful_stop` 触发（就是上面那句日志）→
容器以退出码 0 正常退出。等你下次开终端，WSL 又启动、容器又被 `restart: unless-stopped`
拉起，但 ARK 还没启动完就再次被回收 —— **死循环**。

顺带解释一个反直觉的现象：**开着终端盯着它时不重启，一走开就重启。**
因为 VM 只在没有任何会话时才计时，挂着会话排查时永远看不到问题。

**验证方法**

```bash
# 第一次
wsl -d Ubuntu-24.04 -- bash -c "cut -d. -f1 /proc/uptime"   # 例如 33
# 关掉所有 WSL 终端，什么都不做等 95 秒
wsl -d Ubuntu-24.04 -- bash -c "cut -d. -f1 /proc/uptime"   # 变成 5 → VM 被重启了
```

uptime 不增反降，就是被回收了。

**修复：在 `%USERPROFILE%\.wslconfig` 里关掉两个计时器**

```ini
[general]
instanceIdleTimeout=-1

[wsl2]
vmIdleTimeout=-1
```

改完执行 `wsl --shutdown`，等约 10 秒再重新进 WSL 生效。之后：

```bash
# 空闲 3 分钟后再看，uptime 应该持续增长，容器不再重启
wsl -d Ubuntu-24.04 -- bash -c "cut -d. -f1 /proc/uptime; docker ps --format '{{.Status}}'"
```

**副作用**：WSL2 虚拟机会一直占用内存，不再自动释放。不用服务器时手动
`wsl --shutdown` 即可。

---

### 18. 容器显示 healthy，但服务端其实没在跑

**现象**：`docker ps` 显示 `(healthy)`，可端口没人监听、A2S 探测超时。

**真因**：健康检查命令

```yaml
test: ["CMD-SHELL", "pgrep -f ShooterGameServer >/dev/null 2>&1 || exit 1"]
```

`pgrep -f` 匹配的是**完整命令行**，而执行这条命令的 shell 自身的命令行里就含有
`ShooterGameServer` 这个字符串。`pgrep` 只会排除自己，**不会排除父进程 `sh -c`**
⇒ 永远能匹配到 ⇒ 永远返回 0 ⇒ 永远 healthy。

**修复**：把模式写成正则字符类，让它匹配不到命令自身：

```yaml
test: ["CMD-SHELL", "pgrep -f '[S]hooterGameServer' >/dev/null 2>&1 || exit 1"]
```

`'[S]hooterGameServer'` 作为正则仍能匹配真实的 `ShooterGameServer` 进程，
但字面量 `[S]hooterGameServer` 不匹配自身。

**验证**：`docker inspect ark-server --format '{{json .State.Health}}'`，
或临时 `docker compose exec ark pgrep -af '[S]hooterGameServer'`。

---

## 十、免责声明

- 本项目仅提供容器化部署工具与文档，**不包含任何游戏本体文件**，游戏资源由 SteamCMD 从 Valve 官方渠道下载。
- 请在遵守 [Steam 订阅者协议](https://store.steampowered.com/subscriber_agreement/) 与游戏厂商条款的前提下自行架设服务器，
  公网开服产生的一切后果由使用者自负。
- 模组版权归各自作者所有，本项目仅提供 Mod ID 配置能力，不分发模组文件。
- `SERVER_ADMIN_PASSWORD` / `SERVER_PASSWORD` 等敏感信息保存在 `.env` 中，请勿提交到公开仓库（`.gitignore` 已默认忽略）。

---

## 十一、开源许可证

本项目基于 [MIT License](LICENSE) 开源，可自由使用、修改与再分发，仅需保留版权声明。

方舟（ARK: Survival Evolved）及相关素材的版权归 Studio Wildcard 所有，本项目与之无从属关系。
