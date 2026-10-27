# 原神玩家查询 —— Web 服务端开发指南

> 基于《MIGRATION_NOTES.md》的调研结论，面向 Web 服务器开发的完整方案文档。
> 两种数据源：**Enka.Network**（免登录、免风控）与**米游社接口**（数据全、需维护 Cookie/签名）。

---

## 1. 总体架构

```
                ┌─────────────────────────────────────────────┐
  客户端 ──────▶ │              你的 Web 服务器                 │
 (Web/小程序/App) │                                             │
                │  API 层 (鉴权/参数校验/限流)                   │
                │      │                                      │
                │  服务层 (查询编排 + 数据聚合)                   │
                │      │             │                        │
                │  Enka 客户端   米游社客户端(可选)                │
                │      │             │                        │
                │  缓存层 (Redis / 内存, 按 UID + TTL)           │
                └──────┼─────────────┼────────────────────────┘
                       ▼             ▼
                enka.network    api-takumi-record.mihoyo.com
```

**推荐策略**：Enka 为主（基础信息 + 展柜角色详情），深渊数据为刚需时再实现米游社客户端。

---

## 2. 数据源 A：Enka.Network（首选，零维护成本）

### 2.1 接口

```
GET https://enka.network/api/uid/{uid}/
```

无需任何认证和签名。

### 2.2 响应关键字段

```json
{
  "playerInfo": {
    "nickname": "昵称",
    "level": 60,
    "signature": "签名",
    "worldLevel": 8,
    "nameCardId": 210001,
    "finishAchievementNum": 800,
    "profilePicture": { "avatarId": 10000007 },
    "showAvatarInfoList": [ { "avatarId": 10000002, "level": 90 } ]
  },
  "avatarInfoList": [
    {
      "avatarId": 10000002,
      "propMap": { "4001": { "val": "15184" } },   // 生命/攻击等基础属性
      "talentIdList": [20311, 20312],               // 命座 (长度=已解锁命座数)
      "equipList": [
        { "flat": { "itemType": "ITEM_WEAPON", "nameTextMapHash": ... },
          "weapon": { "level": 90, "promoteLevel": 6, "affixMap": { ... } } },
        { "flat": { "itemType": "ITEM_RELIQUARY", "reliquaryMainstat": ... },
          "reliquary": { "level": 20, "appendPropIdList": [...] } }
      ],
      "fetterInfo": { "expLevel": 10 }
    }
  ],
  "ttl": 60,
  "uid": "100000001",
  "region": "CN"
}
```

**响应头**：注意 `Cache-Control`，与 `ttl` 字段配合做本地缓存。

### 2.3 注意事项

1. **展柜限制**：`avatarInfoList` 只包含对方游戏内"角色展柜"摆出的角色（最多 8 个）；未开展柜时为空
2. **ID 解码**：官方数据全是 ID，需要静态映射文件翻译：
   - 角色名/技能/命座/武器名：Enka 的映射仓库 `Escartem/EnkaGameAssets` 或 `Dimbreath/AnimeGameData`（Excel 配置表）
   - 圣遗物词条（`appendPropIdList`）→ 属性名+数值换算
   - 角色头像/立绘图片：`https://enka.network/ui/UI_AvatarIcon_{icon}.png`
   - 名片：`https://enka.network/ui/UI_NameCardPic_{p}.png`
3. **缓存**：响应带 `ttl`（60 秒内同 UID 返回缓存数据），你的服务器应对该 UID 做本地缓存，避免重复请求
4. **限流**：无官方配额，建议自己做速率限制（如每 IP 每分钟 10 次）

### 2.4 参考实现（Python / FastAPI）

```python
import time
from fastapi import FastAPI, HTTPException
import httpx

app = FastAPI()
_cache: dict[str, tuple[float, dict]] = {}
TTL = 60

@app.get("/api/genshin/{uid}")
async def query_player(uid: str):
    if not uid.isdigit() or len(uid) != 9:
        raise HTTPException(400, "UID 必须是 9 位数字")

    hit = _cache.get(uid)
    if hit and time.time() - hit[0] < TTL:
        return {"cached": True, "data": hit[1]}

    async with httpx.AsyncClient(timeout=10) as client:
        r = await client.get(f"https://enka.network/api/uid/{uid}/")
    if r.status_code == 400:
        raise HTTPException(404, "玩家不存在或数据未公开")
    if r.status_code == 424:
        raise HTTPException(503, "游戏维护中，请稍后再试")
    if r.status_code == 429:
        raise HTTPException(503, "上游限流，请稍后再试")
    r.raise_for_status()

    _cache[uid] = (time.time(), r.json())
    return {"cached": False, "data": r.json()}
```

生产环境把内存缓存换成 Redis：`SET enka:{uid} <json> EX 60`。

---

## 3. 数据源 B：米游社接口（可选，数据全）

> 仅当需要**深渊战绩 / 完整角色列表 / 探索度**时才实现。风险点：DS 签名需跟进、Cookie 会过期、风控 1034。

### 3.1 服务端架构

```
米游社客户端模块
├── 签名器: DS = f"{time},{random},MD5(salt=...&t=...&r=...&b={body}&q={query})"
│           (salt 需跟进社区最新版, 参考 Snap.Hutao / hoyo.py 源码)
├── 请求头: x-rpc-client_type: 5, x-rpc-app_version: 最新米游社版本,
│           x-rpc-device_id: 固定随机UUID(绑定Cookie), Referer: https://webstatic.mihoyo.com/
├── Cookie 池: 多账号轮换 + 过期检测(定时调 api/index 验活) + 失效告警
├── 风控处理: retcode=1034 → 换 Cookie 重试 → 仍失败则返回特定错误码由前端引导
└── 限流队列: 全局 QPS 限制(如 1 QPS/Cookie), 指数退避
```

### 3.2 接口清单（同原项目）

| 功能 | 端点 |
|---|---|
| 基础信息 | `GET https://api-takumi-record.mihoyo.com/game_record/app/genshin/api/index?role_id={uid}&server={server}` |
| 深渊 | `GET .../genshin/api/spiralAbyss?schedule_type={1|2}&server={server}&role_id={uid}` |
| 角色详情 | `POST .../genshin/api/character` body: `{"character_ids":[...],"role_id":"...","server":"..."}` |

`server`：`cn_gf01`(天空岛) / `cn_qd01`(世界树)。UID 9 开头 → 天空岛，5 开头 → 世界树，可自动推断。

### 3.3 Cookie 获取方式（服务端场景）

不再适合内嵌 WebView，改用以下方式之一：
1. **用户粘贴 Cookie**：让用户从浏览器 F12 复制米游社 Cookie（`ltoken` + `ltuid`，或 `account_id` + `cookie_token`），存入你的用户体系
2. **扫码登录**：实现 `https://passport-api.mihoyo.com/account/ma-cn-session/app/getQRLogin` 扫码流程（复杂度高，需跟进 App 签名）

### 3.4 参考实现（Python / httpx）

```python
import time, uuid, hashlib, random, string, httpx

SALT = "xV8v4Qu54lUKrEYFZkJhB8cuOh9Asafs"   # 会被米哈游更换, 需跟进社区
APP_VERSION = "2.55.0"                       # 同上

def ds(url: str, body: str = "") -> str:
    query = ""
    if "?" in url:
        query = "&".join(sorted(url.split("?", 1)[1].split("&")))
    t = int(time.time())
    r = "".join(random.choices(string.ascii_letters + string.digits, k=6))
    check = hashlib.md5(f"salt={SALT}&t={t}&r={r}&b={body}&q={query}".encode()).hexdigest()
    return f"{t},{r},{check}"

async def call_api(url: str, cookie: str, body: str = ""):
    headers = {
        "x-rpc-client_type": "5",
        "x-rpc-app_version": APP_VERSION,
        "x-rpc-device_id": str(uuid.uuid4()).upper(),
        "DS": ds(url, body),
        "Cookie": cookie,
        "Referer": "https://webstatic.mihoyo.com/",
        "Content-Type": "application/json",
    }
    async with httpx.AsyncClient(timeout=10) as client:
        if body:
            r = await client.post(url, headers=headers, content=body)
        else:
            r = await client.get(url, headers=headers)
    data = r.json()
    if data["retcode"] == 1034:
        raise RiskControlError()      # 上层: 换Cookie重试 / 告警
    if data["retcode"] == -100:
        raise CookieExpiredError()    # 上层: 从池中摘除该Cookie
    if data["retcode"] != 0:
        raise ApiError(data["retcode"], data.get("message", ""))
    return data["data"]
```

---

## 4. 你的对外 API 设计建议

```
GET /api/genshin/{uid}?server=auto
    → 200 { "basic": {...}, "characters": [...] }
    → 404 玩家不存在 / 503 上游限流 / 502 上游错误

GET /api/genshin/{uid}/abyss?schedule=current     # 需米游社数据源
GET /api/genshin/{uid}/characters                  # 完整角色列表, 需米游社数据源
```

要点：
- **server 参数**：`auto`（UID 首位推断，9→gf01，5→qd01）、`gf`、`qd`
- **错误码透传**：把上游 retcode 映射成干净的 HTTP 状态码 + 业务码，前端好处理
- **缓存穿透**：对不存在的 UID 也缓存（短 TTL，如 5 分钟），防止恶意扫号打穿上游
- **鉴权与配额**：按 API Key 限流；米游社数据源消耗 Cookie 额度，收费/配额策略先行

---

## 5. 开发里程碑

1. **M1 - Enka 基础查询**：封装 Enka 客户端 + 缓存 + 错误映射，先跑通基础信息和展柜角色
2. **M2 - 数据解码**：接入静态资源映射（角色/武器/圣遗物名称与图片），输出人类可读的结构化 JSON
3. **M3 - 米游社客户端**（可选）：签名器 + Cookie 池 + 风控处理，补齐深渊和完整角色列表
4. **M4 - 运维**：Redis 缓存、Prometheus 指标（上游成功率/缓存命中率/Cookie 存活数）、日志告警

---

## 6. 相关资源

| 资源 | 地址 |
|---|---|
| Enka API 文档(中文) | https://github.com/EnkaNetwork/API-docs/blob/master/api_chs.md |
| Enka 静态资源映射 | https://github.com/Escartem/EnkaGameAssets |
| 游戏解包数据(Excel表) | https://github.com/Dimbreath/AnimeGameData |
| 米游社签名参考(Python, 维护中) | https://github.com/seriaati/hoyo.py |
| 米游社签名参考(C#, 功能全) | https://github.com/DGP-Studio/Snap.Hutao |
| 原项目逆向记录 | 见同目录《MIGRATION_NOTES.md》 |
