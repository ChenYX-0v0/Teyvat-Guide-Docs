# 项目待办（Backlog）

> 维护规则：完成即勾选并注明提交；每项归属应明确"后台侧 / web 侧 / AI 侧 / 网关"。
> 关联文档：`01`~`05`。

---

## A. 中转网关项目（`docs/05-中转网关项目设计.md`）

### G0 · 抽公共层
- [ ] 把 `src/lib/projects.ts`、网关转发逻辑、`src/lib/notifications.ts` 抽为共享包 `packages/relay-core`
- [ ] 冻结共享包的对外接口（路由/鉴权注入/归一化/通知的签名）
- [ ] 现有后台改为依赖共享包，行为不变（重构不引入功能变化）

### G1 · 网关 MVP
- [ ] 建独立服务骨架（语言待定 D1，建议 Node/TS），内网监听 `:8091`
- [ ] 只读 `managed_projects` 作为项目注册表（D3）
- [ ] 路由 `/{project}/**` + 鉴权注入（`auth_type`/`auth_header`）
- [ ] 响应归一化（`{code,message,data}` → `{success,message,data}`）
- [ ] 审计日志落库 + 结构化日志（D5）
- [ ] 消费者鉴权（`GW_TOKEN` 起步，D4）
- [ ] 单测：转发/鉴权/归一化/超时

### G2 · 通知队列与重试迁移
- [ ] 通知表与重试逻辑迁入网关；后台改为只读展示
- [ ] 定时重试（cron），失败退避
- [ ] 迁移期双写兼容，再灰度切读

### G3 · 健康聚合 + 后台改造
- [ ] 网关 `GET /gw/health` 并发探测各项目并聚合
- [ ] 后台「服务状态」页改为读聚合结果（避免逐项目 fetch）
- [ ] 后台 `/api/gateway` 改为经网关（或浏览器直连网关）

### G4 · 进阶
- [ ] 按 caller/project 限流
- [ ] 上游故障熔断 + 降级
- [ ] 多消费者接入：CLI、定时任务、告警系统
- [ ] 决策 D2：资产映射 CRUD 是否收进网关（收进则后台不再直连 `teyvat_guide` 库）

### 待决策（见 `05` §8）
- [ ] D1 网关语言
- [ ] D2 资产映射是否入网关
- [ ] D3 注册表来源
- [ ] D4 消费者鉴权方式
- [ ] D5 审计落地方式
- [ ] D6 是否前置反向代理

---

## B. 提瓦特向导后台（`docs/02`）

### 已完成
- [x] M1 `managed_projects` + 网关代理 + 服务状态页
- [x] M2-1 直连 `teyvat_guide` 库（影子实体 + assets 服务）
- [x] M2-2 资产映射管理（角色/武器/圣遗物 + 推荐属性）
- [x] 通知落库与重试（`project_notifications` + 服务状态页）

### 待办
- [ ] M2-3 翻译缺漏清单页（直连 `missings`）+ 一键补录
- [ ] reload 参数与 web 侧约定固化（`?purgeSnapshots=true`）——已用，补 web 侧文档登记
- [ ] 资产映射批量导入（若要替代 CLI 首次铺数据）
- [ ] **V2.2 数据支撑（已立项 2026-09-12）**：`asset_weapon_recommendations`（武器 → 推荐角色）与 `asset_relic_set_effects`（套装 2/4 件效果）的导入载荷 + 维护面板；先做套装效果（数据不依赖外部渠道），武器推荐角色等数据来源定了再补录。规划见 `../ai/05-开发路线图.md` §3「V2.2 已立项」，导入载荷届时登记到 `../web/04-API接口文档.md` §6.2

---

## C. 用户体系（契约真源在 `../shared/04-用户体系与鉴权边界设计.md`，后台项目内为 `shared-docs/04-用户体系与鉴权边界设计.md`）

### 后台侧（已完成）
- [x] 内网客户端 `teyvat-users.ts` + 用户管理页 + Actions
- [x] `PROJECT_TEYVAT_GUIDE_INTERNAL_KEY` 配置项

### web 侧（已完成 · 2026-09-12 核实）
- [x] `GET /internal/v1/admin/users`（`router.go` 注册 + `handler/internal_user.go` + `service/admin_users.go`）
- [x] `POST /internal/v1/admin/users/status`（封禁/解封，幂等）
- [x] `middleware.InternalKeyAuth` + 仅内网可达（`auth.internal_key` 未配置时整组不注册）
- [x] 封禁联动：`middleware.UserStatusChecker` 每次请求校验封禁态 → 既有 JWT 立即失效、无法重新登录
- [ ] **唯一剩余动作**：双方在同一环境填同名密钥，联调一次「用户管理」页（封禁后旧 Token 应立即失效）

---

## D. AI 派蒙服务（`docs/03`）

### 已完成
- [x] 注册为接入项目 + 服务状态页（`/health`）

### 待办
- [ ] 运维增强：不可达告警（复用通知机制）
- [ ] 试跑补全（`/v1/complete`，消耗额度，按需）
- [ ] 用量观测（规格 P4，需 AI 侧提供查询接口）

---

## E. 平台与工程化

- [ ] `docs/` 归档：`aidoc/doc/*` 是否并入 `docs/ai-paimon/`
- [ ] `managed_projects` 管理界面（在后台增删项目，而非只靠迁移）
- [ ] 新项目接入规范沉淀（注册表配置 + 页面模板 + 共享包）
- [ ] `.env.example` 与文档保持同步的检查项

---

## 待用户确认的事项

- [ ] 中转网关语言与落地时机（D1 + 是否现在启动 G0）
- [ ] 是否把资产映射 CRUD 收进网关（D2，影响是否长期直连 `teyvat_guide`）
- [x] ~~web 侧内网接口的排期~~ → **已实现**（见 C 段；用户管理页不再是"接口未就绪"占位），改为待定：何时做一次双密钥联调
