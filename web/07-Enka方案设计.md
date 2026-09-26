# 07 · Enka.Network 数据源方案设计

> 状态：**待评审**
> 背景：米游社方案因端点级强制风控（1034）放弃，全面转向 Enka.Network（免登录、免风控、免签名）。
> 核心决策：**角色/武器/圣遗物等映射数据存 MySQL，代码零硬编码，新版本角色只需补数据不需改代码。**

---

## 1. 总体架构

```
前端（账号信息页：输入 UID → 查询）
        │
        ▼
后端 PlayerService（编排）
        │
        ├─① EnkaClient ──► enka.network/api/uid/{uid}/   （无认证，内存缓存 60s）
        │
        ├─② AssetService（翻译层）
        │     内存映射表（启动时从 MySQL 全量加载）
        │     avatarId / weaponId / setId / textHash → 中文名、元素、星级、图标
        │     未命中 → asset_missing 表收集 + fallback 显示
        │
        └─③ 输出统一 PlayerProfile（结构化、人类可读）
```

**职责边界**：
- Enka 只负责「拉原始数据」（ID 和 hash）；
- MySQL 负责「映射数据的持久存储」；
- 内存负责「高频翻译零 SQL 压力」；
- 米游社相关代码全部移除（见 §7 清理清单）。

## 2. 数据能力边界（先说清楚）

| 数据 | Enka 有无 | 说明 |
| --- | --- | --- |
| 昵称 / 等级 / 签名 / 世界等级 | ✅ | playerInfo 直读 |
| 成就数 | ✅ | finishAchievementNum |
| **展柜角色**（最多 8 个） | ✅ | 等级 / 命座 / 好感 / 武器 / 圣遗物明细 |
| 全部角色列表、深渊战绩、探索度 | ❌ | 米游社独有，本方案不再提供 |
| 角色基础属性（生命/攻击等） | ✅ | propMap 数值，词条名需映射 |

页面相应调整：档案展示「展柜角色」；深渊/探索度区块移除。

## 3. 数据库设计（MySQL · teyvat_guide 库 · utf8mb4）

### 3.1 映射表（前缀 asset_，均为读多写少，无外键）

```sql
-- 角色（avatarId → 展示信息）
CREATE TABLE asset_characters (
  id          BIGINT PRIMARY KEY,          -- avatarId，如 10000002
  name        VARCHAR(64)  NOT NULL,       -- 中文名：神里绫华
  en_name     VARCHAR(64)  NOT NULL,
  element     VARCHAR(16)  NOT NULL,       -- 冰/水/火/雷/风/岩/草
  rarity      TINYINT      NOT NULL,       -- 4 / 5
  icon        VARCHAR(128) NOT NULL,       -- UI_AvatarIcon_XXX（拼 enka 图片 URL）
  updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 武器
CREATE TABLE asset_weapons (
  id          BIGINT PRIMARY KEY,          -- weaponId
  name        VARCHAR(64)  NOT NULL,
  en_name     VARCHAR(64)  NOT NULL,
  rarity      TINYINT      NOT NULL,
  type        VARCHAR(32)  NOT NULL,       -- 单手剑/弓/法器/长柄武器/双手剑
  icon        VARCHAR(128) NOT NULL,
  updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 圣遗物套装
CREATE TABLE asset_relic_sets (
  set_id      INT PRIMARY KEY,
  name        VARCHAR(64)  NOT NULL,
  icon        VARCHAR(128) NOT NULL,
  updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

-- 文本映射（StableHash → 中文），武器/圣遗物等名称的通用兜底
CREATE TABLE asset_text_map (
  hash        BIGINT PRIMARY KEY,          -- nameTextMapHash
  text        VARCHAR(255) NOT NULL
);

-- 属性 ID → 词条名（圣遗物主/副词条翻译）
CREATE TABLE asset_prop_map (
  prop_id     VARCHAR(32) PRIMARY KEY,     -- FIGHT_PROP_HP / FIGHT_PROP_CRITICAL...
  name        VARCHAR(32)  NOT NULL,       -- 生命值 / 暴击率
  percent     TINYINT      NOT NULL        -- 1=百分比词条
);

-- 翻译缺漏收集（补录依据，不阻塞查询）
CREATE TABLE asset_missing (
  kind        VARCHAR(16)  NOT NULL,       -- character | weapon | relic_set | text | prop
  asset_id    VARCHAR(64)  NOT NULL,
  first_seen  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  hit_count   INT NOT NULL DEFAULT 1,
  PRIMARY KEY (kind, asset_id)
);
```

### 3.2 Enka 响应缓存（可先内存，预留表结构）

```sql
CREATE TABLE enka_cache (
  uid         VARCHAR(16) PRIMARY KEY,
  payload     JSON NOT NULL,
  expires_at  DATETIME NOT NULL
);
-- M1 用进程内 map + singleflight；跨实例部署时切换此表
```

## 4. 映射数据管理（核心：不改代码完成维护）

### 4.1 运行时策略

- **启动**：AssetService 全量加载五张映射表进内存（总量 <10MB，毫秒级）。
- **查询**：全部走内存 map，翻译零 SQL。
- **未命中**：返回 fallback（`未知角色 #10000123`）+ 异步 upsert `asset_missing`（hit_count 累加）。
- **生效**：导入/补录接口成功后触发内存 reload，**立即生效，无需重启**。

### 4.2 更新通道（三个，全部不改代码）

| 通道 | 用途 | 说明 |
| --- | --- | --- |
| `POST /api/admin/assets/import` | 批量 upsert | JSON body 按表分组，管理员 JWT 保护 |
| `GET /api/admin/assets/missing` | 查缺补漏 | 按 hit_count 排序，导出待补录清单 |
| `cmd/assetimport` CLI | 初始全量导入 | 读 JSON 文件入库（首次铺数据用） |

### 4.2.1 数据落位规则（2026-09-26 定）

> 一句话：**能进数据库的，都进数据库；仓里只留"种子 + 生成器"。**

| 角色 | 是谁 | 规矩 |
| --- | --- | --- |
| **运行时真源** | `asset_*` / `character_stat_weights` 等表（启动全量加载进内存，翻译零 SQL） | 唯一权威；应用**只读库**，不读仓内 JSON |
| **写路径（只此两条）** | ① 后台「资产映射管理」（角色/武器/套装/套装效果/推荐词条，写后自动 reload）② `POST /api/admin/assets/import`（批量） | 单点修改走后台；批量/重建走接口或 CLI |
| **种子（入仓）** | `server/cmd/assetimport/*.json` 中**上游拿不到、只能人工维护**的那些（`prop_maps` / `relic_slots` / `fight_props` / `props_*.json` / `relic_set_effects.json` / `stat_weights_source.json`） | 只用于**首次铺底与灾难重建**；用完以库为准，**不要反向回写** |
| **生成物（不入仓）** | `stat_weights_full.json`（由 `scripts/gen-stat-weights.mjs` 生成） | 已 gitignore；每次导入现场生成即可 |
| **代码** | `gen-stat-weights.mjs` 只保留**逻辑与模板**（ARCHETYPES + build 流程） | **数据不入代码**：逐角色定档与人工覆盖已外置到 `stat_weights_source.json`（`AGENTS.md` §4.4 / §7-13 的硬要求） |

配套事实：`prop_maps` 在后台**目前只能看不能改**（`AssetMappingPanel` 只 load 未提供 save）——
补上编辑入口前，词条名修正仍走接口/脚本（见 `../ai/07` TODO-05 §8）。

### 4.3 初始数据源

1. 首选 [Escartem/EnkaGameAssets](https://github.com/Escartem/EnkaGameAssets)：官方 Excel 的社区转换，含角色/武器/圣遗物/文本多语言 JSON。
2. 兜底 [Dimbreath/AnimeGameData](https://github.com/Dimbreath/AnimeGameData)（游戏解包 Excel）。
3. 由 CLI 转换导入；转换脚本一次性，后续新版本角色直接下载新 JSON 重新导入。

> 📚 **实际使用的数据源、抽文件姿势、缺漏补齐流程与踩坑清单，见 `14-游戏资产中文文本获取手册.md`**
> （2026-09-26 成文）：主源实为 `EnkaNetwork/API-docs` 的 `store/gi`（用 `git fetch`+`git show` 抽文件），
> 游戏原表走 `DimbreathBot/AnimeGameData`（GitHub raw 媒体类型）；「hash 键」与「名字键」的区别是选源的关键。

## 5. 后端模块设计（严格遵循现有分层）

```
internal/service/asset/
├─ model.go        # 五张映射表 + asset_missing 的 GORM 模型
├─ service.go      # AssetService：全量加载、翻译接口、missing 收集、reload
└─ import.go       # ImportAssets(payload) 批量 upsert（事务）

internal/service/enka/
├─ model.go        # Enka 原始响应结构（playerInfo / avatarInfoList 摘要字段）
├─ client.go       # HTTP + 内存缓存(60s) + 负缓存(5min) + singleflight + 错误映射
└─ translate.go    # Enka 原始数据 → dto（依赖 AssetService）

internal/handler/asset.go + router 注册：
├─ POST /api/admin/assets/import    （JWT 保护）
├─ GET  /api/admin/assets/missing   （JWT 保护）
└─ POST /api/admin/assets/reload    （JWT 保护）
```

## 6. 对外 API（对前端保持 `/api/genshin/player?uid=` 不变）

```jsonc
// 响应（重构后）
{
  "code": 0,
  "data": {
    "source": "enka",
    "uid": "197794747",
    "nickname": "…",
    "level": 60,
    "signature": "…",
    "worldLevel": 8,
    "achievements": 812,
    "characters": [            // 展柜角色（≤8）
      {
        "id": 10000002,
        "name": "神里绫华",     // 来自 asset_characters，未命中为 "未知角色 #id"
        "element": "冰",
        "rarity": 5,
        "level": 90,
        "constellation": 3,    // talentIdList 长度
        "fetter": 10,
        "iconUrl": "https://enka.network/ui/UI_AvatarIcon_…png",
        "weapon": { "name": "雾切之回光", "rarity": 5, "level": 90, "affix": 1 },
        "relics": [ { "set": "冰风迷途的勇士", "pos": "时之沙", "level": 20, "mainStat": "攻击力" } ]
      }
    ],
    "warnings": ["3 个词条未映射，已提交补录"]   // 翻译缺漏提示，非致命
  }
}
```

**错误映射**：上游 400 → 404「玩家不存在或未公开」；424 → 503「游戏维护中」；429 → 503「上游限流」；网络错误 → 502。

## 7. 米游社代码清理清单（放弃项）

| 位置 | 处理 |
| --- | --- |
| `server/internal/service/mihoyo/`（client/qrcode/verification/model） | **删除** |
| `handler/genshin.go` 中 record-card / qr / verification / cookie 方法 | **删除**，Player 保留改走 Enka |
| `router.go` 对应路由、`config.Mihoyo`、`config.yaml` mihoyo 段、`.env.example` | **删除** |
| `dto/genshin.go` 中 QR / Verification / RecordCard / Cookie 相关 | **删除** |
| `web`：Cookie 卡片、扫码卡片、极验组件、`api/genshin.ts` 对应方法、i18n 相关 key | **删除**，页面简化为「UID 查询 + 档案展示」 |
| `model`（chat 会话表）与对话模块 | **保留**（与米游社无关） |
| `MIGRATION_NOTES.md` / `WEB_SERVER_DEV_GUIDE.md` | **保留**作参考存档（已随本目录迁入共享仓 `teyvat-docs/web/`） |

## 8. 里程碑与工作量

| 阶段 | 内容 | 规模 |
| --- | --- | --- |
| D1 | asset 表 + AssetService（加载/翻译/missing/import） | 中 |
| D2 | Enka client + 缓存 + translate 输出 | 中 |
| D3 | API 整合 + 米游社清理（后端） | 小 |
| D4 | 前端适配（档案页改版 + 清理） | 中 |
| D5 | 初始映射数据获取与导入（EnkaGameAssets → JSON → CLI） | 中，一次性 |

## 9. 风险与对策

| 风险 | 对策 |
| --- | --- |
| Enka 无 SLA / 临时不可用 | 内存缓存 + 503 明确提示；保留错误映射 |
| 初始映射数据不全 | asset_missing 收集 + 管理接口补录，不阻塞查询 |
| 新版本角色上线 | 下载新 JSON → import，代码零改动 |
| 恶意扫号打穿上游 | UID 负缓存 5 分钟 + 全局限速 |
| 展柜为空 | 页面明确提示「对方未摆放角色展柜或未公开信息」 |
