# 04 · API 接口文档

基础路径：`http://localhost:8080/api`（前端通过 Vite 代理使用 `/api`）
统一响应：`{ "code": 0, "message": "ok", "data": ... }`，`code !== 0` 表示业务失败。

## 错误码

| code | HTTP | 含义 |
| --- | --- | --- |
| 0 | 200 | 成功 |
| 400 | 400 | 参数错误 |
| 401 | 401 | 未登录 / 凭证无效 |
| 404 | 404 | 玩家不存在或未公开 |
| 409 | 409 | 用户名已存在 |
| 500 | 500 | 服务内部错误 |
| 502 | 502 | 上游错误 |
| 503 | 503 | 上游限流 / 游戏维护 |

---

## 1. 健康检查

`GET /api/health`

```json
{
  "code": 0,
  "message": "ok",
  "data": { "status": "up", "version": "0.1.0", "time": "2026-09-10T10:00:00+08:00" }
}
```

---

## 2. 对话

`POST /api/chat`

| 字段 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| sessionId | string | 否 | 为空则创建新会话 |
| message | string | 是 | 用户提问，最长 4000 字符 |
| stream | bool | 否 | `true` 走 SSE 流式（见 §2.2），缺省为非流式 |

**鉴权语义（2026-09-14 变更：`/api/chat` 改为强制登录）**：

| 接口 | 未带 `Authorization` | 带了但无效 / 过期 |
| --- | --- | --- |
| `POST /api/chat` | **401 `请先登录后再使用 AI 问答`** —— **匿名不再具备 AI 对话能力**（2026-09-14 变更） | 401 `登录状态已失效，请重新登录` |
| `/api/genshin/*`（只读） | 放行，按匿名处理 | 401 `登录状态已失效，请重新登录` |

**为什么匿名禁用**：token 是花钱的，匿名消耗无归属、不可审计，也没有任何频率与配额手段（设计见 `shared-docs/05-AI使用边界设计（匿名·配额·内容治理）.md` §1）。
匿名用户在对话页看到的是**预设问答**（`GET /api/preset-qa`，见 §2.5），且前端**在提问前**就拦住（输入框禁用 + 登录引导），不让用户打完字才吃 401。

> 两次行为变更在同一条线上：2026-09-12 起，**带了无效 Token 不再静默降级为匿名**（否则用户以为还登录着，实际会话归属、面板注入、封禁联动全部失效，后台也认不出数据归属）；2026-09-14 起，**未带 Token 也不再放行**。前端收到 401 会清凭据并回登录页（`api/client.ts` 的 `handleUnauthorized`，axios 与流式 `fetch` 两条路径都会处理），匿名则留在预设问答页并给登录入口。

**历史组装（两种模式一致）**：取本会话**最近 20 条**消息为上限，再按 **1200 tokens 预算**从最近往前裁剪（超预算即截断，但始终保留最新一条）；同时
①丢弃尾部与本次提问相同的那条 user 消息（提问由 `prompt` 字段单独下发，重复发送会重复计费并干扰模型）；
②过滤降级兜底文案（不承载有效信息，留在上下文会污染后续对话）。
裁剪只影响发给模型的内容，落库始终完整。

### 2.1 非流式（`stream` 缺省/false）

**响应 data**：`{ sessionId, reply, tokens, elapsedMs }`

### 2.2 流式（`stream=true`，SSE）

响应头 `Content-Type: text/event-stream`；帧格式（与 AI 服务 `shared-docs/01-接口契约.md` §6 同构，但**事件流没有外层信封**）：

```
event: session
data: {"sessionId":"166f3ff1-bc35-4384-8544-cf2980714ffa"}

event: delta
data: {"text":"胡桃"}

event: delta
data: {"text":"是往生堂第七十七代堂主"}

event: done
data: {"sessionId":"166f3ff1-...","tokens":633,"elapsedMs":1606}
```

| 事件 | `data` | 说明 |
| --- | --- | --- |
| `session` | `{sessionId}` | **首个事件**，先于任何增量；流中断时前端也能保留会话归属 |
| `delta` | `{text}` | 增量文本，可多次 |
| `done` | `{sessionId, tokens, elapsedMs}` | **唯一终止成功事件** |
| `error` | `{message}` | 已脱敏的提示文案；出现后连接结束（HTTP 已是 200，不能只看状态码） |

**事件序列**：`session` → `delta*` → (`done` | `error`)，不会出现 `done` 之后还有 `delta`。

**降级语义**：
- AI 服务不可用且**一个增量都未产出** → 仍返回 HTTP 200，把兜底文案作为 `delta` 下发，随后 `done`（与非流式一致，用户始终能看到可读回复）；
- 已产出部分内容后上游失败 → 正常关闭并下发 `error`（文案已脱敏，前端保留已生成内容并提示）；
- 客户端断连 → 服务端停止产出并结束请求，不再占用上游配额。

**注意**：经反向代理（Nginx）时必须关闭响应缓冲，否则会被攒包一次性吐出：
`proxy_buffering off; proxy_read_timeout 120s;`。前端由 `web/src/api/chat.ts` 用 `fetch` + `ReadableStream` 逐行解析（`axios` 无法读取浏览器流）。

### 2.3 AI 后端与降级（两种模式通用）

**AI 后端**：`ai.provider` 决定，`mock`（**代码内置默认**）/`openai`（直连）/ **`remote`（当前 `config.yaml` 配的值，对接独立 AI 派蒙服务）**。
remote 模式下非流式调 `POST /v1/complete`、流式调 `POST /v1/complete/stream`（`X-AI-Key` 鉴权），AI 服务不可用或超时时**降级**（见 §2.2 与下述要点）：错误明细只进服务端日志，不向前端暴露。系统提示词留空则由 AI 服务提供人格。详见 `docs/08-AI服务接入规格.md`。

**超时**：非流式用 `ai.timeout_seconds`（默认 65s，必须大于 AI 服务自身的 55s）；**流式下该配置作为「空闲超时」**——任一段静默超过该时长即中止，但整段回答可以更长（否则长回答会被整体超时掐断）。

**业务上下文注入（两条链路，都是可选、都可降级）**：

| 链路 | 触发条件 | 内容 | 预算 |
| --- | --- | --- | --- |
| **资产资料**（V2，公开数据） | 提问命中角色名（**与登录无关**；2026-09-14 起匿名已不能提问，见 §2） | 查 `asset_character_stat_weights` → 渲染成「【游戏资料】…」文本放入 `context.summary`，含 primary/secondary 分级与推荐主词条 | ≤400 tokens，最多 2 个角色 |
| **玩家档案**（V1，私有数据） | 携带 `Authorization: Bearer <token>` 且该账号已绑定游戏 UID | `context.player.characters`（展柜角色概览 + 点名角色明细） | ≤1500 tokens |

两者都注入时，`summary` 里的资料排在玩家档案之前。命中但库里没有数据的角色会显式写成「本服暂无该角色的资料」，配合 AI 服务人格提示词的「资料外不编造」规则，冷门角色会老实承认不知道而不是编数值。

改资料（`/api/admin/assets/import` 或直写 DB 后 reload、**带 `?purgeSnapshots=true`**）后，回答应随之变化 —— 这是 V2 的验收方式。会话归属记录在 `chat_sessions.user_id`（0 = 匿名）。

### 2.4 会话管理（列表 / 明细 / 重命名 / 删除；**需登录**）

匿名没有「我的会话」这个概念，因此以下四个接口一律挂 `JWTAuth`：
**未带 Token 或 Token 无效/过期 → 401**。消息只从服务端拉，前端不缓存正文。

> 2026-09-14 起 `/api/chat` 也改为强制登录（见 §2），本组接口不再是"唯一的强制登录组"，但口径不变。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/sessions?page=1&pageSize=20` | 本人会话列表（不含消息正文）；活跃时间倒序 `updated_at DESC, id DESC`；`pageSize` 上限 100 |
| GET | `/api/sessions/{sessionId}/messages?beforeId=&limit=` | 会话明细；**向上游标分页**：返回 `id < beforeId` 的**最近** `limit` 条（缺省 100、上限 200），按 `id` 升序；`hasMore=true` 表示还有更早的，用返回首条的 `id` 继续当 `beforeId` |
| PATCH | `/api/sessions/{sessionId}` | 重命名，body `{title}`；去首尾空白，空 → 400，超 50 字 → 400；返回服务端归一化后的标题 |
| DELETE | `/api/sessions/{sessionId}` | 删除会话（**软删除**）：C 端从此不可见，数据保留供后台审计；重复删除 → 404 |

**列表项**：`{sessionId, title, messageCount, createdAt, updatedAt}`，外层 `{items, total, page, pageSize}`。
**明细**：`{sessionId, messages: [{id, role, content, createdAt}], hasMore}` —— 用量 / 降级标记属运维信息，只在 §7 的 `/internal/v1/admin/chat/*` 下发。

**口径（2026-09-12 定）**：

1. **只服务登录用户**：列表只返回 `chat_sessions.user_id = 本人` 的会话；匿名会话（`user_id = 0`）不进任何人的列表；
2. **匿名不持久化**：前端只把登录用户的当前 `sessionId` 存 localStorage 并在进入页面时恢复；匿名刷新即新对话（同一页面内仍可连续对话）；
3. **不认领匿名会话**：先匿名聊、后登录，那条匿名会话不会并到账号下（登录后是新会话）；
4. **删除是软删除**（置 `chat_sessions.deleted_at`，不物理删除）：C 端（列表 / 明细 / 改名 / 续聊）从此不可见，数据保留供后台审计与成本统计；**B 端仍可查**并标注「已删除」（见 §7.1 的 `deletedAt` / `onlyDeleted`），后台不提供删除入口；
5. **写入侧同样校验归属**：`POST /api/chat` 带的 `sessionId` 若非本人所有（或已不存在、已删除），**一律当作新会话**，不会续聊别人的会话，也不会让已删除的会话复活；
6. 非本人、不存在、已删除的会话，读 / 改名 / 删除统一 **404「会话不存在」**（不返回 403，避免被用来探测会话是否存在；重复删除也因这条自然幂等）；
7. 重命名与删除都**不刷新 `updated_at`**（只改 `title` / `deleted_at`），否则列表顺序会因改名或删除而跳动。

### 2.5 预设问答（**无需登录** · 已实现 2026-09-14）

`GET /api/preset-qa`

匿名用户在对话页看到的内容：**不调用模型、不消耗 token、不落库**。口径真源见 `shared-docs/05-AI使用边界设计（匿名·配额·内容治理）.md` §1.3。

**响应 data**：`{ items: [{ id, sceneKey, question, answer, sort }] }`（只返回 `enabled=1`，按 `scene_key, sort` 排序）。

| 项 | 说明 |
| --- | --- |
| 鉴权 | **无**——它是全站仅有的匿名可读业务接口（另一组是只读的 `/api/genshin/*`） |
| 数据来源 | `preset_qa` 表：`scene_key` 分组 + `sort` 组内排序；下架用 `enabled=0`，**不做物理删除** |
| 内容维护 | 本轮不做后台面板，先由 SQL 种子灌入（见 `shared-docs/05` §1.3） |
| 不做 | 不做搜索、不做个性化、不记录点击（要统计再加） |

### 2.6 配额与限流（**登录用户** · 已实现 2026-09-14）

| 限制 | 口径 | 超限 |
| --- | --- | --- |
| **每日 token 配额** | 每用户每自然日（本地时区 UTC+8）`SUM(chat_messages.tokens)` ≤ `quota.daily_tokens_per_user`（默认 **100,000**，`0` = 不限） | **429** |
| **单用户并发** | 同一用户同时进行中的 AI 请求 ≤ 2（流式与非流式都算） | **429** |
| 全局日预算（可选） | 全站当日 token ≤ `quota.daily_tokens_global`（默认关闭） | **429**（全站熔断） |

**429 响应体**（两种限流共用同一结构，靠 `message` 区分）：

```json
{
  "code": 429,
  "message": "今日 AI 额度已用完，明日 0 点重置",
  "data": { "reason": "daily", "used": 100230, "limit": 100000, "resetAt": "2026-09-15T00:00:00+08:00" }
}
```

> `reason` **恒存在**，取值：`daily`（日配额）/ `concurrent`（单用户并发超限）/ `global`（全站日预算熔断）。
```

| 要点 | 说明 |
| --- | --- |
| 检查时点 | **建会话之前**；流式请求在写出任何 SSE 帧之前拒绝（不能先建会话再拒） |
| 上限性质 | **软上限**：不做事前预扣，允许"最后一问"溢出（最坏 = 上限 + 单次最大消耗），并发同理允许少量超支 |
| 重置 | 自然日 0 点，**无定时任务**（读时按 `created_at` 窗口聚合，天然滚动重置） |
| 并发计数 | 请求进入即占位，结束（含客户端断连）释放；被配额拒绝的请求不占位 |
| C 端不下发 | 配额用量**不在响应里逐次下发**（只在下发 429 时给出 `used/limit/resetAt`）；后台观测见 §7.2 |
| 待决策 | 超限后是硬拒还是降级到预设问答：**先硬拒**（`shared-docs/05` §5 D1） |

---

## 3. 鉴权（已实现）

| 方法 | 路径 | 鉴权 | 说明 |
| --- | --- | --- | --- |
| POST | `/api/auth/register` | 无 | `{username, password, displayName?}`；用户名 3~32 字符，密码 ≥6 位。**`auth.allow_register=false` 时一律 403** `本站为不公开邀请制，已关闭注册；请联系管理员开通账号`（项目当前口径，账号由后台代建，见 `shared-docs/04` §4.4） |
| POST | `/api/auth/login` | 无 | 返回 `{token, displayName}`（JWT，有效期 `auth.jwt_ttl_hours`） |
| GET | `/api/auth/me` | Bearer | 当前用户 `{id, username}` |

注册成功后前端自动调用登录完成会话建立。**不公开部署（`auth.allow_register=false`）下，前端登录页不展示注册入口**，只显示邀请制说明（`web/src/pages/LoginPage.tsx`；i18n `login.inviteOnly` / `login.inviteHint`）。

**curl 示例**

```powershell
$body = '{"username":"admin","password":"admin123"}'
$r = Invoke-RestMethod -Method Post http://localhost:8080/api/auth/login -ContentType "application/json" -Body $body
$H = @{ Authorization = "Bearer " + $r.data.token }
```

---

## 4. 玩家信息查询（Enka.Network 数据源）

数据来自 [Enka.Network](https://github.com/EnkaNetwork/API-docs)：免登录、免签名、免风控。
名称等映射数据存 MySQL 映射表（见 §6.2），由管理接口维护，代码零硬编码。设计详见 `docs/07-Enka方案设计.md`。

### 4.1 查询玩家档案

`GET /api/genshin/player?uid=197794747[&refresh=true]`

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| uid | 条件 | 9 位数字；**携带 Bearer Token 时可省略**，自动使用当前用户绑定的 UID（见 4.3） |
| refresh | 否 | `true` 强制绕过本地快照直接查上游并更新快照 |

**响应 data（PlayerProfile）**

| 字段 | 说明 |
| --- | --- |
| uid / nickname / level / signature / worldLevel / achievements / avatarUrl | 玩家基础信息 |
| characters[] | 展柜角色（≤8）：name / element / rarity / level / constellation / fetter / iconUrl |
| characters[].stats[] | 面板属性 `{name, value, tier?}`；tier=`primary`/`secondary`（推荐属性，前端金色），空为未分级（灰色） |
| characters[].statWeights | 推荐强化词条（来源 asset_character_stat_weights，见 6.2） |
| characters[].weapon | `{name, rarity, level, affix}` |
| characters[].relics[] | 圣遗物：name / set / rarity / level / pos（部位枚举）/ slot（部位中文名）/ mainStat / mainStatTier / subStats[]{name,value,count,tier} |
| warnings | 翻译缺漏提示（前端当前不展示，明细仍落 asset_missings 表） |

**错误映射**：404 玩家不存在或未公开；503 游戏维护 / 上游限流；502 其他上游错误。
**缓存**：本地快照优先（`player_profile_snapshots` 表，uid 主键）；负缓存 5min 防扫号穿透。

### 4.2 档案快照

`GET /api/genshin/player-snapshot?uid=xxx` —— 读取最近一次查询落库的快照，不发起上游查询。

### 4.3 账号 ↔ UID 绑定（需 Bearer Token，一对一）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/genshin/binding` | 绑定 `{uid, server?}`（server 默认 `cn_gf01`）；**绑定前实查 Enka 验证 UID 存在且档案公开** |
| GET | `/api/genshin/binding` | 查询 `{bound, uid?, server?}` |
| DELETE | `/api/genshin/binding` | 解绑 |

---

## 5. 图鉴检索（规划中）

`GET /api/wiki?q=钟离`

---

## 6. 资产映射管理（后台管理系统核心）

### 6.1 接口（X-Admin-Key 鉴权）

请求头：`X-Admin-Key: <config.yaml 的 auth.admin_key 值>`（未配置时回落 `auth.jwt_secret`，不推荐）。
外部系统（后台管理系统）若直连数据库写入映射，**必须再调用 reload 通知服务刷新内存**，否则运行中的进程仍用旧映射。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| POST | `/api/admin/assets/import` | 批量 upsert 映射，成功后自动刷新内存（走接口导入无需再调 reload） |
| GET | `/api/admin/assets/missing?limit=100` | 翻译缺漏清单 `{items, total}`（按 hit_count 倒序），补录依据 |
| POST | `/api/admin/assets/reload[?purgeSnapshots=true]` | 刷新内存映射；`purgeSnapshots=true` 时同时清空档案快照（**改了词条名/分级等翻译数据后必须带上**，否则旧翻译快照仍会命中） |
| POST | `/api/admin/assets/purge-snapshots` | 仅清空档案快照（配合外部直写 DB 的场景） |

**外部系统调用示例**

```powershell
$H = @{ "X-Admin-Key" = "<管理密钥>" }
# 直写 DB 改了词条映射后：
Invoke-RestMethod -Method Post "http://<服务地址>:8080/api/admin/assets/reload?purgeSnapshots=true" -Headers $H
```

**安全要求**：

- `auth.admin_key` 独立于 `auth.jwt_secret`（后者是 JWT 签名密钥，泄露即可伪造任意用户身份）；
- 生产环境必须走内网或 HTTPS 调用，禁止把管理密钥下发到浏览器端；
- 密钥通过环境变量 `TEYVAT_AUTH_ADMIN_KEY` 注入，不写入代码仓库。

> CLI 批量导入：`go run ./cmd/assetimport -dir <EnkaGameAssets store/gi 目录>`，或分表导入
> `-textmap-file` / `-affixes-file` / `-fight-props-file` / `-stat-weights-file` / `-import-file`
> （`-import-file` 为通用模式，可导入任意 ImportPayload 子集，如 `cmd/assetimport/relic_slots.json`）。

### 6.2 ImportPayload 与数据表（字段全部可选，按表分组 upsert）

| 载荷字段 | 数据表 | 结构 |
| --- | --- | --- |
| characters[] | characters | `{id(avatarId), name, enName, element, rarity, icon}` |
| weapons[] | weapons | `{id, name, enName, rarity, type, icon}` |
| relicSets[] | relic_sets | `{setId, name, icon}` |
| textMap[] | text_map_entries | `{hash, text}`（TextMapCHS：hash → 中文） |
| propMap[] | prop_maps | `{propId, name, percent}` 词条 ID → 中文名；percent 决定数值格式 |
| fightProps[] | fight_props | `{numId, propId}` Enka fightPropMap 数字枚举 → FIGHT_PROP_XXX |
| relicSlots[] | relic_slots | `{pos, name}` 圣遗物部位枚举 → 中文（生之花 / 时之沙 …） |
| affixes[] | affixes | `{id, propType, propValue}` 圣遗物词缀表（解码强化次数） |
| statWeights[] | character_stat_weights | `{characterId, recommendation}`，JSON payload：`{subStats:[{statKey,weight,tier?}], mainStats:{sand,goblet,circlet}}`；tier=`primary`/`secondary` |

**tier（属性分级）说明**：`primary`/`secondary` 会透传到面板属性（stats[].tier）与圣遗物词条（relics[].mainStatTier / subStats[].tier），前端据此着色；未分级为空。修改 payload 后需 reload 或重启生效，并清空 `player_profile_snapshots`（旧快照不含新翻译）。

**请求示例**

```json
{
  "propMap": [{ "propId": "FIGHT_PROP_HP_PERCENT", "name": "百分比生命值", "percent": true }],
  "fightProps": [{ "numId": "45", "propId": "FIGHT_PROP_WATER_ADD" }],
  "statWeights": [{
    "characterId": 10000089,
    "recommendation": {
      "subStats": [
        { "statKey": "FIGHT_PROP_HP_PERCENT", "weight": 10, "tier": "primary" },
        { "statKey": "FIGHT_PROP_CRITICAL", "weight": 8, "tier": "primary" }
      ],
      "mainStats": { "sand": "元素充能效率", "goblet": "水元素伤害加成", "circlet": "暴击率" }
    }
  }]
}
```

**响应**：`{ "characters": n, "weapons": n, "relicSets": n, "textMap": n, "propMap": n }`

---

## 7. 内网管理接口（X-Internal-Key，供后台运维系统调用）

**路径不带 `/api` 前缀**（契约见 `shared-docs/04-用户体系与鉴权边界设计.md` §4）。请求头：`X-Internal-Key: <auth.internal_key>`；
**未配置 `auth.internal_key` 时该组路由不注册**（安全默认），请求头缺失/错误一律 401。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/internal/v1/admin/users?keyword=&page=1&pageSize=20` | 用户列表；keyword 匹配 用户名 / 昵称 / 游戏 UID；`pageSize` 上限 100 |
| POST | `/internal/v1/admin/users/status` | 封禁 / 解封 `{id, banned}`，幂等 |
| POST | `/internal/v1/admin/users` | **代建 C 端账号**（邀请制下的唯一开户入口）：`{username, password, displayName?}` → `{id, username, displayName, createdAt}`；400 参数不合法 / 409 用户名已存在。契约见 `shared-docs/04` §4.4 |

**列表项字段**：`id / username / displayName / genshinUid(可空) / status(active|banned) / createdAt / lastLoginAt(可空) / totalTokens`
（`totalTokens` = 该用户经 `chat_sessions.user_id` 归属的 `chat_messages.tokens` 聚合）

**封禁语义（联动会话失效）**：

- 鉴权中间件（`JWTAuth` / `JWTAuthOptional`）每次都校验封禁状态 → **封禁后既有 JWT 立即失效**（403 `账号已被封禁，请联系管理员`）；
- 封禁用户无法重新登录（403 `账号已被封禁`）；解封后恢复；
- `POST /internal/v1/admin/users/status` 不存在用户 → 404 `用户不存在`。

**错误码**：401 缺少/错误 X-Internal-Key；404 用户不存在；400 参数错误。

**外部（后台）配置**：后台侧环境变量 `PROJECT_TEYVAT_GUIDE_INTERNAL_KEY` = 本服务的 `auth.internal_key`。
三类密钥必须各自独立：用户 JWT（`jwt_secret`）／资产管理（`admin_key`）／内网管理（`internal_key`）／AI 服务（`X-AI-Key`）。

### 7.1 对话记录查看（只读 · 已实现 2026-09-12）

设计见共享仓 `admin/06-对话记录查看设计.md`；后台页面为「AI 提瓦特向导 → 对话记录」。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/internal/v1/admin/chat/sessions?keyword=&userId=&uid=&onlyDegraded=&onlyDeleted=&onlyOffTopic=&from=&to=&page=1&pageSize=20` | 会话列表（**不含消息正文**）；`keyword` **只匹配提问内容**（既定口径，不搜回答）；排序 `updated_at DESC, id DESC`；`pageSize` 上限 100；**默认不过滤用户已删除的会话**（含已删除，前端标注），`onlyDeleted=true` 只看已删除；**`onlyOffTopic=true` 只看含无关提问的会话**（2026-09-14 新增，**已实现**） |
| GET | `/internal/v1/admin/chat/sessions/{sessionId}/messages?afterId=&limit=` | 会话明细；**游标分页**（取 `afterId` 之后的消息，`hasMore` 提示还有）；`limit` 上限 500、默认 200；会话不存在 → 404 |

**列表项字段**：`sessionId / title / userId(0=匿名) / username / displayName / genshinUid / messageCount / tokens / degradedCount / hasPlayerContext / hasAssetReference / lastQuestion(截断摘要) / createdAt / updatedAt / deletedAt(用户在 C 端删除的时间，null = 未删除) / offTopicCount(会话内无关提问数，判定未开启时为 0，2026-09-14 新增)`，外层 `{items,total,page,pageSize}`。

**消息字段**：`id / role / content / tokens / tokensInput / tokensOutput / tokensCached / model / profile / degraded / elapsedMs / createdAt / offTopic(仅 role=user 有意义；null = 未判定) / offTopicReason(子类，2026-09-14 新增)`，外层 `{sessionId,userId,messages,hasMore}`。

> 用户列表（`/internal/v1/admin/users`）的契约真源在 `shared-docs/04-用户体系与鉴权边界设计.md` §4.1；2026-09-14 为其新增了 `usageDate / minDailyTokens / onlyOffTopic / offTopicMin` 入参与 `todayTokens / todayInput / todayOutput / todayCached / todayRequests / offTopicCount` 字段（当日用量与无关问题筛选，**已实现**；后台界面目前只用 `minDailyTokens` 与 `onlyOffTopic`，`usageDate` 缺省为今天）。

### 7.2 预设问答维护（可运营 · 已实现 2026-09-14）

后台「AI 提瓦特向导 → 预设问答」的数据接口。**C 端免登录可见**（§2.5），这里给运营提供读写。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/internal/v1/admin/preset-qa` | 全部条目（**含已下架**），排序 `scene_key ASC, sort ASC, id ASC` |
| POST | `/internal/v1/admin/preset-qa` | 新建，body `{sceneKey, question, answer, sort, enabled?}` |
| PUT | `/internal/v1/admin/preset-qa/{id}` | 更新（**整体覆盖**这几个字段；`enabled` 省略 = 保持原值） |

**响应 data（单条/列表项）**：`{id, sceneKey, question, answer, sort, enabled, createdAt, updatedAt}`。

| 口径 | 说明 |
| --- | --- |
| **不做物理删除** | 下架只需 `enabled=false`：C 端立刻不再下发，**数据保留**，后台随时可恢复（与"对话记录不删"的理由不同：这里是运营需要随时改、随时撤） |
| 生效方式 | 写库即生效，C 端下次拉取（`GET /api/preset-qa`）立刻看到；**无需发版、无需重启** |
| 字段校验 | 提问/回答去首尾空白后非空；提问 ≤200、回答 ≤4000、分组 ≤32（按**字符**计）；`sort` 限 -9999~9999 |
| 错误码 | 参数不合法 → **400**；`id` 不存在 → **404**；其余 → 500 |
| 与种子的关系 | 表为空时启动会灌 6 条种子（`service/preset.go`）；后台新建/编辑/下架都只是普通数据操作 |

**观测字段说明**：
- `tokensCached`＝命中前缀缓存的 tokens（单价约为未命中的 1/50，**成本统计必须分开算**）；
- `degraded` 由服务端标记，不再靠文案比对判断；
- `hasPlayerContext` / `hasAssetReference`＝该会话**曾经**注入过玩家面板 / 资产资料（V1/V2 的落地效果观测）。

**红线**：只读——**不提供修改 / 删除消息的接口**（对话记录属审计数据，需要清理只能运维直接操作数据库）。
C 端用户发起的「删除会话」是**软删除**（`chat_sessions.deleted_at`）：数据仍在、后台照常可见并标注「已删除」，**后台不提供删除入口**。

---

## 8. 业务数据表总览（teyvat_guide 库）

| 表 | 用途 |
| --- | --- |
| users | 用户（username / password_hash / display_name / genshin_uid / genshin_server / status / last_login_at） |
| chat_sessions / chat_messages | 对话会话（含 user_id，0=匿名）与消息 |
| player_profile_snapshots | 玩家档案快照缓存（uid 主键，JSON，TTL 10 分钟） |
| characters / weapons / relic_sets | 角色 / 武器 / 套装映射 |
| text_map_entries | 文本 hash → 中文 |
| prop_maps / fight_props / relic_slots / affixes | 词条名 / 数字枚举 / 圣遗物部位 / 词缀映射 |
| character_stat_weights | 角色推荐词条（JSON payload，含 tier 分级） |
| missings | 翻译缺漏收集（补录依据） |
