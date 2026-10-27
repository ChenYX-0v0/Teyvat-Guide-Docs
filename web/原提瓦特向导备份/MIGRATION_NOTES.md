# 原神玩家信息查询 —— 数据获取原理与迁移文档

> 源自 Azure99/GenshinPlayerQuery 逆向分析，用于将查询功能迁移到其他项目。

## 1. 整体原理

本项目本质是一个**米游社 API 的第三方客户端**：伪装成米游社 App，携带用户的米游社登录 Cookie 和逆向得到的 DS 签名，调用米哈游官方接口 `api-takumi-record.mihoyo.com`，查询**任意 UID**（自己或他人）的玩家数据。

```
用户输入 UID → 构造请求（DS 签名 + Cookie + 伪装头）
→ api-takumi-record.mihoyo.com 返回 JSON
→ 反序列化为 Model → 渲染展示
```

## 2. API 端点（`src/Core/GenshinAPI.cs`）

| 功能 | 方法 | 端点 | 备注 |
|---|---|---|---|
| 基础信息 / 角色列表 | GET | `https://api-takumi-record.mihoyo.com/game_record/app/genshin/api/index?role_id={uid}&server={server}` | 需 Cookie |
| 深渊数据 | GET | `https://api-takumi-record.mihoyo.com/game_record/app/genshin/api/spiralAbyss?schedule_type={1|2}&server={server}&role_id={uid}` | `1`=本期，`2`=往期 |
| 角色详情（武器/圣遗物/命座） | POST | `https://api-takumi-record.mihoyo.com/game_record/app/genshin/api/character` | Body: `{"character_ids":[...],"role_id":"{uid}","server":"{server}"}` |
| 发起极验验证 | GET | `https://api-takumi-record.mihoyo.com/game_record/app/card/wapi/createVerification?is_high=true` | 风控触发时（返回码 1034） |
| 提交极验结果 | POST | `https://api-takumi-record.mihoyo.com/game_record/app/card/wapi/verifyVerification` | Body: `{challenge, validate, sec_code}` |

**查询流程**（`GetPlayerData`）：
1. `api/index` 获取基础信息 + 角色 ID 列表
2. `spiralAbyss` 获取本期与往期深渊
3. 用第 1 步拿到的角色 ID 列表 POST `api/character` 获取角色详情

**server 取值**：`cn_gf01`（天空岛）、`cn_qd01`（世界树）。

## 3. 请求鉴权

### 3.1 必需请求头

```
x-rpc-client_type: 5          # 伪装移动端客户端
x-rpc-app_version: 2.11.1     # 伪装米游社 App 版本
DS: {time},{random},{check}   # 动态签名，见下
Cookie: {米游社登录 Cookie}
Content-Type: application/json  (POST 请求)
```

### 3.2 DS 签名算法（`CreateDynamicSecret`）

逆向自米游社 App 的签名算法：

```
salt   = "xV8v4Qu54lUKrEYFZkJhB8cuOh9Asafs"   # 硬编码的 v2 salt
time   = 当前 Unix 时间戳（秒，UTC）
random = 6 位随机字符串 [0-9a-zA-Z]
query  = URL 问号后的参数，按字母序排序后用 & 拼接（GET 用）
body   = 请求体原文（POST 用，无则为空串）

check  = MD5( "salt={salt}&t={time}&r={random}&b={body}&q={query}" ).hexdigest()

DS = "{time},{random},{check}"
```

参考实现（C#）：

```csharp
static string CreateDynamicSecret(string url, string body)
{
    string query = "";
    string[] urlPart = url.Split('?');
    if (urlPart.Length == 2)
    {
        string[] parameters = urlPart[1].Split('&').OrderBy(x => x).ToArray();
        query = string.Join("&", parameters);
    }

    long time = (long)DateTime.UtcNow.Subtract(new DateTime(1970, 1, 1)).TotalSeconds;
    string random = CreateRandomString(6);
    string check = ComputeMd5($"salt={API_SALT}&t={time}&r={random}&b={body}&q={query}");
    return $"{time},{random},{check}";
}
```

## 4. 登录凭据（Cookie）获取

只有**基础信息接口**理论上可不带 Cookie 查询；**深渊战绩、角色详情必须携带登录 Cookie**（任何已登录米游社的账号的 Cookie 均可，不要求是被查询的账号）。

原项目的做法（`LoginWindow` + `MessageBus`）：
1. 用 WebView2 内嵌浏览器打开米哈游账号页，让用户手动登录
2. 监测到跳转至 `https://user.mihoyo.com/#/account/home` 即认为登录成功
3. 提取浏览器 Cookie：
   ```csharp
   List<CoreWebView2Cookie> cookies =
       await WebView.CoreWebView2.CookieManager.GetCookiesAsync("https://user.mihoyo.com/");
   string ticket = string.Join("; ", cookies.Select(c => $"{c.Name}={c.Value}"));
   ```
4. Cookie 明文保存到本地 `ticket.txt`，之后每次请求放入 `Cookie` 头

> 迁移提示：关键 Cookie 字段通常是 `account_id` 和 `cookie_token`（可能还需 `ltoken`/`ltuid`）。也可让用户手动粘贴 Cookie 字符串，避免内嵌浏览器方案。

## 5. 风控与验证码（返回码 1034）

米哈游会对高频/异常请求触发风控。判定方式：查询 `api/index` 返回码为 `1034`。

处理流程：
1. GET `createVerification?is_high=true` → 返回 `{challenge, gt}`（极验 GeeTest 参数）
2. 前端加载极验滑块组件，用户完成验证，得到 `challenge / validate / seccode`
3. POST `verifyVerification`，Body：
   ```json
   {"challenge": "...", "validate": "...", "sec_code": "..."}
   ```
4. 验证通过后即可正常发起查询

## 6. 响应格式

所有接口返回统一包装：

```json
{
  "retcode": 0,          // 0=成功；1034=风控需验证码；其他=错误
  "message": "OK",
  "data": { ... }
}
```

主要数据结构（`src/Model/` 下有完整模型）：
- `PlayerInfo`：活跃天数、成就数、深境螺旋层数、世界探索度、头像列表（含角色 ID 与命座数）等
- `spiralAbyss`：各层阵容、星数、战斗/胜利次数、角色出场统计等
- `api/character`：角色等级、命座、武器（含精炼）、圣遗物（含等级）等

## 7. 迁移要点清单

- [ ] 实现 DS 签名（算法见 §3.2，salt 可能随米游社版本更新而变化）
- [ ] 请求头伪装（`x-rpc-client_type`、`x-rpc-app_version`）
- [ ] 获取并维护用户 Cookie（内嵌 WebView 或用户手动粘贴），持久化存储
- [ ] 查询流程编排：index → spiralAbyss(1,2) → character
- [ ] 处理 `retcode`：1034 时走极验流程，其他错误码提示用户
- [ ] 注意请求频率，避免触发风控导致 Cookie 被封
- [ ] Salt / App 版本失效时的更新机制（关注社区如 genshin.dev、其他开源实现获取新 salt）
