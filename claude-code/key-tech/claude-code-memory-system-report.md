# Claude Code 记忆系统深度分析报告

## 目录

1. [整体架构](#1-整体架构)
2. [存储结构](#2-存储结构)
3. [四种记忆类型详解](#3-四种记忆类型详解)
4. [记忆的写入：三条路径](#4-记忆的写入三条路径)
5. [记忆的读取：Sonnet 智能检索](#5-记忆的读取sonnet-智能检索)
6. [记忆整合引擎 (autoDream)](#6-记忆整合引擎-autodream)
7. [记忆老化与漂移检测](#7-记忆老化与漂移检测)
8. [团队记忆与安全防护](#8-团队记忆与安全防护)
9. [决策边界：代码 vs LLM 的分工](#9-决策边界代码-vs-llm-的分工)
10. [完整生命周期：从冷启动到成熟](#10-完整生命周期从冷启动到成熟)
11. [性能优化与关键常量](#11-性能优化与关键常量)
12. [源码文件索引](#12-源码文件索引)

---

## 1. 整体架构

Claude Code 的记忆系统是一套**基于文件的、由 AI 自管理的持久化知识库**——LLM 自己决定记什么、怎么组织、何时整理、何时遗忘。

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Claude Code 记忆系统                             │
│                                                                         │
│  ┌─ 存储层 (文件系统) ──────────────────────────────────────────────┐   │
│  │  ~/.claude/projects/<project-slug>/memory/                       │   │
│  │  ├── MEMORY.md           ← 索引 (≤200行, ≤25KB)                 │   │
│  │  ├── *.md                ← 记忆文件 (最多 200 个)                │   │
│  │  ├── team/               ← 团队记忆 (可选)                       │   │
│  │  ├── logs/               ← KAIROS 日志 (可选)                    │   │
│  │  └── .consolidate-lock   ← Dream 进程锁                         │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─ 写入层 ─────────────────────────────────────────────────────────┐   │
│  │  路径 A: 主 Agent 直接写 (用户说"记住这个")                       │   │
│  │  路径 B: extractMemories 后台提取 (每轮对话后自动)                │   │
│  │  路径 C: autoDream 后台整合 (24h + 5 sessions 后触发)            │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─ 读取层 ─────────────────────────────────────────────────────────┐   │
│  │  ① MEMORY.md 索引 → 始终注入系统提示词                            │   │
│  │  ② scanMemoryFiles() → 扫描所有 .md 的 frontmatter               │   │
│  │  ③ Sonnet 选 Top-5 最相关 → 注入为消息附件                       │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─ 安全层 ─────────────────────────────────────────────────────────┐   │
│  │  路径验证 / symlink 防逃逸 / 密钥扫描 / 工具权限隔离 / 双重截断  │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 存储结构

### 单个记忆文件

每个记忆是独立的 Markdown 文件，带 YAML frontmatter：

```markdown
---
name: 测试策略偏好
description: 集成测试必须用真实数据库 — 源于 mock/prod 不一致事故
type: feedback
---

集成测试必须连接真实数据库，不要用 mock。

**Why:** 上季度 mock 测试全部通过，但生产 migration 失败。mock 和 prod 行为不一致导致问题被掩盖。

**How to apply:** 所有 integration test 和 e2e test。纯逻辑的 unit test 可以不连 DB。
```

### MEMORY.md 索引

```markdown
# Memory Index

## User
- [user_role.md](user_role.md) - 资深后端工程师，新接触 React

## Feedback
- [feedback_testing.md](feedback_testing.md) - 测试必须用真实 DB

## Project
- [project_stack.md](project_stack.md) - React 18 + Prisma + PostgreSQL
- [project_migration.md](project_migration.md) - API v2→v3 迁移中，截止 2026-05-01

## References
- [reference_ci.md](reference_ci.md) - CI 在 GitHub Actions，部署看板在 Grafana
```

### 目录结构

```
~/.claude/projects/-Users-goodnight-my-project/
├── memory/
│   ├── MEMORY.md
│   ├── user_role.md
│   ├── feedback_testing.md
│   ├── project_stack.md
│   ├── reference_ci.md
│   ├── .consolidate-lock
│   ├── team/                  ← 团队共享记忆
│   │   ├── MEMORY.md
│   │   └── *.md
│   └── logs/                  ← KAIROS 模式日志
│       └── 2026/04/2026-04-05.md
└── transcripts/               ← 会话记录 (Dream 会读)
    └── *.jsonl
```

---

## 3. 四种记忆类型详解

### 总览

| 类型 | 记什么 | 结构要求 | Scope | 衰减速度 |
|------|--------|---------|-------|---------|
| **user** | 用户是谁 | 自由 | 始终私有 | 很慢 |
| **feedback** | 怎么干活 | Rule + Why + How | 默认私有 | 慢 |
| **project** | 在做什么 | Fact + Why + How | 倾向团队 | 快 |
| **reference** | 去哪找 | 自由 | 通常团队 | 中 |

### 什么不该存

```
✗ 代码模式、架构、文件路径 → 读代码即可推断
✗ Git 历史、谁改了什么 → git log / git blame 是权威来源
✗ 调试方案、修复配方 → 修复在代码里，commit message 有上下文
✗ CLAUDE.md 中已有的内容 → 不需要重复
✗ 临时任务详情 → 用 Task/Plan，不用 Memory
```

### 3.1 User — 用户画像

```
记什么: 用户的角色、目标、职责、知识水平、偏好
目的:   让 LLM 针对不同用户定制交互方式
        (和资深工程师 vs 编程新手应该有不同的沟通方式)

触发信号:
  用户: "我是数据科学家，在排查日志系统"
  → 保存: user 类型, "数据科学家，关注可观测性/日志"

  用户: "Go 写了十年了但第一次碰这个项目的 React 部分"
  → 保存: user 类型, "Go 专家, React 新手 — 用后端类比解释前端"

始终私有 — 个人角色不应暴露给团队
```

### 3.2 Feedback — 行为校准 (最精巧的类型)

```
记什么: 用户对 LLM 工作方式的指导 — 纠正 + 确认
目的:   让 LLM 跨会话保持一致的工作方式，不重蹈覆辙
```

**核心设计：必须同时记录纠正和确认**

```
为什么确认也要记?

  源码注释: "Record from failure AND success: if you only save
  corrections, you will avoid past mistakes but drift away from
  approaches the user has already validated, and may grow overly
  cautious."

  只记纠正 → LLM 知道什么不该做，但忘了什么该做 → 越来越犹豫
  纠正+确认都记 → LLM 既避雷也确信 → 行为稳定
```

**两种触发信号：**

```
信号 A — 纠正 (容易识别):
  用户: "别在测试里 mock 数据库"
  用户: "stop summarizing at the end"
  用户: "commit message 别用中文"

信号 B — 确认 (很安静，prompt 特别提醒 "watch for them"):
  用户: "嗯，单个大 PR 是对的，拆开纯属浪费时间"
  用户: "好的" (接受了一个非显而易见的方案，没有反对)
```

**三段式结构（强制要求）：**

```
1. 规则本身: "集成测试必须连真实数据库"
2. **Why:**   "上季度 mock 测试通过但生产 migration 失败"
3. **How to apply:** "所有 integration/e2e test。纯逻辑 unit test 例外"

为什么需要 Why?
  "Knowing WHY lets you judge edge cases instead of blindly following the rule."
  → 规则: "测试不要 mock"
  → 边缘: 有个测试只验证 JSON 序列化，不涉及 DB
  → 不知道 Why: 也连真实 DB → 测试变慢，无意义
  → 知道 Why (mock/prod 不一致): JSON 序列化和 DB 无关 → 可以不连
```

**Scope 判断：**

```
私有 (默认): 个人风格偏好
  "回复不加末尾总结" / "用简洁回答" / "一个大 PR 比多个小 PR 好"

团队: 项目级约定 (所有成员都应遵守)
  "测试必须连真实 DB" / "commit message 用 conventional commits"

冲突: 个人 feedback 和团队 feedback 矛盾?
  → 不保存个人版本，或明确标注是对团队规则的覆盖
```

### 3.3 Project — 项目动态

```
记什么: 进行中的工作、目标、bug、事件等代码/git 无法推断的信息
目的:   理解工作的广义上下文和动机

触发信号:
  用户: "周四后冻结非关键合并，移动端在切 release"
  → 保存: "合并冻结 2026-04-10 起。Why: 移动端 release。
           How: 标记周四后的非关键 PR"

  用户: "拆旧 auth 中间件是因为法务说 session token 存储不合规"
  → 保存: "auth 重写由合规驱动，非技术债。
           How: scope 决策优先合规而非人机工效"

关键规则: 相对日期必须转为绝对日期
  "周四" → "2026-04-10" (否则下次读到时 "周四" 的含义已变)

衰减快 — 项目状态常变，需要频繁更新或由 Dream 清理
倾向团队共享
```

### 3.4 Reference — 外部书签

```
记什么: 指向外部系统中信息位置的"书签"
目的:   LLM 不联网，不知道你的外部系统在哪
        记下来以后可以告诉用户去哪里找信息

触发信号:
  用户: "bug 都在 Linear 的 INGEST 项目里"
  → 保存: "pipeline bug 在 Linear INGEST 项目中跟踪"

  用户: "oncall 看的是 grafana.internal/d/api-latency"
  → 保存: "oncall 延迟看板，改请求路径代码时需关注"

结构最自由 — 没有强制 Why + How，一句话书签即可
通常团队 — 外部系统指针对所有团队成员都有用

特殊检索规则:
  如果用户最近刚用了某工具 → 不选那个工具的参考文档
  但如果有警告/注意事项 → 仍然选中 (安全警告不过滤)
```

### 类型边界判断

同一件事可能是不同类型，取决于说的是什么方面：

```
"CI 在 GitHub Actions"           → reference (在哪里)
"CI 必须全绿才能合并"             → feedback  (怎么做)
"CI 昨天挂了，正在修"             → project   (正在发生什么)
```

---

## 4. 记忆的写入：三条路径

```
                    记忆写入
                       │
         ┌─────────────┼─────────────┐
         │             │             │
    路径 A          路径 B         路径 C
    主 Agent       提取 Agent     整合 Agent
    直接写入       (extractMem)   (autoDream)
    用户驱动        每轮自动       周期触发
    无限制          ≤5轮           不限轮次
```

### 路径 A：主 Agent 直接写入

用户明确说"记住这个"时，LLM 两步操作：写记忆文件 → 更新 MEMORY.md 索引。

### 路径 B：extractMemories 后台自动提取

**记忆系统最核心的自动化机制。**

```
每轮 query 循环结束 (StopHooks)
     │
     ▼ 门控检查 (全由代码决定):
     ├─ feature flag 开启?
     ├─ autoMemory 启用?
     ├─ 是主 Agent (非子 agent)?
     ├─ 节流: turnsSince >= N?
     └─ 互斥: 主 Agent 本轮没直接写记忆?
     │
     ▼ 全部通过
     │
     ▼ Fork 提取 Agent:
     ├─ 预注入: 现有记忆 manifest (避免重复)
     ├─ maxTurns: 5
     ├─ 工具权限:
     │   ├─ Read/Grep/Glob → 无限制
     │   ├─ Bash → 只读 (ls, find, grep, cat, stat, ...)
     │   ├─ Edit/Write → 只能写 memory/ 目录
     │   └─ 其他 → 全部禁止
     └─ 提取 Agent 自主决定:
         ├─ 这段对话有什么值得记住的?
         ├─ 属于哪种类型?
         ├─ 新建还是更新已有的?
         └─ 写文件 + 更新索引
```

**互斥机制**: 如果主 Agent 本轮已经写了记忆目录（用户主动要求），提取 Agent 跳过本轮，避免冲突。

**节流与合并**: 提取不是每轮都跑——通过 `turnsSinceLastExtraction` 计数器节流。如果上一次提取还在跑，新请求被 stash，等上一次完成后做一次 "trailing extraction"。

### 路径 C：autoDream 后台整合

详见[第 6 节](#6-记忆整合引擎-autodream)。

---

## 5. 记忆的读取：Sonnet 智能检索

```
会话启动，用户输入 "帮我把 API v2 迁移到 v3"
     │
     ▼ ① scanMemoryFiles() — 扫描 memory/*.md 的 frontmatter
     │  ├─ 只读前 30 行 (不读全文)
     │  ├─ 解析 YAML: name, description, type
     │  ├─ 按 mtime 倒序，截取前 200 个
     │  └─ 过滤已浮现的 (避免同会话重复注入)
     │
     ▼ ② Sonnet 选 Top-5
     │  ├─ 输入: 用户问题 + 200 个记忆的 frontmatter (~2K tokens)
     │  ├─ 指令: "选出最多 5 个明确有用的。宁缺毋滥。"
     │  ├─ max_tokens: 256
     │  └─ 输出: JSON { selected_memories: [...] }
     │
     ▼ ③ 注入为消息附件
        ├─ Read 选中文件的完整内容
        ├─ 附加老化警告 (超过 1 天的记忆)
        └─ 创建 AttachmentMessage

Sonnet 选择示例:
  200 个记忆中 → 选中:
  ├─ project_migration.md  ← "v2→v3 迁移中" 直接相关
  ├─ project_stack.md      ← 技术栈信息
  ├─ reference_api_docs.md ← API 文档位置
  ├─ feedback_testing.md   ← 迁移后需要测试
  └─ user_role.md          ← 用户是后端出身
  未选:
  ├─ project_deploy.md     ← 和迁移无关
  └─ project_login_bug.md  ← 和迁移无关
```

**为什么不全量加载？**

| 方案 | 成本 | 精度 | 结果 |
|------|------|------|------|
| 全部加载 200 个 | ~100K tokens, 占上下文 50% | 高但浪费 | 不可行 |
| 关键词匹配 | 0 | 低 (无语义理解) | 效果差 |
| **Sonnet 检索** | ~2K tokens + 1 次 API ($0.001) | **高** | **采用** |

---

## 6. 记忆整合引擎 (autoDream)

### 三重门控

```
每轮 query 结束 → StopHooks → executeAutoDream()
     │
     ▼ Gate 1: 时间 (成本: 1 次 fs.stat)
     │  读取 .consolidate-lock 的 mtime
     │  hoursSince < 24? → 跳过
     │
     ▼ Gate 2: 会话数 (成本: N 次 fs.stat)
     │  扫描 transcripts/ 目录
     │  mtime > lastConsolidatedAt 的会话 < 5? → 跳过
     │  (扫描节流: 10 分钟内不重复扫描)
     │
     ▼ Gate 3: 锁 (成本: 文件读写)
        读取 .consolidate-lock 内容 (PID)
        ├─ 锁不存在 → 获取
        ├─ PID 活着 + < 60 分钟 → 放弃
        ├─ PID 死了 → 回收
        └─ > 60 分钟 → 强制回收 (防死锁)
```

### 四阶段协议

**类比**：书桌上堆满了便签，"夜间整理员"按四步整理。

#### Phase 1 — Orient（定位）：先看看有什么

```
整理员做的事:
  ls memory/           → 看看目录里有哪些文件
  Read MEMORY.md       → 看看索引
  快速浏览 topic 文件  → 知道每个文件写了什么

目的: 摸清现状，避免创建重复
```

#### Phase 2 — Gather（收集）：寻找新信号

```
三个信号来源（按优先级）:

  ① 日志文件 (logs/YYYY/MM/*.md)
     KAIROS 模式下的每日对话摘要，最密集的信号来源
     例: 发现 "用户把 React 17 升级到了 18"
     → project_stack.md 里还写着 React 17，需要更新！

  ② 漂移检测 (记忆 vs 现实)
     记忆说 "配置在 src/config/database.ts"
     → ls 一查 → 不存在！→ grep 发现在 src/lib/db.ts
     → 记忆过时了

  ③ 会话记录搜索 (transcripts/*.jsonl)
     用 grep 窄范围查特定关键词 (不穷举读取!)
     例: grep "migration failed" transcripts/ | tail -50
```

#### Phase 3 — Consolidate（整合）：动手整理

```
具体操作:
  ├─ 合并重复: 两个 React 版本的记忆 → 合并为一个
  ├─ 删除过时: 已完成的 TODO → 删除
  ├─ 修正错误: URL 变了 → 更新
  ├─ 日期修正: "上周五" → "2026-03-28"
  └─ 创建新记忆: 从新信号中发现值得保存的
```

#### Phase 4 — Prune（修剪）：收尾索引

```
确保 MEMORY.md 精简准确:
  ├─ ≤ 200 行, ≤ 25KB (硬限制)
  ├─ 每行 ≤ ~150 字符
  ├─ 删除指向已删文件的条目
  ├─ 更新变化了的描述
  └─ 解决矛盾条目
```

### 整合前后对比

```
整合前 (6 个文件，有冗余):
  project_stack.md (3天前): "React 17"         ← 过时
  project_stack_v2.md (1天前): "React 18"      ← 重复
  project_todo_1.md (5天前): "修 Login bug"    ← 已完成
  project_todo_2.md (2天前): "Login 已修复"    ← 已完成
  feedback_testing.md: "测试用真实 DB"          ← 有效
  user_role.md: "资深后端工程师"                ← 有效

整合后 (3 个文件，精炼):
  project_stack.md: "React 18 + Prisma (2026-04-03 从 17 升级)"  ← 合并
  feedback_testing.md: 不变
  user_role.md: 不变
  已删: project_stack_v2.md, project_todo_1.md, project_todo_2.md
```

---

## 7. 记忆老化与漂移检测

记忆可能随时间失效——代码改了但记忆还是旧的。

### 老化标记

```
memoryAge(mtime):
  今天的记忆 → 无标记
  昨天的 → 无标记
  ≥ 2 天 → 附加 <system-reminder> 警告:
    "This memory is 5 days old. Verify against current state."
```

### 漂移防护 (系统提示词)

```
"记忆说 X 存在" ≠ "X 现在存在"

在向用户推荐基于记忆的信息前:
  如果记忆提到文件路径 → 检查文件是否存在
  如果记忆提到函数/flag → grep 确认它还在
  如果用户即将基于推荐行动 → 先验证

如果记忆和现实冲突 → 信任现实，更新或删除记忆
```

---

## 8. 团队记忆与安全防护

### 团队记忆

```
位置: memory/team/ (feature flag tengu_herring_clock)

适合团队共享的:
  ├─ reference: 外部系统指针 (所有人需要)
  ├─ project: 项目决策/截止日期 (团队上下文)
  └─ feedback: 项目级约定 (如 "测试必须用真实 DB")

始终私有的:
  └─ user: 个人角色/偏好
```

### 安全防护体系

**路径安全 (validateMemoryPath)**:
```
拒绝: ../foo (遍历) / 根目录 / null 字节 / ．．／(Unicode 全角攻击)
Symlink 防护: 两阶段验证 (字符串级 + realpath)
悬空 symlink 检测 / 循环 symlink 检测
```

**密钥扫描 (团队记忆写入前)**:
```
30+ gitleaks 规则: AWS / GitHub PAT / OpenAI / Anthropic / Stripe /
Private Key / Slack / Grafana / Sentry / npm / PyPI ...
发现密钥 → 阻止写入，返回错误
```

**工具权限隔离**:
```
┌──────────┬──────────────┬────────────────────┐
│  工具     │  主 Agent     │  提取/整合 Agent    │
├──────────┼──────────────┼────────────────────┤
│ Read     │ 无限制        │ 无限制              │
│ Grep/Glob│ 无限制        │ 无限制              │
│ Bash     │ 无限制        │ 只读命令            │
│ Edit     │ 无限制        │ 只能写 memory/      │
│ Write    │ 无限制        │ 只能写 memory/      │
│ Agent等  │ 可用          │ 禁止                │
└──────────┴──────────────┴────────────────────┘
```

**MEMORY.md 双重截断**:
```
行数截断: > 200 行 → 截取前 200 行
字节截断: > 25KB → 截取到最后一个完整行
为什么需要双重? 200 行 × 每行 1KB = 200KB，远超 25KB
```

---

## 9. 决策边界：代码 vs LLM 的分工

### 完整决策图

```
■ = 代码决定 (确定性, LLM 无法改变)
□ = LLM 决定 (自主性, 被 prompt 引导)

开启记忆?          ■ 代码 (feature flag + settings)
存在哪?            ■ 代码 (路径计算)
何时提取?          ■ 代码 (StopHooks + 节流 + 互斥)
提取什么?          □ LLM (被类型/排除规则引导)
怎么分类?          □ LLM (在 4 种类型框架内判断)
文件名叫什么?      □ LLM 自主决定
内容怎么写?        □ LLM (被三段式结构引导)
写到哪个目录?      ■ 代码 (canUseTool 硬限制)
何时检索?          ■ 代码 (每轮自动预取)
候选池多大?        ■ 代码 (200 文件上限)
选哪 5 条?         □ Sonnet (被"宁缺毋滥"引导)
怎么注入?          ■ 代码 (AttachmentMessage + 老化警告)
何时整合?          ■ 代码 (24h + 5 sessions + 锁)
怎么整合?          □ LLM (被四阶段协议引导)
安全校验?          ■ 代码 (路径/symlink/密钥/权限)
```

### 设计哲学

```
代码画围栏，LLM 在围栏内自由发挥。

代码擅长: 确定性逻辑、安全保证、资源控制
  → 负责: 时机控制 + 权限边界 + 安全校验 + 体积限制

LLM 擅长: 理解语义、判断重要性、组织知识
  → 负责: 内容判断 + 语义理解 + 知识组织 + 质量把控

四种类型分类法是典型的"硬框架 + 软执行":
  框架 (4 种类型): 代码写死，不可协商
  分类执行: LLM 在框架内自主判断
```

---

## 10. 完整生命周期：从冷启动到成熟

```
═══ Day 1, Session 1: 冷启动 ═══
  记忆: 空
  LLM 从零探索项目，效率最低
  → extractMemories 保存: user_role.md, project_stack.md

═══ Day 1, Session 2 ═══
  记忆: 2 个文件
  Sonnet 选中 project_stack.md → LLM 已知技术栈，不用重新探索

═══ Day 2, Session 3-7 ═══
  每次 extractMemories 持续积累
  记忆: ~10 个文件，LLM 越来越"懂"项目

═══ Day 3: autoDream 触发 ═══
  48h > 24h ✓, 7 sessions > 5 ✓
  Dream 整合: 合并重复、删除已完成 TODO、修正过时信息
  记忆: 8 个文件 (更精炼)

═══ Day 7: 用户写 CLAUDE.md ═══
  将稳定信息 (技术栈、约定) 从记忆搬到 CLAUDE.md
  CLAUDE.md = 稳定的"入职手册"
  记忆系统 = 动态的"工作日志"
  → 两者互补，LLM 从第一句话就像"了解项目的同事"

═══ 持续循环 ═══
  对话 → extractMemories 提取新知识
  → 积累到阈值 → autoDream 整合
  → 下次会话 → Sonnet 精选注入
  → 认知正向循环
```

---

## 11. 性能优化与关键常量

### 性能优化

| 措施 | 效果 |
|------|------|
| `getAutoMemPath()` 路径缓存 | 每会话只算 1 次 |
| scanMemoryFiles 单遍扫描 | readdir + stat 一起，syscall 减半 |
| Frontmatter 只读 30 行 | 200 个文件只读头部 |
| Sonnet 检索只用 frontmatter | 200 个记忆 ≈ 2K tokens (非全量 100K) |
| 记忆预取异步化 | API 流式调用时后台执行，不阻塞 |
| 提取 Agent 共享 Prompt Cache | Fork 继承父对话前缀 |
| 密钥正则懒编译 | 第一次扫描时才编译 |
| Dream 门控成本递增 | 99% 的检查在 1 次 stat 后返回 |
| alreadySurfaced 去重 | 同会话不重复注入 |

### 关键常量

| 常量 | 值 | 用途 |
|------|---|------|
| MAX_ENTRYPOINT_LINES | 200 | MEMORY.md 行数上限 |
| MAX_ENTRYPOINT_BYTES | 25,000 | MEMORY.md 字节上限 |
| MAX_MEMORY_FILES | 200 | 扫描文件数上限 |
| FRONTMATTER_MAX_LINES | 30 | frontmatter 读取行数 |
| Top-K | 5 | Sonnet 每次选出的记忆数 |
| Sonnet max_tokens | 256 | 检索 API 输出上限 |
| extractMemories maxTurns | 5 | 提取 Agent 轮次上限 |
| Dream minHours | 24 | 整合最小间隔 |
| Dream minSessions | 5 | 整合最小会话数 |
| SESSION_SCAN_INTERVAL_MS | 600,000 | Dream 扫描节流 (10分钟) |
| HOLDER_STALE_MS | 3,600,000 | 锁过期时间 (60分钟) |
| Secret Scanner Rules | 30+ | gitleaks 密钥规则数 |

---

## 12. 源码文件索引

| 文件 | 职责 |
|------|------|
| **核心模块** | |
| `src/memdir/memdir.ts` | 记忆目录核心: 加载、提示词构建、截断 |
| `src/memdir/paths.ts` | 路径解析、验证、安全检查 |
| `src/memdir/memoryTypes.ts` | 四种类型定义、提示词模板 |
| `src/memdir/memoryScan.ts` | 文件扫描、frontmatter 解析 |
| `src/memdir/memoryAge.ts` | 老化检测、新鲜度文本 |
| `src/memdir/findRelevantMemories.ts` | Sonnet 智能检索 |
| `src/memdir/teamMemPaths.ts` | 团队记忆路径安全 |
| **写入** | |
| `src/services/extractMemories/extractMemories.ts` | 自动提取 Agent |
| `src/services/extractMemories/prompts.ts` | 提取提示词 |
| `src/services/autoDream/autoDream.ts` | 整合引擎 |
| `src/services/autoDream/consolidationPrompt.ts` | 四阶段提示词 |
| `src/services/autoDream/consolidationLock.ts` | 进程锁 |
| `src/services/autoDream/config.ts` | Dream 配置 |
| **安全** | |
| `src/services/teamMemorySync/secretScanner.ts` | 密钥检测规则 |
| `src/services/teamMemorySync/teamMemSecretGuard.ts` | 写入前扫描 |
| `src/utils/memoryFileDetection.ts` | 文件分类 |
| **集成点** | |
| `src/query/stopHooks.ts` | 提取 + Dream 的触发点 |
| `src/utils/attachments.ts` | 记忆预取和注入 |
| `src/constants/prompts.ts` | 系统提示词中记忆部分 |
| `src/context.ts` | MEMORY.md 加载到 userContext |
