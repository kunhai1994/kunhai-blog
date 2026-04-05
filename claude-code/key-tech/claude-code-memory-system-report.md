# Claude Code 记忆系统深度分析报告

## 目录

1. [整体架构](#1-整体架构)
2. [记忆的四种类型](#2-记忆的四种类型)
3. [记忆的存储结构](#3-记忆的存储结构)
4. [记忆的写入：三条路径](#4-记忆的写入三条路径)
5. [记忆的读取：Sonnet 智能检索](#5-记忆的读取sonnet-智能检索)
6. [记忆提取 Agent (extractMemories)](#6-记忆提取-agent-extractmemories)
7. [记忆整合引擎 (autoDream)](#7-记忆整合引擎-autodream)
8. [记忆老化与漂移检测](#8-记忆老化与漂移检测)
9. [团队记忆同步](#9-团队记忆同步)
10. [安全防护体系](#10-安全防护体系)
11. [性能优化设计](#11-性能优化设计)
12. [完整数据流：一个例子](#12-完整数据流一个例子)
13. [关键常量与阈值](#13-关键常量与阈值)
14. [源码文件索引](#14-源码文件索引)

---

## 1. 整体架构

### 一句话概括

Claude Code 的记忆系统是一套**基于文件的、由 AI 自管理的持久化知识库**——LLM 自己决定记什么、怎么组织、何时整理、何时遗忘。

### 架构总图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Claude Code 记忆系统                             │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    存储层 (文件系统)                               │    │
│  │                                                                 │    │
│  │  ~/.claude/projects/<project-slug>/memory/                      │    │
│  │  ├── MEMORY.md              ← 索引文件 (≤200行, ≤25KB)          │    │
│  │  ├── user_role.md           ← 用户记忆                          │    │
│  │  ├── feedback_testing.md    ← 反馈记忆                          │    │
│  │  ├── project_stack.md       ← 项目记忆                          │    │
│  │  ├── reference_ci.md        ← 引用记忆                          │    │
│  │  ├── ...                    ← 最多 200 个 .md 文件              │    │
│  │  ├── team/                  ← 团队记忆 (可选)                    │    │
│  │  │   ├── MEMORY.md                                              │    │
│  │  │   └── *.md                                                   │    │
│  │  ├── logs/                  ← KAIROS 模式日志                    │    │
│  │  │   └── YYYY/MM/YYYY-MM-DD.md                                 │    │
│  │  └── .consolidate-lock      ← Dream 进程锁                     │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    写入层 (三条路径)                               │    │
│  │                                                                 │    │
│  │  路径 A: 主 Agent 直接写入                                       │    │
│  │  ├─ 用户说 "记住这个" → LLM 调用 Write/Edit 工具                 │    │
│  │  └─ 实时、精确、用户主导                                         │    │
│  │                                                                 │    │
│  │  路径 B: extractMemories 后台提取                                │    │
│  │  ├─ 每轮对话结束后自动运行                                       │    │
│  │  ├─ Fork 子 agent, 最多 5 轮工具调用                             │    │
│  │  └─ 自动发现值得记住的信息                                       │    │
│  │                                                                 │    │
│  │  路径 C: autoDream 后台整合                                      │    │
│  │  ├─ 24小时 + 5个会话 后触发                                      │    │
│  │  ├─ Fork 子 agent, 读取所有会话记录                              │    │
│  │  └─ 合并、去重、删过时、控制体积                                  │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    读取层 (Sonnet 智能检索)                        │    │
│  │                                                                 │    │
│  │  每次会话启动:                                                    │    │
│  │  ① MEMORY.md 索引 → 始终注入系统提示词                           │    │
│  │  ② scanMemoryFiles() → 扫描所有 .md 文件的 frontmatter          │    │
│  │  ③ findRelevantMemories() → Sonnet 从中选 Top-5                 │    │
│  │  ④ 选中的记忆内容 → 注入为消息附件                                │    │
│  └─────────────────────────────────────────────────────────────────┘    │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐    │
│  │                    安全层                                         │    │
│  │                                                                 │    │
│  │  ├─ 路径验证 (防遍历攻击, 防 symlink 逃逸)                       │    │
│  │  ├─ 密钥扫描 (30+ gitleaks 规则, 团队记忆写入前检查)             │    │
│  │  ├─ MEMORY.md 双重截断 (200行 + 25KB)                           │    │
│  │  └─ 工具权限隔离 (提取/整合 agent 只能写记忆目录)                 │    │
│  └─────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## 2. 记忆的四种类型

Claude Code 将记忆严格分为 4 种类型，每种有不同的语义和使用场景：

```
┌──────────┬───────────────────────────────────────────────────────────┐
│  类型     │  说明                                                     │
├──────────┼───────────────────────────────────────────────────────────┤
│          │  用户的角色、目标、职责、知识水平、偏好                      │
│  user    │  帮助 LLM 针对具体用户定制交互方式                          │
│          │  例: "用户是资深后端工程师，第一次接触 React"                │
│          │  → LLM 解释前端概念时会用后端类比                           │
│          │  始终私有 (不进团队记忆)                                    │
├──────────┼───────────────────────────────────────────────────────────┤
│          │  用户对 LLM 工作方式的反馈 (纠正 + 确认)                    │
│ feedback │  结构: 规则 + Why (原因) + How to apply (应用场景)          │
│          │  例: "测试不要用 mock，要用真实数据库。                      │
│          │       Why: 上季度 mock 测试通过但生产 migration 失败。      │
│          │       How: 所有 integration test 必须连真实 DB。"           │
│          │  可私有或团队共享                                           │
├──────────┼───────────────────────────────────────────────────────────┤
│          │  进行中的工作、目标、bug、事件等代码/git 无法推断的信息       │
│ project  │  结构: 事实/决策 + Why (动机) + How to apply (影响建议)     │
│          │  例: "周四后冻结非关键合并。                                │
│          │       Why: 移动端团队在切 release 分支。                    │
│          │       How: 标记周四之后安排的非关键 PR 工作。"              │
│          │  相对日期必须转为绝对日期 ("周四" → "2026-04-10")           │
│          │  倾向团队共享                                              │
├──────────┼───────────────────────────────────────────────────────────┤
│          │  外部系统中信息所在位置的指针                                │
│reference │  例: "pipeline bug 在 Linear 的 INGEST 项目中跟踪"         │
│          │  例: "oncall 延迟看板: grafana.internal/d/api-latency"     │
│          │  始终团队共享                                               │
└──────────┴───────────────────────────────────────────────────────────┘
```

### 什么不该存为记忆

```
┌─ 明确排除的内容 ──────────────────────────────────────────────────┐
│                                                                    │
│  ✗ 代码模式、架构、文件路径、项目结构 → 读代码即可推断              │
│  ✗ Git 历史、谁改了什么 → git log / git blame 是权威来源           │
│  ✗ 调试方案、修复配方 → 修复在代码里，commit message 有上下文       │
│  ✗ CLAUDE.md 中已有的内容 → 不需要重复                             │
│  ✗ 临时任务详情、当前对话上下文 → 用 Task/Plan，不用 Memory         │
└────────────────────────────────────────────────────────────────────┘
```

---

## 3. 记忆的存储结构

### 单个记忆文件的格式

每个记忆是一个独立的 Markdown 文件，带 YAML frontmatter：

```markdown
---
name: 测试策略偏好
description: 用户要求集成测试用真实数据库，不要 mock — 源于上季度 mock/prod 不一致事故
type: feedback
---

测试不要用 mock，必须连真实数据库。

**Why:** 上季度 mock 测试全部通过，但生产环境 migration 失败了。mock 和 prod 行为不一致导致问题被掩盖。

**How to apply:** 所有 integration test 和 e2e test 必须连接真实数据库实例（可以是测试专用 DB）。只有纯逻辑的 unit test 可以不连 DB。
```

### MEMORY.md 索引文件

```markdown
# Memory Index

## User Preferences
- [user_role.md](user_role.md) - 用户是资深后端工程师，新接触 React

## Feedback
- [feedback_testing.md](feedback_testing.md) - 测试必须用真实数据库，不要 mock

## Project Context
- [project_stack.md](project_stack.md) - 技术栈 React 18 + Prisma + PostgreSQL
- [project_migration.md](project_migration.md) - 正在从 API v2 迁移到 v3，截止 2026-05-01

## References
- [reference_ci.md](reference_ci.md) - CI 在 GitHub Actions，部署看板在 Grafana
```

### 目录结构

```
~/.claude/
├── CLAUDE.md                          ← 用户级指令 (非记忆系统)
└── projects/
    └── -Users-goodnight-my-project/   ← 项目 slug (路径 sanitize)
        ├── memory/                    ← 自动记忆根目录
        │   ├── MEMORY.md             ← 索引 (≤200行, ≤25KB)
        │   ├── user_role.md          ← 私有记忆
        │   ├── feedback_testing.md
        │   ├── project_stack.md
        │   ├── reference_ci.md
        │   ├── .consolidate-lock     ← Dream 进程锁
        │   ├── team/                 ← 团队记忆 (可选)
        │   │   ├── MEMORY.md
        │   │   └── shared_conventions.md
        │   └── logs/                 ← KAIROS 日志 (可选)
        │       └── 2026/04/
        │           ├── 2026-04-03.md
        │           ├── 2026-04-04.md
        │           └── 2026-04-05.md
        └── transcripts/              ← 会话记录 (非记忆，但 Dream 会读)
            ├── abc123.jsonl
            ├── def456.jsonl
            └── ...
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
         │             │             │
    用户驱动        每轮自动       周期触发
    实时精确        后台静默       后台静默
    无限制          ≤5轮           不限轮次
```

### 路径 A：主 Agent 直接写入

当用户明确说"记住这个"时，主 Agent 直接用 Write/Edit 工具写入：

```
用户: "记住我们项目的部署流程是先 staging 再 production"

LLM 执行两步:

Step 1 — 写记忆文件:
  Write("~/.claude/projects/.../memory/project_deploy.md", content="""
  ---
  name: 部署流程
  description: 项目部署流程 — staging 先行，production 跟进
  type: project
  ---

  部署流程是先 staging 再 production。

  **Why:** 团队约定，staging 跑通后再推 production。
  **How to apply:** 部署相关建议时遵循此顺序。
  """)

Step 2 — 更新索引:
  Edit("~/.claude/projects/.../memory/MEMORY.md",
    在 Project Context 下添加:
    "- [project_deploy.md](project_deploy.md) - 部署流程 staging → production")
```

### 路径 B：extractMemories 后台自动提取

**这是记忆系统最核心的自动化机制。**

```
每轮 query 循环结束 (StopHooks 阶段)
     │
     ▼
┌─ executeExtractMemories() ──────────────────────────────────────┐
│                                                                  │
│  门控检查:                                                        │
│  ├─ feature flag tengu_passport_quail 开启?                      │
│  ├─ isAutoMemoryEnabled()?                                       │
│  ├─ 不是远程模式?                                                │
│  ├─ 是主 Agent (非子 agent)?                                     │
│  ├─ 节流: turnsSinceLastExtraction >= N?                         │
│  └─ 互斥: 主 Agent 本轮没有直接写记忆?                            │
│     (hasMemoryWritesSince 检查)                                  │
│                                                                  │
│  全部通过 ↓                                                      │
│                                                                  │
│  准备工作:                                                        │
│  ├─ scanMemoryFiles() → 获取现有记忆的 manifest                  │
│  ├─ 构建提取提示词 (包含 manifest)                                │
│  └─ 确定要分析的消息范围 (上次提取后的新消息)                      │
│                                                                  │
│  执行:                                                            │
│  ├─ runForkedAgent({                                             │
│  │    maxTurns: 5,            ← 最多 5 轮工具调用                 │
│  │    canUseTool: 受限,        ← 只能写记忆目录                   │
│  │    skipTranscript: true,    ← 不记录自己的操作                 │
│  │    querySource: 'extract_memories'                            │
│  │  })                                                           │
│  │                                                               │
│  │  提取 Agent 可用的工具:                                        │
│  │  ├─ Read / Grep / Glob / REPL → 无限制                       │
│  │  ├─ Bash → 只读命令 (ls, find, grep, cat, stat, ...)         │
│  │  ├─ Edit / Write → 只能写 memory/ 目录下的文件                 │
│  │  └─ 其他工具 → 全部禁止                                       │
│  │                                                               │
│  │  提取 Agent 的行为:                                            │
│  │  ├─ 阅读最近的对话内容                                        │
│  │  ├─ 识别值得记住的信息 (匹配 4 种类型)                         │
│  │  ├─ 检查是否已有类似记忆 (避免重复)                             │
│  │  ├─ 写入新记忆文件 / 更新已有记忆                               │
│  │  └─ 更新 MEMORY.md 索引                                       │
│  │                                                               │
│  结果:                                                            │
│  ├─ 提取写入的文件路径列表                                        │
│  ├─ appendSystemMessage("Saved N memories")                      │
│  └─ 推进 cursor (lastMemoryMessageUuid)                          │
│                                                                  │
│  telemetry:                                                       │
│  └─ tengu_extract_memories_extraction (tokens, duration, files)  │
└──────────────────────────────────────────────────────────────────┘
```

#### 提取 Agent 的提示词核心

```
你是一个记忆管理 agent。分析最近的对话，提取值得跨会话保存的信息。

现有记忆清单:
- [user] user_role.md (2026-04-03): 用户是资深后端工程师
- [project] project_stack.md (2026-04-01): React + Prisma 技术栈
- ...

规则:
1. 不要保存代码模式、架构等可从代码推断的信息
2. 不要保存 CLAUDE.md 中已有的信息
3. 不要创建重复记忆——先检查是否可以更新已有的
4. feedback 类型必须包含 Why 和 How to apply
5. project 类型中相对日期转为绝对日期
6. 保存步骤: 写文件 → 更新 MEMORY.md 索引
```

#### 互斥机制

主 Agent 和提取 Agent 不能同时写记忆目录：

```
┌─ 互斥检查 ───────────────────────────────────────────┐
│                                                       │
│  hasMemoryWritesSince(messages, lastCursorUuid):      │
│    扫描 cursor 之后的 assistant 消息                    │
│    如果发现 tool_use: Write/Edit                       │
│    且目标路径在 memory/ 下                              │
│    → return true                                      │
│    → 本轮跳过提取，推进 cursor                          │
│                                                       │
│  为什么: 主 Agent 可能正在按用户要求精确地调整记忆，     │
│  提取 Agent 不应该干扰                                  │
└───────────────────────────────────────────────────────┘
```

### 路径 C：autoDream 后台整合

详见[第 7 节](#7-记忆整合引擎-autodream)。

---

## 5. 记忆的读取：Sonnet 智能检索

### 读取流程

```
会话启动，用户输入 "帮我修复登录 bug"
     │
     ▼
┌─ startRelevantMemoryPrefetch() ──── 异步预取，不阻塞 ────────┐
│                                                               │
│  ① scanMemoryFiles(memoryDir)                                │
│     ├─ readdir 递归扫描 memory/*.md                           │
│     ├─ 排除 MEMORY.md (索引，已单独加载)                       │
│     ├─ 对每个文件: 只读前 30 行 (frontmatter)                  │
│     ├─ 解析 YAML: name, description, type                     │
│     ├─ 按 mtime 倒序排列 (最新优先)                           │
│     └─ 截取前 200 个                                          │
│                                                               │
│     结果:                                                     │
│     [                                                         │
│       { filename: "project_login_bug.md",                     │
│         description: "Login.tsx 异步 bug 已修复",              │
│         type: "project", mtimeMs: 1712300000000 },            │
│       { filename: "user_role.md",                             │
│         description: "用户是资深后端工程师",                    │
│         type: "user", mtimeMs: 1712200000000 },               │
│       ... 最多 200 个                                         │
│     ]                                                         │
│                                                               │
│  ② 过滤已浮现的记忆 (alreadySurfaced)                         │
│     避免同一会话重复注入同一记忆                                │
│                                                               │
│  ③ selectRelevantMemories(query, memories, signal)            │
│     ├─ 模型: Sonnet (默认)                                    │
│     ├─ 输入: 用户问题 + 记忆列表 (只有 frontmatter)            │
│     ├─ 指令: "选出最多 5 个对回答这个问题明确有用的记忆。       │
│     │         不确定的不要选。宁缺毋滥。"                       │
│     ├─ max_tokens: 256                                        │
│     ├─ 输出: JSON { selected_memories: ["file1.md", ...] }    │
│     └─ 验证: 过滤不在合法集合中的文件名                        │
│                                                               │
│  ④ 返回选中的记忆 (含文件路径和 mtime)                        │
└───────────────────────────────────────────────────────────────┘
     │
     ▼ (API 流式调用期间后台完成)
     │
     ▼ (工具执行后消费预取结果)
┌─ 注入为消息附件 ──────────────────────────────────────────────┐
│                                                               │
│  对每个选中的记忆:                                             │
│  ├─ Read 完整文件内容                                         │
│  ├─ 附加 memoryFreshnessNote (如果 > 1 天则加老化警告)         │
│  └─ 创建 AttachmentMessage 注入到消息流                        │
│                                                               │
│  LLM 在下一轮看到:                                             │
│  [附件: project_login_bug.md]                                  │
│  [附件: user_role.md]                                          │
│  [附件: feedback_testing.md]                                   │
│  ... 最多 5 个                                                │
└───────────────────────────────────────────────────────────────┘
```

### 为什么用 Sonnet 而不是全量加载？

```
方案 A: 加载全部记忆
  ├─ 200 个记忆文件，每个 ~500 字
  ├─ 约 100K tokens
  ├─ 占上下文窗口的 50%
  ├─ 成本高，99% 的记忆和当前任务无关
  └─ ✗ 不可行

方案 B: 关键词匹配
  ├─ 简单快速，零 API 成本
  ├─ 但无法理解语义
  ├─ "帮我修登录 bug" 匹配不到 "Login.tsx 的 async 问题"
  └─ ✗ 效果差

方案 C: Sonnet 智能检索 ← Claude Code 的选择
  ├─ 只读 frontmatter (name + description)
  ├─ 200 个文件的 frontmatter ≈ 2K tokens
  ├─ 1 次 Sonnet 调用 ≈ $0.001
  ├─ Sonnet 理解语义: "登录 bug" → 选中 "Login.tsx 异步问题"
  ├─ 选出 Top-5 最相关的，注入 ≈ 2.5K tokens
  └─ ✓ 高性价比，高精度
```

### 例子：Sonnet 选择过程

```
用户输入: "帮我把 API v2 的 /users 接口迁移到 v3"

Sonnet 看到的记忆列表 (只有 frontmatter):
┌────────────────────────────────────────────────────────────────┐
│ 1. [user] user_role.md: 用户是资深后端工程师，新接触 React      │
│ 2. [feedback] feedback_testing.md: 测试必须用真实 DB           │
│ 3. [project] project_stack.md: React + Prisma + PostgreSQL    │
│ 4. [project] project_migration.md: API v2→v3 迁移中，截止5月  │ ← 高度相关!
│ 5. [project] project_deploy.md: staging→production 部署流程    │
│ 6. [reference] reference_ci.md: CI 在 GitHub Actions          │
│ 7. [feedback] feedback_pr_style.md: 重构用单个大 PR           │
│ 8. [project] project_login_bug.md: Login.tsx 异步 bug 已修复  │
│ 9. [reference] reference_api_docs.md: API 文档在 Notion       │ ← 相关!
│ 10. [user] user_schedule.md: 用户周五不在                      │
└────────────────────────────────────────────────────────────────┘

Sonnet 选择:
{
  "selected_memories": [
    "project_migration.md",     ← 直接相关: v2→v3 迁移的上下文
    "project_stack.md",         ← 相关: 需要知道技术栈
    "reference_api_docs.md",    ← 相关: API 文档位置
    "feedback_testing.md",      ← 相关: 迁移后需要测试
    "user_role.md"              ← 有用: 知道用户是后端出身
  ]
}

未选:
  project_deploy.md → 和 API 迁移无关
  project_login_bug.md → 和当前任务无关
  user_schedule.md → 和当前任务无关
```

---

## 6. 记忆提取 Agent (extractMemories)

### 完整的提取流程

```
用户和 Claude 对话了 5 轮, 最后一轮:

  用户: "对了，这个项目的 staging 环境 URL 是 https://staging.myapp.com"
  Claude: "好的，我记下了。" (自然结束，没有工具调用)

     │ StopHooks 触发
     ▼

┌─ extractMemories 执行 ──────────────────────────────────────────┐
│                                                                  │
│  检查门控:                                                        │
│  ├─ feature flag: ON ✓                                           │
│  ├─ autoMemory: enabled ✓                                        │
│  ├─ 非远程模式 ✓                                                  │
│  ├─ 主 Agent ✓                                                    │
│  ├─ 节流: turnsSinceLastExtraction=3 >= threshold=1 ✓            │
│  └─ 互斥: 主 Agent 本轮没写记忆 ✓                                 │
│                                                                  │
│  准备:                                                            │
│  ├─ 扫描现有记忆 → 生成 manifest                                  │
│  ├─ 新消息范围: Turn 3-5 (Turn 1-2 上次已提取)                    │
│  └─ 构建提取提示词                                                │
│                                                                  │
│  Fork Agent 执行 (最多 5 轮):                                     │
│                                                                  │
│  Turn 1 (Agent):                                                 │
│    "分析新对话，我发现:                                            │
│     - 用户提到了 staging URL，这是一个 reference 类型信息           │
│     - 检查现有记忆... 没有 staging URL 的记忆                      │
│     - 创建新记忆文件"                                              │
│    tool_use: Write("memory/reference_staging.md", content="""    │
│      ---                                                         │
│      name: Staging 环境                                           │
│      description: staging 环境 URL — https://staging.myapp.com   │
│      type: reference                                              │
│      ---                                                         │
│                                                                  │
│      Staging 环境 URL: https://staging.myapp.com                 │
│    """)                                                          │
│                                                                  │
│  Turn 2 (Agent):                                                 │
│    tool_use: Edit("memory/MEMORY.md",                            │
│      在 References 下添加:                                        │
│      "- [reference_staging.md] - staging 环境 URL")              │
│                                                                  │
│  结果: 写入 1 个新记忆文件                                        │
│  UI 显示: "Saved 1 memory"                                       │
└──────────────────────────────────────────────────────────────────┘
```

### 节流与合并

```
┌─ 节流机制 ─────────────────────────────────────────────────────┐
│                                                                 │
│  turnsSinceLastExtraction 计数器:                                │
│  ├─ Turn 1: count=1, threshold=1 → 提取 ✓, count 重置          │
│  ├─ Turn 2: count=1 → 提取 ✓                                   │
│  ├─ Turn 3: count=1 → 提取 ✓                                   │
│  ...                                                            │
│                                                                 │
│  如果 threshold=3 (通过 feature flag 配置):                      │
│  ├─ Turn 1: count=1 < 3 → 跳过                                 │
│  ├─ Turn 2: count=2 < 3 → 跳过                                 │
│  ├─ Turn 3: count=3 >= 3 → 提取 ✓, count 重置                  │
│  ├─ Turn 4: count=1 → 跳过                                     │
│  ...                                                            │
│                                                                 │
│  合并机制 (防止重叠):                                            │
│  ├─ 提取 A 正在执行中                                           │
│  ├─ Turn N 结束，触发新的提取请求                                 │
│  ├─ → 不启动新的，而是 stash context                             │
│  ├─ 提取 A 完成后                                                │
│  └─ → 用 stash 的 context 做一次 "trailing extraction"          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 7. 记忆整合引擎 (autoDream)

### 三重门控

```
每轮 query 循环结束 → StopHooks → executeAutoDream()
     │
     ▼
┌─ Gate 1: 时间门控 (成本: 1 次 fs.stat) ──────────────────────┐
│  读取 .consolidate-lock 的 mtime                              │
│  hoursSince = (now - mtime) / 3600000                         │
│  hoursSince < 24? → 跳过 (太早了)                              │
└────────────┬──────────────────────────────────────────────────┘
             │ ≥ 24 小时
             ▼
┌─ Gate 2: 会话门控 (成本: N 次 fs.stat) ──────────────────────┐
│  扫描 transcripts/ 目录                                       │
│  找出 mtime > lastConsolidatedAt 的会话                       │
│  排除当前会话                                                  │
│  count < 5? → 跳过 (积累不够)                                  │
│                                                               │
│  扫描节流: 10 分钟内不重复扫描                                  │
│  (时间门控过了但会话不够 → 下次也不用马上再扫)                   │
└────────────┬──────────────────────────────────────────────────┘
             │ ≥ 5 个会话
             ▼
┌─ Gate 3: 锁门控 (成本: 文件读写) ────────────────────────────┐
│  读取 .consolidate-lock 内容 (PID)                            │
│  ├─ 锁不存在 → 获取锁                                        │
│  ├─ 锁存在, PID 还活着, < 60 分钟 → 放弃 (别人在做)           │
│  ├─ 锁存在, PID 死了 → 回收锁                                 │
│  └─ 锁存在, > 60 分钟 → 强制回收 (防死锁)                     │
│                                                               │
│  获取锁: 写入自己的 PID → 重读验证 → PID 匹配则成功            │
│  (两个进程同时写 → 最后一个赢 → 另一个验证失败放弃)            │
└────────────┬──────────────────────────────────────────────────┘
             │ 锁获取成功
             ▼
┌─ 执行整合 ────────────────────────────────────────────────────┐
│                                                                │
│  runForkedAgent({                                              │
│    prompt: buildConsolidationPrompt(...),                      │
│    canUseTool: 受限 (只读 Bash + 记忆目录 Edit/Write),         │
│    querySource: 'auto_dream',                                  │
│  })                                                            │
│                                                                │
│  整合 Agent 四阶段协议:                                         │
│                                                                │
│  Phase 1 — Orient (定位):                                      │
│    ls memory/, read MEMORY.md, skim topic files                │
│    "了解当前记忆的全貌"                                         │
│                                                                │
│  Phase 2 — Gather (收集):                                      │
│    读取日志 logs/YYYY/MM/*.md                                  │
│    grep 会话记录寻找线索 (窄范围搜索)                           │
│    识别: 过时信息、矛盾事实、可合并的重复                        │
│                                                                │
│  Phase 3 — Consolidate (整合):                                 │
│    更新/合并 topic 文件                                         │
│    相对日期 → 绝对日期                                          │
│    删除被代码变更推翻的事实                                      │
│    合并重复记忆                                                 │
│                                                                │
│  Phase 4 — Prune & Index (修剪):                               │
│    MEMORY.md ≤ 200 行, ≤ 25KB                                  │
│    缩短冗长描述                                                 │
│    删除指向已删文件的条目                                        │
│    解决矛盾条目                                                 │
│                                                                │
│  完成 → 更新 .consolidate-lock mtime                           │
│  失败 → rollback lock mtime (回到之前的值)                     │
│  用户手动 kill → abort + rollback                              │
└────────────────────────────────────────────────────────────────┘
```

### 例子：Dream 整合前后

```
整合前 (6 个记忆文件):
┌────────────────────────────────────────────────────────────────┐
│ project_stack.md (3天前):                                      │
│   "项目用 React 17"  ← 过时! 昨天已升级到 React 18             │
│                                                                │
│ project_stack_v2.md (1天前):                                   │
│   "项目已升级到 React 18"  ← 和上面重复/矛盾                   │
│                                                                │
│ project_todo_1.md (5天前):                                     │
│   "需要修复 Login bug"  ← 已完成，过时                          │
│                                                                │
│ project_todo_2.md (2天前):                                     │
│   "Login bug 已修复"  ← 和 todo_1 重复/矛盾                    │
│                                                                │
│ feedback_testing.md (10天前):                                  │
│   "测试必须用真实 DB"  ← 仍然有效                               │
│                                                                │
│ user_role.md (15天前):                                         │
│   "用户是资深后端工程师"  ← 仍然有效                            │
└────────────────────────────────────────────────────────────────┘

Dream Agent 执行后 (3 个记忆文件):
┌────────────────────────────────────────────────────────────────┐
│ project_stack.md (更新):                                       │
│   "项目用 React 18 + Prisma + PostgreSQL                      │
│    (2026-04-03 从 React 17 升级)"                              │
│   ← 合并了两个文件，保留准确信息                                 │
│                                                                │
│ feedback_testing.md (不变):                                    │
│   "测试必须用真实 DB"                                           │
│                                                                │
│ user_role.md (不变):                                           │
│   "用户是资深后端工程师"                                        │
│                                                                │
│ 已删除:                                                        │
│   project_stack_v2.md ← 已合并入 project_stack.md              │
│   project_todo_1.md ← 已完成的任务，无需保留                    │
│   project_todo_2.md ← 已完成的任务，无需保留                    │
│                                                                │
│ MEMORY.md 更新:                                                │
│   删除了指向已删文件的条目                                      │
│   更新了 project_stack.md 的描述                                │
└────────────────────────────────────────────────────────────────┘
```

---

## 8. 记忆老化与漂移检测

记忆可能随时间变得不准确——代码已经改了，但记忆还记录着旧信息。

### 老化标记

```typescript
// memoryAge.ts

memoryAgeDays(mtimeMs)    → 0 (今天), 1 (昨天), N (N天前)
memoryAge(mtimeMs)        → "today", "yesterday", "5 days ago"
memoryFreshnessNote(mtime) → 超过 1 天的记忆附加警告:

  "<system-reminder>
   This memory is 5 days old. Information may have changed
   since it was written. If acting on this memory, verify
   against current code/state first.
   </system-reminder>"
```

### 漂移防护

系统提示词中注入的漂移警告：

```
记忆记录的是写入时刻的真相，可能已经过时。

在向用户推荐基于记忆的信息前:
- 如果记忆提到一个文件路径: 检查文件是否存在
- 如果记忆提到一个函数或 flag: grep 确认它还在
- 如果用户即将基于你的推荐采取行动: 先验证

"记忆说 X 存在" ≠ "X 现在存在"
```

### 例子

```
记忆: "数据库连接配置在 src/config/database.ts"
  ↓ 但 2 天前项目重构，移到了 src/lib/db.ts
  ↓ 记忆标记: "2 days ago"

LLM 的行为:
  ① 读到记忆: database.ts 有连接配置
  ② 看到老化警告: 2 天前的记忆，需要验证
  ③ 执行: Glob("src/**/database.ts") → 不存在!
  ④ 执行: Grep("database.*connection", type="ts") → 发现 src/lib/db.ts
  ⑤ 更新记忆 (或标记为需要更新)
  ⑥ 给用户正确的信息
```

---

## 9. 团队记忆同步

### 架构

```
┌─ 团队记忆 ─────────────────────────────────────────────────────┐
│                                                                 │
│  位置: memory/team/                                             │
│  开关: feature flag tengu_herring_clock                         │
│                                                                 │
│  vs 私有记忆:                                                    │
│  ├─ 私有记忆: memory/*.md (只有自己能看到)                       │
│  └─ 团队记忆: memory/team/*.md (团队成员共享)                    │
│                                                                 │
│  适合团队记忆的:                                                 │
│  ├─ reference 类型 (外部系统指针，所有人都需要)                   │
│  ├─ project 类型 (项目决策/截止日期，团队共享上下文)              │
│  └─ feedback 类型 (团队约定，如"测试必须用真实DB")               │
│                                                                 │
│  始终私有的:                                                     │
│  └─ user 类型 (个人角色/偏好，不应该暴露给团队)                  │
└─────────────────────────────────────────────────────────────────┘
```

### 写入安全

```
团队记忆写入前的安全检查:

  Write("memory/team/reference_api.md", content="...")
       │
       ▼
  ┌─ validateTeamMemWritePath() ─────────────────────────┐
  │  ① 路径规范化 (NFC Unicode)                           │
  │  ② 字符串级别检查: 是否在 team/ 目录下?               │
  │  ③ realpath 检查: 解析 symlink 后还在 team/ 下?      │
  │  ④ 防止 symlink 逃逸攻击                              │
  └────────────────────────────┬─────────────────────────┘
                               │ 路径合法
                               ▼
  ┌─ checkTeamMemSecrets() ──────────────────────────────┐
  │  扫描内容是否包含密钥/凭证:                            │
  │  ├─ AWS Access Key                                    │
  │  ├─ GitHub PAT                                        │
  │  ├─ OpenAI API Key                                    │
  │  ├─ Anthropic API Key                                 │
  │  ├─ Stripe Secret Key                                 │
  │  ├─ Private Key (RSA/EC/etc)                          │
  │  └─ ... 30+ gitleaks 规则                             │
  │                                                       │
  │  发现密钥 → 阻止写入 + 返回错误消息                    │
  │  "Blocked: content contains GitHub PAT"               │
  └────────────────────────────┬─────────────────────────┘
                               │ 无密钥
                               ▼
                          写入文件 ✓
```

---

## 10. 安全防护体系

### 路径安全

```
┌─ 路径验证层 (validateMemoryPath) ────────────────────────────┐
│                                                               │
│  拒绝的路径模式:                                               │
│  ├─ ../foo/bar          ← 相对路径 (可能遍历出目录)            │
│  ├─ /                   ← 根目录                              │
│  ├─ /a                  ← 近根目录 (长度 < 3)                  │
│  ├─ C:\                 ← Windows 驱动器根                     │
│  ├─ \\server\share      ← UNC 路径                            │
│  ├─ path\0with\0nulls   ← 空字节注入                          │
│  └─ ．．／foo            ← Unicode 全角字符 (NFKC 归一化攻击)  │
│                                                               │
│  Symlink 防护 (团队记忆):                                      │
│  ├─ 两阶段验证:                                                │
│  │   阶段 1: 字符串级 path.resolve + startsWith               │
│  │   阶段 2: realpath 解析 + 真实路径包含检查                   │
│  ├─ 悬空 symlink 检测: lstat 区分 "不存在" vs "symlink 目标丢失"│
│  └─ 循环 symlink 检测: ELOOP 错误处理                          │
└───────────────────────────────────────────────────────────────┘
```

### 工具权限隔离

```
┌─────────────────┬─────────────────┬─────────────────────────────┐
│     工具         │   主 Agent       │   提取/整合 Agent            │
├─────────────────┼─────────────────┼─────────────────────────────┤
│  Read           │  无限制          │  无限制                      │
│  Grep           │  无限制          │  无限制                      │
│  Glob           │  无限制          │  无限制                      │
│  Bash           │  无限制          │  只读 (ls,find,grep,cat,...) │
│  Edit           │  无限制          │  只能写 memory/ 目录         │
│  Write          │  无限制          │  只能写 memory/ 目录         │
│  Agent          │  可用            │  禁止                        │
│  MCP tools      │  可用            │  禁止                        │
│  其他           │  可用            │  禁止                        │
└─────────────────┴─────────────────┴─────────────────────────────┘
```

### MEMORY.md 双重截断

```
MEMORY.md 可能被 LLM 写得很长。双重安全网:

  raw content
       │
       ▼
  ┌─ 截断 1: 行数限制 ──────────────────┐
  │  if lines > 200:                     │
  │    content = first 200 lines         │
  │    append "... truncated (200 line   │
  │           limit reached)"            │
  └──────────────┬───────────────────────┘
                 │
                 ▼
  ┌─ 截断 2: 字节限制 ──────────────────┐
  │  if bytes > 25000:                   │
  │    找到 25000 字节前的最后一个换行    │
  │    content = 到那个换行为止           │
  │    append "... truncated (25KB       │
  │           limit reached)"            │
  └──────────────┬───────────────────────┘
                 │
                 ▼
  安全的 MEMORY.md 内容 → 注入系统提示词

  为什么需要双重?
  200 行 × 每行 1KB = 200KB → 远超 25KB!
  所以行数限制不够, 还需要字节限制兜底
```

---

## 11. 性能优化设计

```
┌─ 优化措施 ─────────────────────────────┬─────────────────────────┐
│  措施                                   │  效果                    │
├─────────────────────────────────────────┼─────────────────────────┤
│  getAutoMemPath() 路径缓存              │  每会话只计算 1 次       │
│  (以 project root 为 key 的 memoize)    │                         │
├─────────────────────────────────────────┼─────────────────────────┤
│  scanMemoryFiles 单遍扫描               │  readdir + stat 一起做   │
│  (读取-排序, 而非 stat-排序-读取)       │  syscall 减半            │
├─────────────────────────────────────────┼─────────────────────────┤
│  Frontmatter 只读 30 行                 │  200 个文件只读头部      │
│  (FRONTMATTER_MAX_LINES = 30)          │  不读完整内容            │
├─────────────────────────────────────────┼─────────────────────────┤
│  Sonnet 检索只用 frontmatter            │  200 个记忆 ≈ 2K tokens  │
│  (不读文件全文, 只看 description)       │  而非全量 100K           │
├─────────────────────────────────────────┼─────────────────────────┤
│  记忆预取异步化                          │  API 流式调用时后台执行  │
│  (startRelevantMemoryPrefetch)          │  不阻塞模型响应          │
├─────────────────────────────────────────┼─────────────────────────┤
│  提取 Agent 共享 Prompt Cache            │  fork 继承父对话前缀     │
│  (CacheSafeParams 复用)                 │  N 次提取只付 1 份缓存   │
├─────────────────────────────────────────┼─────────────────────────┤
│  密钥扫描正则懒编译                      │  第一次扫描时才编译      │
│  (compile once on first use)            │  不影响启动时间          │
├─────────────────────────────────────────┼─────────────────────────┤
│  Dream 门控成本递增                      │  时间门控: 1 次 stat     │
│  (time→session→lock)                    │  会话门控: N 次 stat     │
│                                         │  锁门控: 文件读写        │
│                                         │  99% 的检查在第一步返回  │
├─────────────────────────────────────────┼─────────────────────────┤
│  Dream 扫描节流                          │  10 分钟内不重复扫描     │
│  (SESSION_SCAN_INTERVAL_MS = 600000)    │  时间门控过但会话不够时  │
│                                         │  避免每轮都 readdir      │
├─────────────────────────────────────────┼─────────────────────────┤
│  alreadySurfaced 去重                   │  同一会话中已注入的记忆   │
│                                         │  不会在后续轮次重复注入   │
├─────────────────────────────────────────┼─────────────────────────┤
│  telemetry 异步 fire-and-forget         │  文件计数统计不阻塞主流程 │
└─────────────────────────────────────────┴─────────────────────────┘
```

---

## 12. 完整数据流：一个例子

### 场景：新项目第一天到第一周

```
═══ Day 1, Session 1: 用户首次使用 ═══

  用户: "帮我搭建项目结构"

  记忆状态: 空 (memory/ 目录不存在)
  ├─ Sonnet 检索: 无记忆可选
  ├─ 附件注入: 无
  └─ LLM 从零开始探索项目

  ...5 轮对话后...

  StopHooks → extractMemories:
    提取 Agent 分析对话，发现:
    ├─ 用户是全栈开发者 → 写 user_role.md
    ├─ 项目用 Next.js + Prisma → 写 project_stack.md
    └─ 更新 MEMORY.md 索引

  记忆状态: 2 个文件

═══ Day 1, Session 2: 用户继续开发 ═══

  用户: "帮我加个用户注册功能"

  记忆状态: 2 个文件
  ├─ Sonnet 检索: 选中 project_stack.md (相关: 需要知道技术栈)
  ├─ 附件注入: project_stack.md 的内容
  └─ LLM 已经知道技术栈是 Next.js + Prisma，不用重新探索!

  ...对话中...
  用户: "别用 class components，我们只用 hooks"

  StopHooks → extractMemories:
    提取 Agent 发现:
    └─ 用户偏好 hooks → 写 feedback_hooks.md

  记忆状态: 3 个文件

═══ Day 2, Session 3-7: 日常开发 ═══

  每次会话:
  ├─ Sonnet 精选 Top-5 相关记忆
  ├─ LLM 越来越"懂"项目
  └─ extractMemories 持续积累新知识

  记忆状态: ~10 个文件

═══ Day 3: autoDream 触发 ═══

  Session 8 结束时:
  ├─ 时间门控: 48h > 24h ✓
  ├─ 会话门控: 7 个会话 > 5 ✓
  ├─ 锁门控: 无竞争 ✓
  └─ Dream Agent 执行:
      ├─ 发现 project_stack.md 里 React 版本过时 → 更新
      ├─ 发现两个关于 API 的记忆可以合并 → 合并
      ├─ 发现一个已完成的 TODO → 删除
      └─ MEMORY.md 瘦身: 12 行 → 8 行

  记忆状态: 8 个文件 (整合后，更精炼)

═══ Day 7: 用户写了 CLAUDE.md ═══

  用户意识到有些规则很重要，手动写了 CLAUDE.md:
  ├─ 技术栈 (从记忆里搬过来，更稳定)
  ├─ 目录结构
  ├─ 测试命令
  └─ 编码约定

  此后:
  ├─ CLAUDE.md 提供稳定的"入职手册"
  ├─ 记忆系统提供动态的"工作日志"
  └─ 两者互补，LLM 从第一句话就像一个"了解项目的同事"
```

---

## 13. 关键常量与阈值

| 常量 | 值 | 用途 |
|------|---|------|
| `MAX_ENTRYPOINT_LINES` | 200 | MEMORY.md 最大行数 |
| `MAX_ENTRYPOINT_BYTES` | 25,000 | MEMORY.md 最大字节数 |
| `MAX_MEMORY_FILES` | 200 | 扫描的最大记忆文件数 |
| `FRONTMATTER_MAX_LINES` | 30 | 读取 frontmatter 的最大行数 |
| Top-K 检索 | 5 | Sonnet 每次选出的记忆数 |
| Sonnet max_tokens | 256 | 检索调用的输出上限 |
| extractMemories maxTurns | 5 | 提取 Agent 最大工具调用轮次 |
| Dream minHours | 24 | 整合最小间隔（小时） |
| Dream minSessions | 5 | 整合最小会话数 |
| SESSION_SCAN_INTERVAL_MS | 600,000 | Dream 扫描节流（10 分钟） |
| HOLDER_STALE_MS | 3,600,000 | 锁过期时间（60 分钟） |
| Secret Scanner Rules | 30+ | gitleaks 密钥检测规则数 |

---

## 14. 源码文件索引

### 核心记忆模块

| 文件 | 职责 |
|------|------|
| `src/memdir/memdir.ts` | 记忆目录核心: 加载、构建提示词、截断 |
| `src/memdir/paths.ts` | 路径解析、验证、安全检查 |
| `src/memdir/memoryTypes.ts` | 四种类型定义、提示词模板 |
| `src/memdir/memoryScan.ts` | 文件扫描、frontmatter 解析、manifest 构建 |
| `src/memdir/memoryAge.ts` | 老化检测、新鲜度文本 |
| `src/memdir/findRelevantMemories.ts` | Sonnet 智能检索 |
| `src/memdir/teamMemPaths.ts` | 团队记忆路径安全 |
| `src/memdir/teamMemPrompts.ts` | 团队记忆提示词 |

### 记忆写入

| 文件 | 职责 |
|------|------|
| `src/services/extractMemories/extractMemories.ts` | 自动提取 Agent 核心 |
| `src/services/extractMemories/prompts.ts` | 提取提示词构建 |
| `src/services/autoDream/autoDream.ts` | 整合引擎核心 |
| `src/services/autoDream/consolidationPrompt.ts` | 四阶段整合提示词 |
| `src/services/autoDream/consolidationLock.ts` | 进程锁机制 |
| `src/services/autoDream/config.ts` | Dream 配置 |

### 安全

| 文件 | 职责 |
|------|------|
| `src/services/teamMemorySync/secretScanner.ts` | 30+ 密钥检测规则 |
| `src/services/teamMemorySync/teamMemSecretGuard.ts` | 写入前密钥扫描 |
| `src/utils/memoryFileDetection.ts` | 文件分类 (记忆/会话/用户管理) |

### 集成点

| 文件 | 职责 |
|------|------|
| `src/query/stopHooks.ts` | extractMemories + autoDream 的触发点 |
| `src/utils/attachments.ts` | 记忆预取和注入 |
| `src/constants/prompts.ts` | 系统提示词中记忆部分的组装 |
| `src/context.ts` | MEMORY.md 内容加载到 userContext |
