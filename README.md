# teyvat-docs · 三项目共享文档仓

本仓是三个项目的**文档唯一真源**，通过目录 Junction 挂载到各项目内，改一处三处生效。

| 目录 | 归属项目 | 内容 |
| --- | --- | --- |
| `web/` | 主服务（teyvat-guide，Go + React） | 架构 / 前后端规范 / API 文档 / Enka 方案 / AI 规格 / 待办 / 上线准备（域名·备案·HTTPS）/ 历史调研 |
| `admin/` | 后台运维系统（demo-app，Next.js） | 平台总体设计 / 后台接入设计 / 运维接入 / 网关设计 / TODO |
| `ai/` | AI 派蒙服务（Python） | 架构设计 / 部署运维 / 路线图 / 阿里云方案 |
| `shared/` | **跨项目契约**（多方共同遵循） | 接口契约 / 主服务对接说明 / 用户体系与鉴权边界设计 / AI 使用边界设计（匿名·配额·内容治理） |

## 挂载关系（Junction）

| 项目 | 项目内路径 | 指向 |
| --- | --- | --- |
| web | `docs/` | `web/` |
| web | `shared-docs/` | `shared/` |
| admin | `docs/` | `admin/` |
| admin | `aidoc/` | `ai/` |
| admin | `shared-docs/` | `shared/` |
| ai | `doc/` | `ai/` |
| ai | `shared-docs/` | `shared/` |

## 新机器 / 新克隆后

```powershell
git clone git@github.com:ChenYX-0v0/Teyvat-Guide-Docs.git C:\Users\HONOR\Desktop\teyvat-docs
powershell -ExecutionPolicy Bypass -File C:\Users\HONOR\Desktop\teyvat-docs\setup-docs.ps1
```

（Junction 不进 git，必须跑一次脚本重建；项目路径不同请改脚本顶部的三个变量。）

## 约定（重要）

1. **只在本仓改文档**——三个项目内的 `docs/` / `doc/` / `aidoc/` / `shared-docs/` 都是链接，不要试图在项目仓里提交文档。
2. **文档提交只发生在本仓**；三个项目仓的 `.gitignore` 已忽略上述链接路径。
3. **跨项目契约放 `shared/`**，项目内部文档放各自目录；禁止在项目里另存副本（历史上 `admin/docs/teyvatGuide/`、`admin/aidoc/doc/` 就是副本，已清理）。
4. 编号在**各自目录内**唯一即可（web 与 admin 均存在 01~05，靠目录区分；交叉引用请写明路径）。
5. 变更契约类文档（`shared/`）后，需同步检查三个项目是否受影响并在提交信息中说明。
6. **本地调试密钥例外条款**（2026-09-12）：三个项目的 `AGENTS.md` 均已写入——**本机开发调试期间，AI 可直接读取 / 使用 / 对齐本地密钥**（`.env`、`config/config.yaml`、注册表凭证），用于启动服务、跑测试、带密钥联调；但**不入仓、不回显、只对本机、不擅自换钥、付费 Key 节制**。属跨项目工作约定，改动需三处同步。
