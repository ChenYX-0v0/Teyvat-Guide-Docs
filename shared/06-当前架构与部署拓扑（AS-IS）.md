# 06 · 当前架构与部署拓扑（AS-IS）

> **本文只回答一件事**：**现在跑着什么、跑在哪、谁连谁。**
> **与其他架构文档的区别**：`web/01 §3`（前端+主服务视角）、`ai/02`（AI 服务内部）、`ai/04 §2`（主服务↔AI 服务）、
> `ai/06 §4`（阿里云推荐拓扑）、`admin/01`（后台平台）都是**设计态 / 单仓视角**；本文是**实况**，且横跨三仓，故放 `shared/`。
> **维护约定**：每次**部署形态变化**（换机、加/减服务、改端口或暴露面）都要回来改本文，并同步 `ai/06 §1.1`（部署实况登记）。
> 最近更新：**2026-09-27（ICP 备案通过 → 公网上线：域名 + 外层 Nginx + HTTPS）**

---

## 1. 一张图看懂（AS-IS）

```
                        ┌──────────────────────────────────────────────┐
   浏览器 / C 端用户  ───► │ 公网：https://aiteyvat.com（已备案 + HTTPS）  │
                        └───────────────────────┬──────────────────────┘
                                                │ 80 → 301 → 443（TLS 在宿主机终结）
┌───────────────────────────────────────────────▼───────────────────────────────────┐
│ 阿里云 ECS  8.159.154.246（公网）/ 172.31.251.144（内网）                           │
│ 地域 cn-shanghai-g ｜ 2 核 2G ｜ Alibaba Cloud Linux 3 ｜ Docker 26.1.3 + Compose   │
│ 部署目录 /opt/teyvat-guide ｜ 镜像来自 ACR 个人版（cn-shanghai）                    │
│                                                                                   │
│  ┌── 宿主机 Nginx 1.24（★ 2026-09-27 新增，公网入口）───────────────────┐           │
│  │   · 443 ssl：证书 Let's Encrypt（certbot，systemd timer 自动续期）    │           │
│  │   · /      → 127.0.0.1:8088（web 容器）                             │           │
│  │   · /api/  → 127.0.0.1:8080（主服务；proxy_buffering off 保 SSE）     │           │
│  │   · /api/admin/ 与 /internal/ → 404；80 → 301 https                 │           │
│  └───────────────┬─────────────────────────────────────────────────────┘           │
│                  │ 回环                                                            │
│  ┌───────────────▼── web 容器（Nginx）127.0.0.1:8088→80 ───────────────┐           │
│  │   · 静态资源 = Vite 构建产物（C 端 React SPA）                        │           │
│  │   · /api/ 反向代理 → server:8080（proxy_buffering off，保 SSE 流式）  │           │
│  │   · /api/admin/ 与 /internal/ 直接 404（管理面不过公网前端）           │           │
│  │   · X-Robots-Tag: noindex（刻意不参与搜索收录，见 web/11 §6.1）        │           │
│  └───────────────┬─────────────────────────────────────────────────────┘           │
│                  │ compose 内网（服务名互通，不走宿主）                             │
│  ┌───────────────▼── server 容器（Go + Gin）  127.0.0.1:8080 ──────────┐           │
│  │   · JWT 鉴权 → 用户须知闸门（terms 版本）→ 配额/并发闸门              │           │
│  │   · 内存资产映射（启动时从 RDS 载入）                                 │           │
│  │   · 玩家档案 ← Enka.Network（公网 HTTPS）                            │           │
│  │   · 埋点写入 usage_events（白名单校验）+ 每小时聚合 usage_daily        │           │
│  │   · 提示词服务端：/internal/v1/ai/prompts（X-Internal-Key）           │           │
│  │   · 调 AI：http://ai-service:8090（X-AI-Key）                        │           │
│  └───────────────┬───────────────────────────────┬─────────────────────┘           │
│                  │ 内网 3306                     │ 内网 8090                       │
│  ┌───────────────▼──────────┐   ┌────────────────▼──────────────────────┐          │
│  │ 阿里云 RDS MySQL 8.0.36   │   │ ai-service 容器（Python）:8090         │          │
│  │ rm-uf6o31bzhf9zy5139...   │   │   · 派蒙人格 + 资料拼装 + 无关问题判定   │          │
│  │  ├ teyvat_guide（业务库）  │   │   · 提示词 http 模式拉主服务            │          │
│  │  └ teyvat_admin（管理库）  │   └────────────────┬──────────────────────┘          │
│  └───────────────────────────┘                    │ HTTPS 443                      │
└───────────────────────────────────────────────────┼─────────────────────────────────┘
                                                    ▼
                                          DeepSeek API（api.deepseek.com）

┌─ 本机（开发者机器，运营入口）────────────────────────────────────────────────────┐
│  后台管理 demo-app（Next.js dev）  :3000  ──► 云上 RDS teyvat_admin（经 SSH 隧道 13306）│
│      │ SSH 隧道（scripts\tunnel-remote.ps1）：                                    │
│      │   18080 → 云上 8080（主服务）  18090 → 云上 8090（AI 服务）                  │
│      │   9088  → 云上 8088（C 端）    13306 → RDS 内网 3306（MySQL）               │
│      └──────► 云上主服务 / AI 服务（经 managed_projects.base_url 指向隧道）           │
│  本地容器栈：**已停**（镜像保留，随时可 `docker compose up -d` 起本地联调环境）       │
└──────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 组件现状

| 组件 | 跑在哪 | 产物 / 镜像 | 端口（暴露面） | 数据落在哪 |
| --- | --- | --- | --- | --- |
| **宿主机 Nginx** | 云上 ECS（**宿主**，非容器） | 系统包 nginx 1.24 + certbot（Let's Encrypt） | **80 / 443 对公网** | 证书 `/etc/letsencrypt/live/aiteyvat.com/` |
| **C 端前端** | 云上 ECS，`web` 容器 | `teyvat-guide-web:20260928-0109`（Nginx + Vite 产物） | `127.0.0.1:8088→80`（仅回环） | 无（纯静态） |
| **主服务** | 云上 ECS，`server` 容器 | `teyvat-guide-server:20260928-0031`（Go） | `127.0.0.1:8080`（仅回环） | RDS `teyvat_guide`（**23 张表**，含 `usage_events` / `usage_daily` / `invite_codes` ✓；2026-09-27 删掉孤儿表 `character_relic_weight_mps` ✓、2026-09-28 新增邀请码表 `invite_codes` ✓） |
| **AI 派蒙服务** | 云上 ECS，`ai-service` 容器 | `teyvat-ai:20260927-1610`（Python） | `127.0.0.1:8090`（仅回环，**禁止公网**） | 无状态（提示词存 RDS `ai_prompts`） |
| **数据库** | 阿里云 RDS MySQL **8.0.36** | — | 内网 3306（白名单只放 ECS 内网 IP） | `teyvat_guide` + `teyvat_admin` 两库 |
| **镜像仓库** | 阿里云 ACR 个人版（cn-shanghai） | `crpi-ecqw70nr0f83o93t.cn-shanghai.personal.cr.aliyuncs.com/teyvat/*` | 公网 HTTPS | — |
| **后台管理** | **本机**（`npm run dev`，**未上云**） | `demo-app`（Next.js） | 本机 `:3000` | RDS `teyvat_admin`（经隧道）+ 读业务库 `teyvat_guide` |
| 本地容器栈 | 本机 | 三个镜像（本地 tag） | **已停** | 运行时也连 RDS（经隧道） |

**两个账号边界**（刻意分开，别混）：`teyvat` → 仅 `teyvat_guide.*`；`teyvat_ops` → 仅 `teyvat_admin.*`。口径见 `05-密钥与凭据管理.md`。
> ⚠️ 这条边界也决定了 `admin/08` 里"数据库状态"能做到什么：应用账号看不到 `GLOBAL STATUS` / 慢日志 / 实例磁盘。

**版本怎么发**：`deploy/out/release.ps1 -Service server|web`（构建 → save → scp → load → 改 `.env` → `up -d --no-build` → 自检），
每次自动留 `.env.bak-<tag>` 可一键回滚；生产 tag 台账见主仓 `deploy/README.md §3.9`。

---

## 3. 一次提问的完整路径（带锚点，便于排查）

| # | 环节 | 细节 | 排查看哪 |
| --- | --- | --- | --- |
| 1 | 浏览器 → 入口 | `http://aiteyvat.com` → 301 → `https://aiteyvat.com`（宿主机 Nginx 终结 TLS） | `tail /var/log/nginx/access.log` |
| 2 | 宿主机 Nginx | `/` → `127.0.0.1:8088`；`/api/` → `127.0.0.1:8080`（**`proxy_buffering off`**）；`/api/admin/`、`/internal/` 404 | 同上 |
| 3 | Nginx（`web` 容器） | 再反代一次 `server:8080`（同样关缓冲）；顺手带 `X-Robots-Tag: noindex` | `docker compose logs web` |
| 4 | 主服务鉴权与闸门 | JWT → **用户须知版本闸门** → 每用户日配额 / 并发闸门（`05-AI使用边界设计`） | `logs server`：`access` 行 |
| 5 | 资产映射（内存） | 启动时从 RDS 载入：角色 **124** / 武器 **255** / 套装 **65** / 套装效果 **128** / 文案 **498** / 词条名 **24** / 战斗词条 **15** / 词缀 **350** / 推荐词条 **124**（**2026-09-27 实测值** ✓；词条名原为 32，因同名两套 key 去重 ⇒ 24 ✓） | `logs server`：`asset maps loaded` |
| 6 | 玩家上下文 | 有 UID 时调 Enka.Network 取展柜 → 组进上下文 | `logs server`：`ai context attached` |
| 7 | 资料注入 | 按问题关键词匹配资产并拼进提示词 | `logs server`：`ai asset reference attached` |
| 8 | 提示词 | AI 服务 `PROMPT_STORE_MODE=http` → 主服务 `/internal/v1/ai/prompts`（`X-Internal-Key`） | `logs ai-service`：`prompt_store.backend` |
| 9 | 调 AI 服务 | 主服务 → `http://ai-service:8090/v1/complete`（`X-AI-Key`） | `logs server`：失败打 `ai complete failed` |
| 10 | 调模型 | AI 服务 → `api.deepseek.com`（命中前缀缓存 → `tokens_cached`） | `logs ai-service`：`llm.completed` |
| 11 | 回写与落库 | SSE 逐字回写前端；`chat_messages` / 用量落 RDS；回答末尾带「内容由 AI 生成」（前端标识） | 前端气泡 + `logs server` |
| 12 | 埋点（旁路） | 前端 `track()` → `POST /api/events`（匿名可上报、白名单过滤）→ `usage_events`；**每小时**重建「今天 + 昨天」的 `usage_daily`（幂等，当天数据最多滞后 1 小时 ⇒ 不必等次日 03:30 ✓；`usage_stats.go` 的 `aggLoop`） | `logs server`：`usage ingest` |

> **用户看到兜底话术**（"派蒙现在有点晕乎乎的…"）= 第 9/10 步失败：先看 `logs server` 的 `ai complete failed` 的 `err`，再看 `logs ai-service`。
> **登录后被弹窗拦住** = 用户须知版本不一致（正常行为）：`users.terms_version` ≠ 服务端 `CurrentTermsVersion`，见 `../web/15`。

---

## 4. 后台管理的接入路径（+ 规划）

**现状**：后台跑在本机 3000，**业务项目地址不在环境变量里**，而在管理库 `teyvat_admin.managed_projects.base_url`
（现指向 SSH 隧道 `http://127.0.0.1:18080` / `:18090`）；鉴权密钥走环境变量 `PROJECT_<CODE>_ADMIN_KEY`。
改法、回退与注意点见主仓 `deploy/README.md §3.7`；隧道一条命令起停：`scripts\tunnel-remote.ps1`（含 RDS 13306）。

**规划（未实施）**：后台**自身也上云**（Next.js standalone 镜像 → 只绑回环 → 外层 Nginx 子域 → **管理面必须配访问控制**），
届时 `base_url` 改为容器间地址、**隧道退休**。要点见 `../ai/06-阿里云部署方案.md §1.2`，排期见 `../ai/05-开发路线图.md §8 O5`。
**另见**：`../admin/08-后台运维观测与AI助手设计.md`（服务器/数据库状态观测 + 后台 AI 助手，2026-09-27 立设计）。

---

## 5. 端口与暴露面矩阵

| 位置 | 端口 | 服务 | 是否公网可达 |
| --- | --- | --- | --- |
| 云上 ECS | **80 / 443** | 宿主机 Nginx（HTTP 跳转 / HTTPS 入口） | ✅ **已开放**（2026-09-27 起） |
| 云上 ECS | 22 | sshd | ✅ 公网开放，**安全组限定本机当前 IP** ⚠️（家宽动态 IP 变化即会断开，需改规则或改用控制台 Workbench） |
| 云上 ECS | 8088 / 8080 / 8090 | web / 主服务 / AI 服务 | ❌ 仅 `127.0.0.1`（`docker-proxy`） |
| 云上 RDS | 3306 | MySQL | ❌ 仅内网 + 白名单（放 ECS 内网 IP） |
| 本机 | 3000 | 后台管理（dev） | ❌ 仅本机 |
| 本机 | 18080 / 18090 / 9088 / 13306 | SSH 隧道（主服务 / AI / C 端 / RDS） | ❌ 仅本机 |

> 验收口径：`curl -m 5 http://<ECS公网IP>:8090/health` **必须失败**；`:8080`、`:8088`、`:3306` 同理。

---

## 6. 外部依赖

| 依赖 | 用途 | 出网要求 |
| --- | --- | --- |
| `api.deepseek.com` | 对话模型（付费，**成本大头**） | HTTPS 443 |
| `enka.network` | 玩家展柜数据（有 UID 时） | HTTPS 443 |
| 百炼（`*.maas.aliyuncs.com`） | Embedding（**P2 才用，尚未启用**） | HTTPS 443 |
| Let's Encrypt（`acme-v02.api.letsencrypt.org`） | 证书签发与续期（certbot） | HTTPS 443（续期走 80 的 webroot 挑战） |
| 阿里云 OpenAPI（规划中） | RDS 实例指标（`admin/08` M2.5，只读 AK） | HTTPS 443 |

---

## 7. 与设计态文档的关系 + 变更时间线

| 文档 | 视角 | 本文与它的关系 |
| --- | --- | --- |
| `../web/01-项目总览与架构.md §3` | 前端 + 主服务 | 那里的图是**该仓视角**；完整拓扑以本文为准 |
| `../ai/02-AI派蒙架构设计-DeepSeek方案.md` | AI 服务内部 | 设计态，未变 |
| `../ai/04-部署运维接入说明.md §2` | 主服务 ↔ AI 服务 | 局部图；端口语义已更新（3306 = RDS 内网） |
| `../ai/06-阿里云部署方案.md §1.1 / §4` | 云上 | §1.1 = 部署实况登记（运维细节）；§4 = 推荐拓扑 |
| `../web/11-上线准备（域名·备案·HTTPS）.md` | 对外入口与合规 | 域名/DNS/证书/公安备案/生成式 AI 合规的实操清单 |
| `../admin/01-多项目管理平台总体设计.md` | 后台平台 | 设计态 |
| `../admin/08-后台运维观测与AI助手设计.md` | 运维观测 | 本文的"看什么、怎么看"在那边细化 |

**变更时间线（关键节点）**

| 日期 | 变更 |
| --- | --- |
| 2026-09-18 | 补齐三服务 Dockerfile + 根 compose（只绑回环），本地构建通过 |
| 2026-09-19 | **切 RDS**（业务库 `teyvat_guide` + 后台库改名 `teyvat_admin`，双库双账号）；本机容器化联调通过 |
| 2026-09-20 | 密钥轮换（4 把 + 五处同步）；镜像推 ACR 个人版；**ECS 首次部署上线**（上海）；后台管理接云上（隧道 + 项目注册表） |
| 2026-09-27 | **ICP 备案通过**（`辽ICP备2026022414号-1`）→ **公网上线**：云解析 `aiteyvat.com` → ECS，安全组开 80/443，**新增宿主机 Nginx + Let's Encrypt 证书**（自动续期），web/server 发版 `20260927-0224`；同时上线**用户须知强制确认**（`users.terms_version`）、**AI 生成内容标识**、备案号页脚、**不参与搜索收录**（robots + noindex + `X-Robots-Tag`） |

---

## 8. 怎么验证（两条命令）

```bash
# ① 云上全量自检：容器 / 健康检查 / 登录+提问 / 关键日志 / 资源 / 暴露面
ssh -i <私钥> root@<ECS公网IP> 'bash /opt/teyvat-guide/deploy/smoke-ecs.sh'
#    ⚠️ 该脚本的登录口令优先取 SMOKE_PASS；线上口令改过时用 SMOKE_PASS=<当前密码> 重跑

# ② 公网入口验收（从外网，与用户同路径）
curl -sI https://aiteyvat.com/ | head -3                  # 200 + X-Robots-Tag: noindex...
curl -s  https://aiteyvat.com/api/health                  # {"code":0,...,"status":"up"}
curl -s  https://aiteyvat.com/terms | head -c 200         # 免登录可读的用户须知
curl -sI http://aiteyvat.com/ | head -3                   # 301 → https
curl -m 5 http://<ECS公网IP>:8090/health                  # 必须失败（AI 服务不出公网）
```

脚本见主仓 `deploy/smoke-ecs.sh`（说明在 `deploy/README.md §3.8`）。**2026-09-20 首跑 6/6 通过**；2026-09-27 公网验收全部通过。

---

## 9. 已知缺口 / 风险（别当已完成）

| # | 事项 | 状态 |
| --- | --- | --- |
| 1 | **公安联网备案** | ⏳ 待提交（ICP 通过后 30 日内；口径见 `../web/11` §6） |
| 2 | **生成式 AI 应用侧登记** | ⏳ 未启动（属地网信办；问那四句见 `../web/11` §8.5） |
| 3 | RDS **备份恢复演练** | ⏳ 未做（`deploy/README.md §3.4`） |
| 4 | 容器日志上限 / Nginx 日志轮转 | ⏳ 未核对（可能无限增长） |
| 5 | SSH 22 与**动态 IP** | ⚠️ 家宽 IP 变动即断开，需改安全组或改用控制台 Workbench |
| 6 | 带宽 | 实测下载 ≈10 Mbps（够用）；有 CDN 需求时再上 |
| 7 | 运维观测（服务器/DB 状态） | ⏳ 仅设计（`../admin/08`） |
