# 02 · 资产映射管理（AS-IS）

> **用途**：一份**当前真实状态**的资产映射说明 —— 表在哪、数据从哪来、怎么改才生效、现在缺什么。
> 补上 `shared/` 里长期缺的 **02** 号（`shared/04` 与多处代码注释都写着"资产映射见 `02`"，但文档一直不存在）。
>
> **本文的核实方式**（区分事实来源，别把二手结论当真源 ✗）：
> - **行数、缺漏、当前卡池覆盖**：2026-10-12 直连**线上 RDS**（`teyvat_guide`，经隧道 13306）实测 ✓；
> - **表结构、写入路径、热重载语义**：读代码确认（每条给路径:行号 ✓）；
> - **当前版本卡池**：`scripts/mihoyo-announce.mjs` 实时拉米游社公告 ✓（2026-10-12）。
>
> 相关但**不同**的文档：评分口径与权重来源 → `../ai/08`；缺漏清单历史 → `../ai/07` TODO-05；
> 部署与运维操作 → 主仓 `deploy/README.md` §3.7；资产核对配方 → `web/14`。

---

## 1. 一页速览（2026-10-12 线上实测）

| 项 | 现状 |
| --- | --- |
| 资产表张数 | **14 张**（§3），全部由 GORM `AutoMigrate` 建 / 维护，**仓库里没有任何 `.sql`** ✓ |
| 规模 | 角色 **124** / 武器 **255** / 套装 **65** / 套装效果 **128** / 词缀 **350** / 文案 **498** / 属性 **24** / 战斗属性 **15** / 部位 **5** |
| 权重类 | 推荐词条 `character_stat_weights` **124** / 评分权重 `character_relic_weights` **124** / 小助手口径 `character_relic_weights_mp` **152** / 规则 `character_relic_weight_rules` **9（已停用）** |
| 缺漏 | `missings` 共 **96 条**：**文案 93** + **属性 3** ✓（Top 8 条文案每条被命中 **110+ 次** ⇒ 不是偶发 ✗） |
| **当前版本（7.1）卡池覆盖** | **8/8 ✓** —— 丝柯克 / 爱可菲 / 沃雅妮莎 / 薇斯纳 + 苍耀 / 蝶变 / 香韵奏者 / 漩流颂歌 **全部在表里** ✓ |
| 核心口径 | **推荐词条（statWeights）导入只补缺、不覆盖** ✓；其余表是**覆盖式 upsert** ✓ |
| 最大隐患 | **运行时存在两个内存映射实例**（§5）⇒ 改完数据**必须**再调一次 `reload` ✓ |
| 写入路径 | **只有两条**：管理接口 `POST /api/admin/assets/import` ✓、CLI `server/cmd/assetimport` ✓ |

---

## 2. 数据从哪来

| 数据 | 来源 | 备注 |
| --- | --- | --- |
| 角色 / 武器 / 套装 / 文案 | **EnkaGameAssets**（`store/gi` 的 `avatars.json` / `weapons.json` / `relics.json` / `locs.json`） | 本地跑 `cmd/assetimport -dir <store/gi>` ✓ |
| 评分权重（V3，`character_relic_weights`） | **miao-plugin**（MIT）转译 | 脚本 `cmd/assetimport/gen-relic-weights.ps1` → 种子 `relic_weights_miao.json` |
| 推荐词条权重（小助手口径，`..._mp`） | 提瓦特小助手公式（用户提供截图整理） | **过渡兜底表**，见 §7 |
| 推荐词条（`character_stat_weights`） | 手工定档 + 生成器 | `scripts/gen-stat-weights.mjs`（输入 `stat_weights_source.json`） |
| 套装 2/4 件效果（`relic_set_effects`） | **人工整理** | Enka 不提供效果文本 ✓ |
| 文案 / 属性补录 | CLI 单文件模式（`-textmap-file` / `-fight-props-file` / `-affixes-file` / `-import-file`） | 配合 `/api/admin/assets/missing` 的清单 ✓ |
| 祈愿 UP 与起止时间 | 米游社公告 API（`scripts/mihoyo-announce.mjs`） | ⚠️ **探测样板，尚未产品化** ✓（"当前祈愿"功能的候选数据源 ✓） |

> 生成器里的种子文件（`*.json`）都写着同一句话：**种子是生成器输入、不是运行时真源** ✓ ——
> 运行时真源是**数据库表** ✓（改了 DB 才生效 ✓）。

---

## 3. 表清单（14 张）

⚠️ **表名无 `asset_` 前缀** ✗（`asset/service.go:5` 注明 2026-09-27 已校正）。
主仓 `AGENTS.md` §4.6/§4.7 里写的 `asset_*` / `asset_relic_slots` 是**旧称** ✗ —— 照那个名字写 SQL 会查不到表 ✓（2026-10-12 已同步修正 ✓）。

| 分组 | 表 | 主键 | 内容 |
| --- | --- | --- | --- |
| **身份映射** | `characters` | `id` | avatarId → 角色名 / 元素 / 星级 / 图标 |
| | `weapons` | `id` | weaponId → 武器名 / 星级 / 类型 |
| | `relic_sets` | `set_id` | setId → 套装名 |
| | `relic_slots` | `pos` | 部位枚举 → 中文部位名（**禁止硬编码** ✓） |
| **文案与词条** | `text_map_entries` | `hash` | StableHash → 中文文本 |
| | `prop_maps` | `prop_id` | PropID → 词条名 / 是否百分比 |
| | `fight_props` | `num_id` | 数字枚举 → PropID |
| | `affixes` | `id` | 词缀 id → PropType / 数值 |
| | `relic_set_effects` | `(set_id, piece)` | 套装 2/4 件效果文本（人工 ✓） |
| **权重与规则** | `character_stat_weights` | `character_id` | **推荐词条**（JSON payload）—— **只补缺不覆盖** ✓ |
| | `character_relic_weights` | `character_id` | **评分权重 V3**（miao 口径，10 维） |
| | `character_relic_weights_mp` | `(character_id, element)` | 小助手口径 7 维 —— **过渡兜底** ✓ |
| | `character_relic_weight_rules` | `id` | 角色词条权重规则 —— **已停用** ✓（9 条，仅留回滚） |
| **缺漏** | `missings` | `(kind, asset_id)` | 翻译层未命中的 ID + 命中次数 |

### 3.1 哪些表**不可替代**（与攻略语料 / RAG 的关系，2026-10-12）

结论：**资产映射与攻略语料是正交的两件事，映射不可替代** ✓ —— 它管的是**用户私有数据**的翻译（Enka ID → 中文 / 数值 / 评分），攻略语料管的是**公共知识**（配队 / 毕业线 / 天赋顺序）✓。

| 分组 | 语料能替代吗 | 理由 |
| --- | --- | --- |
| 身份映射（`characters` / `weapons` / `relic_sets` / `relic_slots`） | ✗ **绝不能** | 语料里没有 ID 字典；而且攻略卡（`character_guides.character_id`）**就挂在这张表上** |
| 文案与词条（`text_map_entries` / `prop_maps` / `fight_props` / `affixes`） | ✗ **绝不能** | 这是 **Enka 原始数据的翻译字典**，与语料无关 |
| 套装效果（`relic_set_effects`） | ⚠️ 部分 | 语料也会写，但结构表能回答"**我这套触发了吗**"（语料做不到） |
| 推荐词条（`character_stat_weights`） | ⚠️ **唯一真重叠** | 结构表能**分级 + 参与评分**，散文做不到 ⇒ **以结构表为准**；攻略卡**不重写词条**（见 `../ai/07` TODO-18） |
| 评分权重（`character_relic_weights` / `_mp` / `_rules`） | ✗ 不能 | 这是**算分**的输入，语料只给"该堆什么"的定性说法 |
| 缺漏（`missings`） | ✗ 不能 | Enka 数据完整性监控，与语料无关 |

> 反过来，攻略语料**依赖**这张地基 ✓：攻略卡要锚 `characters.id` ✓、注入时按"问题里的角色名 → ID"命中 ✓、攻略里提到的武器 / 套装名要与 `weapons` / `relic_sets` 对齐 ✓；Enka 一更新版本（新角色 / 新 hash），**映射不补，攻略卡连挂都挂不上** ✓。
>
> ⇒ 映射的维护（`../ai/07` TODO-15 补缺漏、TODO-16 修两个内存实例）**优先级不降反升** ✓。
> **顺带一个反哺**：攻略语料里出现的武器 / 套装名，若在映射表里查不到，就说明映射漏了 —— 可当作**缺漏巡检**的补充信号 ✓。

---

## 4. 写入路径与关键口径

**只有两条写入路径** ✓（全仓对资产表的直接写都在 `asset/import.go` ✓）：

1. `POST /api/admin/assets/import`（后台 → 管理接口 ✓，成功后**自动 reload** ✓）；
2. CLI `server/cmd/assetimport`（一次性批量导入 ✓）。

**关键口径（最容易踩）** ✓：

| 数据 | 导入语义 |
| --- | --- |
| `character_stat_weights`（推荐词条） | **只补缺、不覆盖** ✓ —— 同 key 保留**后台已有**的 weight / tier、后台独有的行留住、旅行者 byElement 保留 ✓（后台是编辑入口，导入不能把人工改的冲掉 ✗） |
| 其余所有表 | **覆盖式 upsert** ✓（`OnConflict{UpdateAll:true}`） |

### 4.1 空之杯不许给"不吃增伤"的角色（2026-10-12 ✓）

**判据（联网核实，逐条有出处）**：**月曜反应**（月感电 / 月绽放 / 月结晶）与**星烁反应**（星超导 / 星扩散）
**都不吃元素伤害加成** ——

- 百度百科《月曜反应》原话：**"不会受到元素伤害加成的增幅，有独立的增伤方式"** ✓；
- 星超导攻略原话：**"星超导反应不吃传统元素伤害加成，千万别带冰伤杯，攻击杯是唯一标准答案"** ✓；
  百度百科《星烁反应》：触发者 = **桑多涅（愚人众「木偶」）/ 奥黛塔 / 旅行者·冰** ✓；
- 米游社《伊涅芙指南》：月感电伤害**"不受普通增伤区（伤害加成杯）影响"** ✓（吃精通 + 双暴 + 减抗 ✓）。

⇒ 这些角色的杯只该是 **攻击力 / 生命值 / 防御力 / 元素精通** ✓（**星体系里的冰主也必须避开冰伤杯** ✓）。

**落点（三处，缺一不可）**：

| 在哪 | 怎么表达 |
| --- | --- |
| 生产库（**运行时真源** ✓） | `character_stat_weights.payload.mainStats` —— 改这里才立刻生效 ✓（后台「资产映射」或直接 SQL ✓） |
| 种子（重建 / 新角色的初值 ✓） | `server/cmd/assetimport/stat_weights_source.json` 的 **`noElementGoblet`**（月/星名单，13 个 id ✓）与 **`overrides`**（逐角色主词条定稿，24 条 ✓）—— **数据不入代码** ✓ |
| 生成器 | `scripts/gen-stat-weights.mjs`：名单内角色按原型把 `{E}元素伤害加成` 换成非元素主词条 ✓；**`overrides` 最后套用**（优先于原型、`withAlternatives` 与 `manual` ✓） |

⚠️ **两个坑**（2026-10-12 都踩到了 ✓）：

1. **`SUP_ER`（"通用充能辅助"）原型**原先**杯/冠照输出写**（元素增伤 + 暴击率）✗ ⇒ 只要角色被定成这个原型，
   哪怕是纯拐 / 盾 / 奶，杯上也自动挂了元素增伤 ✓ —— **已改为 杯=攻击力** ✓（真吃暴击的九条裟罗 / 珐露珊 / 柯莱 用 `overrides` 定稿 ✓）；
2. **`manual`（人工定稿）块**原先**直接 return、不走 `overrides`** ✗ ⇒ 库里改了、重生成的产物却是旧值 ✓
   —— **已改为 manual 也最后套用 `overrides`** ✓，菲林斯那处过期数据同步修正 ✓。

**改完必须**（与 §5 同一口径 ✓）：`POST /api/admin/assets/reload?purgeSnapshots=true` ✓ ——
推荐词条会进**档案快照** ✗，不带 `purgeSnapshots` 的话用户看到的还是旧值 ✓。

> 附带：翻译层未命中时会实时 `ReportMissing(kind,id)`（`missings` 命中次数 +1 ✓），并在档案里追加
> warning「存在 N 类未映射的游戏资产，已记录待补录」✓ —— 所以缺漏**是用户可见**的 ✗，不是内部指标 ✓。

---

## 5. 运行时与热重载（本节的坑最值钱）

- 启动时 `asset.Load()` 把上面所有映射表**全量读进内存** ✓，打日志 `asset maps loaded{...}` ✓（含各类计数 ✓），此后翻译零 SQL ✓。
- `Reload()` = **重跑一次 `Load()`** ✓（`asset/service.go`）。
- ⚠️ **`asset.Service` 存在两个内存实例**（2026-10-12 读码确认 ✓，问题本身仍未在代码层修复 ✗）：
  - 实例 **A**：`router.go:71` `assets := asset.New(...)` → 供**管理接口**（import / missing / reload）使用 ✓；
  - 实例 **B**：`player.go:71` `NewPlayerService()` 内部又 `asset.New(db)` + `Load()` ✓ → 供**翻译链路**（玩家档案、AI 上下文）使用 ✓。
  - `import` 走 A（A 侧 import 后会自刷新 ✓），而**翻译用的是 B** ✗ ⇒ **只 import 不 reload，用户看到的仍是旧翻译** ✗；
  - `reload` 走 B ✓（`player.go:315 ReloadAssets`）⇒ **两边的正确顺序是：先 import、再 reload** ✓✓。
- ⚠️ **改"会进快照"的数据时必须 `?purgeSnapshots=true`** ✓：推荐词条 `card.statWeights` 会被写进档案快照 ✓，
  不清快照接口读到的还是旧值 ✗（2026-09-27 实测踩过：`0/12` ✓，见 `../ai/07` TODO-10 §3）。
  只改**不进快照**的东西（如 AI 上下文文案）不用清 ✓。

**所以改数据的标准动作是** ✓：

```bash
# ① 导入（例如后台"资产映射"页保存，或直接打接口）
curl -X POST -H "X-Admin-Key: $KEY" -H 'Content-Type: application/json' \
     -d @payload.json http://127.0.0.1:8080/api/admin/assets/import
# ② 再 reload（本次改了翻译/权重相关数据 ⇒ 带 purgeSnapshots）
curl -X POST -H "X-Admin-Key: $KEY" \
     "http://127.0.0.1:8080/api/admin/assets/reload?purgeSnapshots=true"
```

---

## 6. 管理接口（4 个）

整组挂在 `/api/admin/assets/*`，鉴权头 **`X-Admin-Key`** ✓（值为 `auth.admin_key`；**未配置时回落 `auth.jwt_secret`** ✗ 并启动告警 —— 回落状态下"泄露 admin_key"等于泄露签发用户 Token 的密钥 ✗，所以正式环境必须显式配置 ✓）。

| 接口 | 作用 | 返回 |
| --- | --- | --- |
| `POST /api/admin/assets/import` | 批量 upsert 映射数据；成功后**自动 reload（A 实例）** ✓ | 各类计数 |
| `GET /api/admin/assets/missing?limit=` | 缺漏清单（按命中次数倒序 ✓，默认 100 / 上限 1000） | `{items,total}` |
| `POST /api/admin/assets/reload[?purgeSnapshots=true]` | 手动重载（**B 实例** ✓）+ 可选清档案快照 | `{reloaded,snapshotsPurged}` |
| `POST /api/admin/assets/purge-snapshots` | 只清档案快照（不动映射 ✓） | `{purged:true}` |

> ⚠️ `purge-snapshots` 清的是**缓存**（`player_profile_snapshots`）✓，
> **不会**碰 `player_characters`（用户已收录角色池，只增不删 ✓）—— 两者刻意分表 ✓，别混 ✗。

---

## 7. 现状盘点与已知缺口

### 7.1 缺漏（`missings`，2026-10-12 实测 96 条）

| 类型 | 条数 | 说明 |
| --- | --- | --- |
| `text` | **93** | 文案 hash 未命中（`text_map_entries` 缺）✓ |
| `prop` | **3** | 属性词条未命中（`prop_maps` 缺）✓ |

Top 命中（说明是**高频**缺漏 ✗，不是边角）：

| kind | asset_id（hash） | 命中次数 |
| --- | --- | --- |
| text | 1309660612 | 112 |
| text | 1975574836 | 111 |
| text | 1533553124 / 2583081228 / 3137512604 / 3114684628 / 643777884 | 110 |
| text | 3250175276 | 109 |

> ⚠️ **趋势要盯**：`../ai/07` TODO-05 记的是"文本未命中 **68** 条"，现在 **93** 条 ⇒ **在增长** ✓
> （每有新角色/新活动文案没补录就会涨 ✓，而且每次命中都会给用户档案挂一条 warning ✗）。

### 7.2 其它已知缺口（逐条带出处）

| # | 缺口 | 出处 | 影响 |
| --- | --- | --- | --- |
| 1 | **两个内存实例**未在代码层修复（靠"import + reload"的纪律绕开 ✓） | §5；`../ai/07` TODO-10 §3 | 忘调 reload ⇒ 用户看到旧翻译 ✗ |
| 2 | `character_relic_weights_mp` 是**过渡兜底表**（不是编辑入口 ✓） | `asset/service.go` 注释 | 结构与 mp 公式相关，勿当长期真源 ✗ |
| 3 | mp 权重表**内嵌在代码里**（`go:embed`），"DB 化"是下一步 ✓ | `asset/relic_score_mp.go` | 改权重需发版 ✗ |
| 4 | `StatRecommendation.Score`（旧评分权重块）**deprecated 可删**（迁移已完成 ✓） | `asset/model.go` | 代码里还留着兼容分支 ✓ |
| 5 | `character_relic_weight_rules` 9 条**已停用**（无生产调用点 ✓），仅留回滚 | `asset/relic_score.go` | 别以为是活的 ✗ |
| 6 | 旅行者「套件号 → 元素」只登记 **1 格**（705=冰 ✓），其余六格**待真实账号实测** | `enka/translate.go`；`../ai/07` TODO-13 | 切元素后元素相关计算会偏 ✗ |
| 7 | 武器"推荐角色"表**未建** ⇒ 用 prompt 规则兜底 | `../ai/07` TODO-05 | 推荐武器/套装回答偏泛 ✓ |
| 8 | `props_resist.json` 文件名是**错标来源**，暂留名 + 记录为凭 ✓ | `../ai/07` TODO-05 | 看文件名的字面意思会误解 ✗ |
| 9 | 文案缺漏**在增长**（68 → 93，§7.1） | 本文实测 | 用户可见 warning ✗ |
| 10 | 祈愿数据（米游社公告）**只是探测样板**，未产品化 ✓ | `scripts/mihoyo-announce.mjs` | "当前祈愿"功能尚无数据源 ✓ |

### 7.3 好消息：当前版本覆盖是满的 ✓

2026-10-12 联网拉米游社公告，把**当前 7.1 两期卡池**的角色与武器逐个回表核对：

| 类型 | 名称（公告口径） | 表 | id |
| --- | --- | --- | --- |
| 角色 | 虚渊暗星·**丝柯克**(冰) | `characters` | 10000114 ✓ |
| 角色 | 明绚千韵·**爱可菲**(冰) | `characters` | 10000112 ✓ |
| 角色 | 幽歌萦渊·**沃雅妮莎**(水) | `characters` | 10000140 ✓ |
| 角色 | 雪宴之锋·**薇斯纳**(风) | `characters` | 10000143 ✓ |
| 武器 | 单手剑·**苍耀** | `weapons` | 11517 ✓ |
| 武器 | 单手剑·**蝶变** | `weapons` | 11522 ✓ |
| 武器 | 长柄武器·**香韵奏者** | `weapons` | 13514 ✓ |
| 武器 | 法器·**漩流颂歌** | `weapons` | 14524 ✓ |

⇒ **8/8 命中** ✓ —— 角色/武器映射**跟得上版本** ✓；缺的是**文案**（93 条）而不是实体 ✓，
这条结论对"缺漏优先级"很有用 ✓：**先补 text_map_entries，别急着导角色** ✓。

---

### 7.4 数据变更记录（人工改动，逐条留痕）

> 为什么记在这里：下面这些是**人工直接改库**的内容改动（不是导入管线产生的 ✓）。
> 出问题时要能一眼看到"什么时候改了什么、怎么回滚" ✓。

| 日期 | 表 | 改动 | 影响面（**先想清楚这个** ✓） | 回滚点 |
| --- | --- | --- | --- | --- |
| 2026-10-12 | `character_stat_weights` | 用户要求：**空之杯主词条推荐元素伤害**的角色，`subStats` 里也要带上**同名元素伤害**并置 `tier=primary`（金色主要 ✓）。实际：**61 行新增** ✓ + **1 行**由 `secondary/50` 升为 `primary/5` ✓；已有 `primary` 的 **16 行原样不动** ✓（不覆盖人工数据 ✗）。`weight` 沿用用户既有约定 **5**（金色主要 + 数值优先级刻意压低 ✓）。命中集共 **78 行**（= 元素伤害合计 ✓；`物理伤害加成` 4 行**未处理** ✓）。⚠️ 元素→枚举名直接取自数据本身：`FIGHT_PROP_{FIRE,WATER,ELEC,ICE,WIND,ROCK,GRASS}_ADD_HURT` ✓ | **只影响"推荐词条"的展示与 AI 上下文** ✓：评分**不受影响** ✓（`ScoreRelic` 走 `character_relic_weights`，不读 `subStats[].weight` ✓）；⚠️ 圣遗物副词条**不可能**出现元素伤害 ⇒ 档案页「有效词条」统计**不会**因此增加 ✓（它按真实副词条匹配 ✓） | `deploy/out/stat-weights-backup-20261012.tsv`（整表 **124** 行 ✓）、`deploy/out/stat-weights-hit-rows.tsv`（命中 **78** 行 ✓）、`deploy/out/fix-element-goblet.sql`（逐行 UPDATE ✓）—— 均在 `deploy/out/`（已 gitignore ✓） |

> ⚠️ **生效动作（必须做，否则用户仍看旧推荐 ✗）**：`POST /api/admin/assets/reload?purgeSnapshots=true`
> —— 已对**本机 8080** 与**云上（经隧道 18080）**各执行一次，均返回 `{reloaded:true, snapshotsPurged:true}` ✓。
>
> **验收（线上真档案）**：`GET /api/genshin/player?uid=197794747&refresh=true` 返回的 12 个角色中 **7 个命中** ✓，
> 其 `subStats` 里的元素伤害均为 `tier=primary` / `weight=5` ✓，且**中文名翻译正常** ✓
> （丝柯克→冰 ✓、芙宁娜/哥伦比娅→水 ✓、兹白→岩 ✓、菲林斯/伊涅芙→雷 ✓、杜林→火 ✓）。

---

| 2026-10-12 | `character_stat_weights`（**空之杯主词条**） | 用户核查："**不吃元素增伤的角色也被挂上了元素增伤杯**" ✗ ⇒ 逐一联网核对后修正 **14 行** ✓：**月曜体系** —— 伊涅芙（雷伤→**攻击力**）、哥伦比娅（水伤→**生命值**，沙 攻击→**充能**）、兹白（岩伤→**防御力**，沙 攻击→**防御力**）、爱诺（水伤→**元素精通**，冠 暴击→**精通**）、叶洛亚（岩伤→**元素精通**，冠 暴击→**精通**）；**辅助向** —— 九条裟罗 / 伊安珊 / 珐露珊（→攻击力）、坎蒂丝 / 塔利雅（→生命值）、茜特菈莉（→元素精通）、柯莱（→元素精通，冠→双暴）、旅行者·空 / 荧（→元素精通 + 精通冠）。依据：**月曜 / 星烁反应不吃元素增伤**（百度百科《月曜反应》《星烁反应》+ 各角色攻略，逐条见 §4.1）✓；**元素增伤杯 75 → 61 行** ✓ | 运行时真源是库 ✓ ⇒ 已直接改库 + `reload?purgeSnapshots=true` ✓（返回 `{"reloaded":true,"snapshotsPurged":true}` ✓）；种子侧加 `noElementGoblet`(13) + `overrides`(24) ✓、修 `SUP_ER` 模板与 `manual` 分支 ✓，重生成的产物与库 **0 不一致** ✓ | `deploy/out/stat-weights-backup-20261012-goblet.json`（改动前 14 行整值 ✓，已 gitignore ✓） |

## 8. 操作手册（怎么改数据才生效 ✓）

| 想做的事 | 做法 |
| --- | --- |
| 新增/更新角色、武器、套装 | 跑 `cmd/assetimport -dir <EnkaGameAssets/store/gi>` ✓ 或走后台导入 ✓ |
| 改推荐词条（这是**后台的地盘** ✓） | 后台「资产映射」编辑 ✓ —— 导入**不会**覆盖它 ✓ |
| 补文案（`text` 缺漏） | 用 `-textmap-file` 指定只补 `missings` 里 kind=text 的 hash ✓（`cmd/assetimport/main.go`） |
| 看还缺什么 | `GET /api/admin/assets/missing?limit=200`（按命中次数倒序 ⇒ 优先补 Top ✓） |
| 让改动**对用户生效** | **再调 `reload?purgeSnapshots=true`** ✓（§5：翻译用的是另一个实例 ✓） |
| 只改 AI 上下文文案（不进快照） | 不用 purge ✓，但**仍要 reload** ✓ |
| 库连不上（本机） | 先起隧道 `scripts/tunnel-remote.ps1`（RDS 内网 3306 → 本机 13306 ✓） |

---

## 9. 与其它文档的关系

| 想知道 | 看 |
| --- | --- |
| 评分怎么算、档位怎么定、权重列的含义 | `../ai/08-圣遗物评分设计与落地.md` |
| 缺漏/权重的**历史待办**（TODO-05 / 10 / 13） | `../ai/07-待办与问题记录.md` |
| 资产映射在**权限边界**里的定位（为什么走直连是安全的） | `04-用户体系与鉴权边界设计.md` §2 |
| 线上部署、镜像、容器内验证 | 主仓 `deploy/README.md`（§3.7 后台 → 云上主服务） |
| 核对线上资产是否与本地一致 | `web/14`（运维配方）+ `deploy/out/verify-*.ps1` |
| C 端接口契约（档案 / 已收录角色） | `../web/04-API接口文档.md` §4.1 / §4.1.1 |

> ⚠️ **两份口径都要记住**：本文件是**现状（AS-IS）** ✓；`../ai/08` 是**评分设计** ✓。
> 数据改了而本文的 §1/§7 数字过期时，**以库为准** ✓（本文数字都带实测日期 ✓，别当永久真值 ✗）。
