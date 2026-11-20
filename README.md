# 科研论文原始数据汇交管理平台

面向科研团队与研究所的论文原始数据汇交系统。以“汇交批次”为核心，把论文稿、代码、原始数据、配置、日志、结果等材料固化为不可篡改的快照，经全部作者确认、研究所审核后归档；归档材料可通过“申请—审批—限时/限次授权”受控共享。

> 在线项目主页（GitHub Pages 静态展示）：<https://laoshan-song.github.io/database-work/>
> GitHub Pages 无法运行 Flask 与 PostgreSQL；完整系统请按下方“快速开始”在本地或云服务器启动。

- 数据库：PostgreSQL 17
- 后端：Python 3.11+ / Flask 3.1 / psycopg 3
- 前端：Bootstrap 5（本地静态资源）
- 测试：pytest，25 项全部通过

完整设计说明、E-R 图、数据字典、执行计划实测数据见 **[docs/项目报告.md](docs/项目报告.md)**。

---

## 快速开始

### 1. 准备 PostgreSQL

要求本机已安装 PostgreSQL 17，并能用 `postgres` 用户连接。默认连接串：

```
postgresql://postgres@localhost:5432/srdp
```

如需要密码，请在 `pgpass.conf` 中保存，或复制 `.env.example` 为 `.env` 并修改 `DATABASE_URL`。

### 2. 安装依赖

```powershell
cd D:\数据库系统概论\2026年资料\大作业
pip install -r requirements.txt
```

### 3. 初始化数据库

```powershell
python scripts/init_db.py
```

脚本会自动：

1. 创建数据库 `srdp`（不存在时）；
2. 依次执行 `db/01_schema.sql` ~ `db/06_seed.sql`；
3. 在 `uploads/` 下生成演示文件，并校验 SHA-256。

> `01_schema.sql` 会 `DROP SCHEMA srdp CASCADE`，该命令用于重置演示环境，请勿指向生产库。

### 4. 启动

```powershell
python run.py
```

浏览器访问 <http://127.0.0.1:5000>。

---

## 演示账号

统一密码：`Demo@2026`

| 账号 | 姓名 | 身份 | 建议演示内容 |
| --- | --- | --- | --- |
| `admin` | 张伟 | INST-01 研究所管理员 | 受理/审核批次、审批材料申请 |
| `lina` | 李娜 | 论文 A 负责人 | 创建批次、发起确认、提交 |
| `wangqiang` | 王强 | 论文 A 作者 | 作者确认 |
| `chenjing` | 陈静 | 作者 + 实验维护成员 | 确认、登记实验 |
| `zhaolei` | 赵磊 | 外部作者 | 外部作者确认 |
| `sunhao` | 孙浩 | 数据使用者 | 浏览共享目录、申请、下载 |
| `ops` | 周运维 | 系统管理员 | 全局审计、邮件队列 |
| `liumin` | 刘敏 | INST-02 论文负责人 | 对照项目 |
| `zhengkai` | 郑凯 | INST-02 管理员 | 验证跨所越权被拒 |

演示数据：

- 论文 A《面向科研数据汇交的多版本溯源方法研究》：4 位作者（3 内部 + 1 外部）
  - 批次 1：已退回（意见：补充 CUDA 版本）
  - 批次 2：已归档（含环境说明 v2、结果指标 v2）
  - 批次 3：草稿，可现场走完整流程
- 论文 B：INST-02 对照项目（跨所隔离）
- 论文 C：草稿批次
- 孙浩对“实验原始数据 v1”有 7 天 / 5 次授权（已下载 1 次），对“图3 对比曲线 v1”有一条待审批申请

---

## 功能概览

- **论文与作者**：论文元数据、作者顺序、内部/外部作者、维护成员授权
- **材料版本**：8 类材料（代码/原始数据/配置/日志/结果/图表/说明/数据字典），版本只增不改，SHA-256 校验
- **实验追溯**：结果 → 运行 → 代码/数据/配置/日志版本全链路
- **汇交批次**：草稿、冻结、作者确认、提交、受理、审核、退回、归档、撤回
- **两轮汇交**：退回后新建下一轮，历史版本与审核意见完整保留
- **受控共享**：访问申请、管理员审批、限时/限次授权、下载登记、撤销
- **组织与权限**：研究所、人员、任职有效期、账号、角色授予/撤销
- **审计与通知**：关键动作审计日志、站内通知、邮件发件箱
- **管理员视图**：待审核批次、访问申请、全局审计、邮件队列

---

## 项目结构

```
.
├─ app/                     Flask 应用
│  ├─ blueprints/           auth / main / papers / batches / experiments /
│  │                        access / org / admin
│  ├─ templates/            Jinja2 模板
│  ├─ static/               Bootstrap 与自定义样式
│  ├─ config.py             配置（环境变量）
│  ├─ db.py                 连接、查询、事务
│  ├─ security.py           登录态与权限判断
│  └─ utils.py              上传、格式化、提示
├─ db/
│  ├─ 01_schema.sql         28 张表与约束
│  ├─ 02_views.sql          8 个视图
│  ├─ 03_functions.sql      25 个业务函数（16 个业务存储过程）+ 21 个触发器函数
│  ├─ 04_triggers.sql       26 个触发器
│  ├─ 05_indexes.sql        31 个查询索引
│  ├─ 06_seed.sql           演示数据
│  ├─ 07_queries.sql        Q1–Q10 代表性查询
│  └─ 08_explain.sql        E1–E7 执行计划
├─ scripts/
│  ├─ init_db.py            建库 / 重置 / 生成演示文件
│  └─ gen_bench.py          生成压测库 srdp_bench
├─ tests/                   pytest 测试
├─ docs/项目报告.md          课程报告
├─ run.py                   开发启动入口
├─ requirements.txt
└─ .env.example
```

---

## 数据库设计要点

- **28 张表**：组织人员、论文作者、文件、材料版本、实验、批次、确认、审核、访问授权、审计、通知、邮件。
- **8 个视图**：批次进度、汇交总览、确认明细、作者待办、未完成论文、结果追溯、材料版本、授权状态。
- **16 个存储过程**：所有写业务统一返回 `op_result(ok, code, message)`。
- **26 个触发器**：
  - 批次状态机、冻结保护、草稿删除限制；
  - 作者/材料/实验快照回填与跨论文校验；
  - 材料版本、论文版本、审核记录、审计日志只增不改；
  - 授权必须来自已批准申请；
  - 关键动作自动审计。
- **31 个查询索引**：含多个部分索引（`WHERE is_current`、`WHERE revoked_at IS NULL`、`WHERE NOT is_read`）。

业务规则全部在数据库层实现，页面只负责收集参数与展示结果；即使绕过应用直接 `psql` 写库，也会被触发器拒绝。

---

## 测试

测试使用独立数据库 `srdp_test`，不会污染演示库。

```powershell
python -m pytest -q
```

预期输出：

```
25 passed
```

覆盖：

- 完整流程：草稿 → 4 作者确认 → 提交 → 跨所越权 → 受理 → 退回校验 → 归档
- 约束兜底：冻结快照、非法状态流转、不可变历史、快照回填、跨论文材料、授权来源
- 权限边界：维护成员无确认权、跨所管理员不能审批、无关用户 403
- 并发：并发提交、并发建批次、并发下载限额

可通过环境变量 `SRDP_TEST_DATABASE_URL` 指向其他测试库。

---

## 性能验证

演示库数据量小，优化器会偏向全表扫描。为验证索引效果，项目提供独立压测库：

```powershell
python scripts/gen_bench.py
psql -d srdp_bench -f db/08_explain.sql
```

压测库规模（约 16 秒生成）：

| 对象 | 行数 |
| --- | --- |
| 论文 | 3,003 |
| 材料版本 | 24,018 |
| 汇交批次 | 3,003 |
| 实验结果 | 9,003 |
| 审计日志 | 231,249 |

实测（默认计划 vs 关闭索引扫描）：

| 用例 | 命中索引 | 无索引 | 提升 |
| --- | --- | --- | --- |
| 论文列表 | 0.034 ms | 0.611 ms | ~18× |
| 作者待办（部分索引） | 0.353 ms | 2.451 ms | ~7× |
| 审计日志按对象查询 | 0.145 ms | 147.407 ms | ~1000× |
| 材料最新版本 | 0.082 ms | — | — |
| 实验追溯 | 0.410 ms | 17.362 ms | ~42× |

详细计划与索引说明见 `db/08_explain.sql` 和报告第 8 章。

---

## 常用命令

```powershell
# 重建演示库（会清空 srdp schema）
python scripts/init_db.py

# 只建库执行 SQL，不生成演示文件
python scripts/init_db.py --no-files

# 库已存在，仅重建 schema
python scripts/init_db.py --skip-create

# 跑测试
python -m pytest -q

# 重建压测库
python scripts/gen_bench.py

# 执行代表性查询（示例参数）
psql -d srdp -v batch_id=2 -v paper_id=2 -v person_id=11 -f db/07_queries.sql
```

---

## 配置

复制 `.env.example` 为 `.env`（可选）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `DATABASE_URL` | `postgresql://postgres@localhost:5432/srdp` | 数据库连接串 |
| `SECRET_KEY` | `srdp-dev-secret-change-me` | Flask 会话密钥，部署时务必更换 |
| `SRDP_SEARCH_PATH` | `srdp,public` | 连接时 `search_path` |
| `SRDP_UPLOAD_DIR` | `./uploads` | 上传文件目录 |
| `SRDP_MAX_UPLOAD_MB` | `200` | 单次上传大小上限 |
| `SRDP_TEST_DATABASE_URL` | `postgresql://postgres@localhost:5432/srdp_test` | 测试库 |
| `SRDP_BENCH_DATABASE_URL` | `postgresql://postgres@localhost:5432/srdp_bench` | 压测库 |

---

## 常见问题

**1. 提示找不到 `libpq` 或 `psycopg` 连接失败**

`app/pglib.py` 会自动尝试常见安装路径。若 PostgreSQL 装在非默认目录，请设置：

```powershell
$env:PATH = "C:\Program Files\PostgreSQL\17\bin;$env:PATH"
```

**2. `psql` 输出中文乱码**

```powershell
chcp 65001
$env:PGCLIENTENCODING = "UTF8"
$env:PYTHONIOENCODING = "utf-8"
```

**3. 登录后页面 500 / 数据库不存在**

重新执行 `python scripts/init_db.py`。该脚本会创建 `srdp` 库并重建 schema。

**4. 端口 5000 被占用**

修改 `run.py` 中的 `port`，或设置环境变量后自行启动。

**5. 测试连到了演示库**

测试夹具会显式覆盖 `DATABASE_URL` 为 `srdp_test`。若自行编写脚本，请确认在导入 `app.config` 前设置环境变量，或直接覆盖 `app.config["DATABASE_URL"]`。

---

## 许可与说明

本项目为数据库系统概论课程大作业，演示数据均为虚构。生产部署前请更换 `SECRET_KEY`、限制数据库权限、启用 HTTPS，并将上传目录替换为对象存储。
