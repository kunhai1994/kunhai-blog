# Claude Code 如何对项目建立认知 — 深度分析报告

## 核心结论

Claude Code 的 LLM **不会在启动时读完整个项目**。它的认知是**分层注入 + 按需探索**的：

```
启动时注入的"底色认知"（~10-20KB）
     │
     ├─ 系统提示词（行为规范 + 工具说明）
     ├─ 环境信息（OS/Shell/CWD/Git 状态）
     ├─ CLAUDE.md 项目指令（用户写的规则）
     ├─ 记忆系统（历史积累的项目知识）
     └─ 当前日期 + 元数据
     │
     ▼
用户第一句话
     │
     ▼
按需探索（模型主动调用工具）
     ├─ Glob: 搜索文件结构
     ├─ Read: 读取具体文件
     ├─ Grep: 搜索代码内容
     ├─ Bash: ls, git log, ...
     └─ Agent: 派子 agent 深入研究
```

**不是"先读完项目再回答"，而是"带着背景知识，边做边学"。**

---

## 一、启动时 LLM 收到的完整信息（按顺序）

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Claude API 请求结构                               │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  system: [系统提示词]                                          │  │
│  │                                                               │  │
│  │  ┌─ 静态部分 (全局可缓存) ─────────────────────────────────┐  │  │
│  │  │  ① 行为规范（~4KB）                                      │  │  │
│  │  │     "你是 Claude Code, Anthropic 的官方 CLI..."          │  │  │
│  │  │     编码风格、工具使用规则、安全规范、输出格式...           │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  │  ─── SYSTEM_PROMPT_DYNAMIC_BOUNDARY ───  (缓存分界线)        │  │
│  │  ┌─ 动态部分 (每会话不同) ─────────────────────────────────┐  │  │
│  │  │  ② 记忆系统指令（~1-2KB）                                │  │  │
│  │  │  ③ 环境信息（~1KB）                                      │  │  │
│  │  │  ④ MCP 服务器指令                                        │  │  │
│  │  │  ⑤ Token Budget 指引                                     │  │  │
│  │  │  ⑥ 其他动态配置                                          │  │  │
│  │  └────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │  messages: [消息数组]                                          │  │
│  │                                                               │  │
│  │  ┌─ User Context (前置注入) ────────────────────────────────┐ │  │
│  │  │  ⑦ CLAUDE.md 项目指令（~2-5KB）                          │ │  │
│  │  │  ⑧ 当前日期                                              │ │  │
│  │  └──────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─ System Context (追加注入) ──────────────────────────────┐ │  │
│  │  │  ⑨ Git 状态快照（分支/未提交文件/最近commit）              │ │  │
│  │  └──────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─ 用户消息 ──────────────────────────────────────────────┐  │  │
│  │  │  ⑩ 用户实际输入的内容                                    │  │  │
│  │  └──────────────────────────────────────────────────────────┘ │  │
│  │                                                               │  │
│  │  ┌─ 附件消息 (第一轮额外注入) ─────────────────────────────┐  │  │
│  │  │  ⑪ 相关记忆文件 (Top-5 by Sonnet)                       │  │  │
│  │  │  ⑫ 当前 Plan（如果有）                                   │  │  │
│  │  │  ⑬ 任务列表（如果有）                                    │  │  │
│  │  │  ⑭ IDE 选中的代码（如果有）                               │  │  │
│  │  │  ⑮ 相关 Skill 建议                                      │  │  │
│  │  └──────────────────────────────────────────────────────────┘ │  │
│  └───────────────────────────────────────────────────────────────┘  │
│                                                                     │
│  tools: [43 个工具的 JSON Schema]                                    │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘

总计: ~10-20KB+ 上下文，在用户说第一句话之前就已经注入
```

---

## 二、逐层详解

### ① 系统提示词 — 行为规范（静态，~4KB）

这部分是写死的，每个会话都一样：

```
你是 Claude Code, Anthropic 的官方 CLI...

# System
- 所有输出文本显示给用户
- 工具在用户选择的权限模式下执行
- ...

# Doing tasks
- 用户主要请求软件工程任务
- 先读代码再提建议
- 不要过度工程化
- 不要引入安全漏洞
- ...

# Using your tools
- 读文件用 Read 不用 cat
- 编辑文件用 Edit 不用 sed
- 搜索文件用 Glob 不用 find
- ...

# Tone and style
- 不用 emoji（除非用户要求）
- 引用代码用 file_path:line_number 格式
- ...
```

**注意: 这里没有任何项目特定信息。** 这只是"做人的规矩"。

### ② 记忆系统指令（动态，~1-2KB）

如果项目启用了 auto memory，系统提示词会包含记忆系统的使用说明：

```
你有一个持久化的、基于文件的记忆系统，路径在
~/.claude/projects/<project-slug>/memory/

记忆类型:
- user: 用户角色、偏好、知识水平
- feedback: 用户对你工作方式的反馈
- project: 项目动态、目标、截止日期
- reference: 外部系统的指针

何时保存/何时读取/何时不保存 的详细规则...

MEMORY.md 索引内容:
(如果存在，会嵌入 MEMORY.md 的前 200 行)
```

### ③ 环境信息（动态，~1KB）

```typescript
// prompts.ts — computeSimpleEnvInfo()
```

LLM 收到的环境信息：

```
# Environment
- Primary working directory: /Users/goodnight/workspace/my-project
  - Is a git repository: true
- Platform: darwin
- Shell: bash
- OS Version: Darwin 25.2.0
- You are powered by claude-opus-4-6[1m]
- Assistant knowledge cutoff is May 2025
- The most recent Claude model family is Claude 4.5/4.6
  Model IDs: claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5
```

**注意: 只有 CWD 路径和 git 状态，没有目录树，没有文件列表。**

### ⑦ CLAUDE.md 项目指令（动态，~2-5KB）

这是用户手写的项目规则文件，**是 LLM 对项目的最重要"先验知识"来源**。

#### 加载优先级（从低到高）

```
优先级从低到高:

/etc/claude-code/CLAUDE.md          ← 组织级（IT 管理员设置）
~/.claude/CLAUDE.md                 ← 用户级（个人偏好）
../../CLAUDE.md                     ← 祖先目录
../CLAUDE.md                        ← 父目录
./CLAUDE.md                         ← 项目根目录     ← 最常用
./.claude/CLAUDE.md                 ← 项目 .claude 目录
./CLAUDE.local.md                   ← 本地覆盖（不提交 git）
./.claude/rules/*.md                ← 规则目录（递归）
```

#### 典型的 CLAUDE.md 内容

```markdown
# Project: MyApp

## Tech Stack
- React 18 + TypeScript
- Express backend
- PostgreSQL + Prisma ORM
- Jest for testing

## Architecture
- src/components/ — React 组件
- src/api/ — Express 路由
- src/services/ — 业务逻辑
- src/db/ — Prisma schema 和 migrations

## Conventions
- 使用 functional components + hooks
- API 路由用 RESTful 命名
- 测试文件放在 __tests__ 目录
- commit message 用 conventional commits 格式

## Important Notes
- 不要修改 src/db/schema.prisma 除非我明确要求
- 环境变量在 .env.example 中有模板
- 跑测试: npm test
- 开发服务器: npm run dev
```

**注入方式**: 作为 `userContext.claudeMd` 前置到消息中，带有强制头：

```
Codebase and user instructions are shown below.
Be sure to adhere to these instructions.
IMPORTANT: These instructions OVERRIDE any default behavior
and you MUST follow them exactly as written.

<instructions>
{CLAUDE.md 的全部内容}
</instructions>
```

### ⑨ Git 状态快照（动态，~0.5-1KB）

```
gitStatus: This is the git status at the start of the conversation.
Note that this status is a snapshot in time, and will not update
during the conversation.

Current branch: feature/login-page
Main branch: main
Git user: goodnight

Status:
 M src/Login.tsx
 M src/api/auth.ts
?? src/components/ForgotPassword.tsx

Recent commits:
a1b2c3d feat: add login form UI
d4e5f6g fix: password validation regex
g7h8i9j refactor: extract auth service
```

**注意: 只是 `git status --short` + `git log --oneline -5`，不是完整历史。**

### ⑪ 相关记忆文件（动态，变长）

如果项目有积累的记忆，启动时会用 **Sonnet 从所有记忆中精选 Top-5 最相关的**：

```
记忆检索流程:

~/.claude/projects/<slug>/memory/
├── MEMORY.md              ← 索引文件（总是加载）
├── user_role.md           ← "用户是高级前端工程师"
├── feedback_testing.md    ← "用户要求测试必须跑真实数据库"
├── project_stack.md       ← "项目用 React + Prisma"
├── project_migration.md   ← "正在从 v2 迁移到 v3"
├── reference_ci.md        ← "CI 在 GitHub Actions"
└── ...可能有几十个记忆文件

↓ Sonnet 只读 frontmatter（零全文开销）
↓ 根据用户当前输入 + 上下文排序
↓ 选出 Top-5 最相关的

注入到消息中:
[附件: user_role.md 内容]
[附件: project_stack.md 内容]
[附件: feedback_testing.md 内容]
...最多 5 个
```

---

## 三、LLM 启动时 **不知道** 什么

这同样重要——以下信息 LLM 在启动时**完全不知道**：

```
┌─ LLM 启动时不知道的事情 ──────────────────────────────────────┐
│                                                                │
│  ✗ 项目的完整目录结构                                           │
│  ✗ 项目有哪些文件（文件名列表）                                  │
│  ✗ 任何源代码的内容                                             │
│  ✗ package.json / Cargo.toml / go.mod 的内容                   │
│  ✗ README.md 的内容                                            │
│  ✗ 项目的依赖关系                                               │
│  ✗ 数据库 schema                                                │
│  ✗ API 接口定义                                                 │
│  ✗ 最近的 git diff 具体内容                                     │
│  ✗ CI/CD 配置                                                   │
│  ✗ 环境变量的值                                                  │
│                                                                │
│  除非这些信息写在了 CLAUDE.md 或 记忆文件 中！                    │
└────────────────────────────────────────────────────────────────┘
```

---

## 四、认知是如何渐进构建的

### 第一轮：用户说话，LLM 决定探索策略

```
用户: "帮我修复登录页面的 bug"

LLM 此时的认知:
┌────────────────────────────────────────────────────┐
│ 我知道:                                             │
│ ├─ 这是一个 git 项目, 在 /Users/.../my-project     │
│ ├─ 当前分支是 feature/login-page                   │
│ ├─ src/Login.tsx 有未提交修改 (from git status)     │
│ ├─ 技术栈是 React + TypeScript (from CLAUDE.md)    │
│ ├─ 用户是高级前端工程师 (from 记忆)                  │
│ └─ 项目结构大致是 src/components + src/api (CLAUDE.md) │
│                                                    │
│ 我不知道:                                           │
│ ├─ Login.tsx 的具体代码                              │
│ ├─ bug 的具体表现                                    │
│ └─ 相关的其他文件内容                                │
│                                                    │
│ 我的探索策略:                                        │
│ → 先 Read src/Login.tsx 看看代码                     │
│ → 可能还需要看 src/api/auth.ts                      │
└────────────────────────────────────────────────────┘

LLM 输出:
  [text] "我来看看登录页面的代码。"
  [tool_use] Read("src/Login.tsx")
  [tool_use] Read("src/api/auth.ts")
```

### 第二轮：工具结果回来，认知扩展

```
工具结果注入后, LLM 的认知:
┌────────────────────────────────────────────────────┐
│ 新增认知:                                           │
│ ├─ Login.tsx 是一个 200 行的 React 组件              │
│ ├─ 用了 useState + useEffect hooks                  │
│ ├─ handleSubmit 调用了 loginAPI()                   │
│ ├─ loginAPI 是异步的但没有 await                     │
│ ├─ auth.ts 暴露了 loginAPI(data) 函数               │
│ └─ 返回值是 Promise<AuthResult>                     │
│                                                    │
│ 诊断:                                               │
│ → handleSubmit 缺少 await → 表单提交后不等结果       │
│ → 这就是 "没反应" 的原因                             │
└────────────────────────────────────────────────────┘
```

### 如果项目更复杂——Agent 深度探索

```
用户: "帮我理解这个项目的整体架构"

LLM 的策略 (因为问题很开放):
  [tool_use] Agent(subagent_type="Explore", prompt="探索项目结构和架构")

Explore Agent 自动执行:
  ├─ Glob("**/*.ts", "**/*.tsx")        → 获取所有 TS 文件列表
  ├─ Read("package.json")              → 了解依赖
  ├─ Read("tsconfig.json")             → 了解编译配置
  ├─ Glob("src/**/*", 只看目录结构)     → 了解模块划分
  ├─ Read("src/index.ts")              → 了解入口
  ├─ Grep("export.*class|export.*function", type="ts")  → 主要导出
  └─ Read("README.md")                 → 项目文档

Agent 返回摘要 → 主 LLM 基于此回答用户
```

---

## 五、CLAUDE.md + 记忆 = "项目说明书"

这两者的配合是 LLM 对项目认知的核心：

```
┌─ CLAUDE.md (用户手写, 版本控制) ──────────────────────────────┐
│                                                                │
│  本质: 项目的"入职手册"                                        │
│  谁写: 开发者手动编写                                          │
│  何时读: 每次会话启动时自动注入                                  │
│  内容: 技术栈、架构、约定、禁忌、常用命令                       │
│  特点: 稳定不变，像文档一样维护                                  │
│                                                                │
│  它告诉 LLM:                                                   │
│  "这个项目是什么，怎么组织的，有什么规矩"                       │
└────────────────────────────────────────────────────────────────┘
                              +
┌─ 记忆系统 (LLM 自动积累, 文件持久化) ────────────────────────┐
│                                                                │
│  本质: 项目的"工作日志"                                        │
│  谁写: Claude 在每轮对话结束后自动提取 (extractMemories)        │
│  何时读: 每次会话启动时 Sonnet 精选 Top-5 注入                  │
│  内容: 用户偏好、历史决策、踩过的坑、正在进行的工作             │
│  特点: 随时间积累，越用越懂你                                   │
│                                                                │
│  它告诉 LLM:                                                   │
│  "这个用户是谁，他喜欢怎么做，项目最近在搞什么"                  │
└────────────────────────────────────────────────────────────────┘
                              =
┌─ LLM 的"先验认知" ────────────────────────────────────────────┐
│                                                                │
│  不需要读任何代码，LLM 就已经知道:                               │
│  ├─ 项目用什么技术栈                                            │
│  ├─ 代码怎么组织的                                              │
│  ├─ 有什么约定和禁忌                                            │
│  ├─ 用户是什么角色、什么水平                                     │
│  ├─ 用户喜欢什么风格的交互                                      │
│  ├─ 项目最近在做什么                                            │
│  └─ 上次对话遗留了什么问题                                      │
│                                                                │
│  然后根据用户的具体问题，按需用工具探索细节                       │
└────────────────────────────────────────────────────────────────┘
```

---

## 六、对比：有/无 CLAUDE.md + 记忆的体验差异

### 场景：用户说 "跑一下测试"

#### 没有 CLAUDE.md，没有记忆（冷启动）

```
LLM 的认知: 几乎为零

LLM 的行为:
  ① Glob("package.json", "Makefile", "Cargo.toml", ...) → 猜语言
  ② Read("package.json") → 发现是 Node 项目
  ③ 看 scripts 字段 → 发现 "test": "jest"
  ④ Bash("npm test")

耗时: 3 轮工具调用 (~10 秒) 才开始跑测试
```

#### 有 CLAUDE.md（写了 "跑测试: npm test"）

```
LLM 的认知: 知道测试命令是 npm test

LLM 的行为:
  ① Bash("npm test")

耗时: 1 轮工具调用 (~3 秒) 直接跑
```

#### 有 CLAUDE.md + 记忆（记忆里有 "上次 Login 测试失败过"）

```
LLM 的认知: 知道测试命令 + 知道 Login 模块曾有问题

LLM 的行为:
  ① Bash("npm test")
  ② 如果失败，直接知道去看 src/Login.tsx
     (而不是从零开始排查)

耗时: 更快定位问题
```

---

## 七、完整信息注入时序图

```
时间 ──────────────────────────────────────────────────────────→

用户启动 claude, 输入 "帮我修个 bug"

  │ QueryEngine.submitMessage("帮我修个 bug")
  │
  ├─ 构建系统提示词
  │   ├─ 加载静态规范（~4KB, 全局缓存命中）
  │   ├─ 注入记忆系统指令（~1.5KB）
  │   ├─ 注入环境信息（~1KB）
  │   │   ├─ CWD: /Users/goodnight/my-project
  │   │   ├─ Platform: darwin, Shell: bash
  │   │   └─ Model: claude-opus-4-6
  │   └─ 注入 MCP 指令（如果有）
  │
  ├─ 构建 User Context
  │   ├─ 加载 CLAUDE.md 链
  │   │   ├─ ~/.claude/CLAUDE.md (用户级)
  │   │   ├─ ./CLAUDE.md (项目级)
  │   │   └─ ./.claude/rules/*.md (规则)
  │   └─ 注入当前日期
  │
  ├─ 构建 System Context
  │   └─ 获取 Git 状态快照
  │       ├─ git branch → feature/fix-login
  │       ├─ git status --short → M src/Login.tsx
  │       └─ git log --oneline -5 → 最近 5 条 commit
  │
  ├─ 记忆预取 (异步, 在 API 调用时后台执行)
  │   ├─ 读取 MEMORY.md 索引
  │   ├─ 读取所有记忆文件的 frontmatter
  │   ├─ Sonnet 排序 → 选 Top-5
  │   └─ 结果在工具执行后注入
  │
  ├─ 组装 API 请求:
  │   ├─ system = [系统提示词]
  │   ├─ messages[0] = [CLAUDE.md 指令 + 日期] (userContext)
  │   ├─ messages[1] = [Git 状态] (systemContext)
  │   └─ messages[2] = [用户输入: "帮我修个 bug"]
  │
  ├─ 调用 Claude API (流式)
  │   Claude 收到 ~15KB 上下文 + 用户问题
  │   思考后输出: "我来看看..." + Read(src/Login.tsx)
  │
  ├─ 工具执行完毕, 注入附件:
  │   ├─ [记忆预取结果: 3 个相关记忆文件]
  │   ├─ [Skill 建议: 无]
  │   └─ [文件变更通知: 无]
  │
  └─ 进入 Turn 2: 消息 = 上下文 + 用户问题 + Claude回复 + 工具结果 + 附件
     Claude 看到 Login.tsx 代码, 继续诊断...
```

---

## 八、设计哲学

### 为什么不在启动时读完整个项目？

```
方案 A: 启动时读完全部代码 (Claude Code 没有选这个)
  ├─ 一个中型项目 500 个文件, ~200万行代码
  ├─ 约 500万 tokens
  ├─ 远超 200K 上下文窗口
  ├─ 即使能塞进去, 99% 的代码和当前任务无关
  ├─ 成本: 500万 input tokens ≈ $15/次 (Opus)
  └─ 延迟: 几十秒才能开始回答

方案 B: 先注入"背景知识", 按需探索 (Claude Code 的选择)
  ├─ 启动上下文: ~15K tokens
  ├─ CLAUDE.md 提供高层架构认知
  ├─ 记忆提供历史经验
  ├─ Git status 提供当前状态
  ├─ 模型根据任务自主决定看哪些文件
  ├─ 成本: ~15K input tokens ≈ $0.05/次
  └─ 延迟: <1 秒即可开始交互
```

### 认知构建的三个层次

```
┌─────────────────────────────────────────────────────────┐
│  Level 1: 先验知识 (启动时注入, 不需要工具调用)           │
│                                                         │
│  来源: 系统提示词 + CLAUDE.md + 记忆 + Git 状态          │
│  内容: 项目是什么, 怎么组织, 用什么技术, 有什么规矩       │
│  类比: 新员工入职第一天读的 wiki 和 onboarding 文档       │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│  Level 2: 探索性认知 (第一轮工具调用获取)                 │
│                                                         │
│  来源: Read/Glob/Grep/Bash 工具调用                      │
│  内容: 具体文件内容, 目录结构, 依赖关系, 测试状态          │
│  类比: 新员工打开 IDE, 浏览项目代码                       │
└───────────────────────────┬─────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────┐
│  Level 3: 深度认知 (多轮交互逐步积累)                     │
│                                                         │
│  来源: 多轮工具调用 + 用户反馈 + Agent 深度研究            │
│  内容: 代码逻辑, bug 根因, 架构细节, 性能瓶颈             │
│  类比: 新员工工作几天后对模块的深入理解                     │
│                                                         │
│  这些认知会被 extractMemories 提取为记忆                   │
│  → 下次启动时变成 Level 1 的先验知识!                      │
│  → 形成认知的正向循环                                     │
└─────────────────────────────────────────────────────────┘
```

### 认知正向循环

```
第 1 次使用:
  先验知识 = 0 (没有 CLAUDE.md, 没有记忆)
  LLM 花很多轮探索项目
  → extractMemories 保存了"项目用 React + Prisma"
  → autoDream 整合了"用户是高级工程师, 喜欢简洁回答"

第 2 次使用:
  先验知识 = 记忆 (知道技术栈和用户偏好)
  LLM 探索效率提升

第 5 次使用:
  先验知识 = 丰富记忆 (知道架构/约定/历史bug/用户习惯)
  LLM 几乎像一个"了解项目的同事"

第 N 次使用:
  用户写了 CLAUDE.md (把最重要的信息固化)
  先验知识 = CLAUDE.md + 记忆
  LLM 从第一句话就"懂"你的项目
```

---

## 九、关键源码位置

| 功能 | 文件 | 核心函数 |
|------|------|---------|
| 系统提示词构建 | `src/constants/prompts.ts` | `getSystemPrompt()`, `computeSimpleEnvInfo()` |
| 环境信息 | `src/constants/prompts.ts` | `computeSimpleEnvInfo()` |
| CLAUDE.md 加载 | `src/context.ts` | `getUserContext()` |
| Git 状态 | `src/context.ts` | `getGitStatus()`, `getSystemContext()` |
| 记忆加载 | `src/memdir/memdir.ts` | `loadMemoryPrompt()`, `buildMemoryLines()` |
| 记忆检索 | `src/memdir/findRelevantMemories.ts` | `findRelevantMemories()` |
| 附件注入 | `src/utils/attachments.ts` | `getAttachmentMessages()`, `getAttachments()` |
| 记忆预取 | `src/utils/attachments.ts` | `startRelevantMemoryPrefetch()` |
| 用户输入处理 | `src/QueryEngine.ts` | `submitMessage()` |
| 上下文前置 | `src/utils/api.ts` | `prependUserContext()`, `appendSystemContext()` |
| SDK 初始化消息 | `src/utils/messages/systemInit.ts` | `buildSystemInitMessage()` |
| 记忆提取 | `src/services/extractMemories/` | `extractMemories()` |
| 记忆整合 | `src/services/autoDream/` | `executeAutoDream()` |
