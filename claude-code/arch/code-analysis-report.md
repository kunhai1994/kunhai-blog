# Claude Code 源码深度分析报告

> **项目**: Claude Code v2.1.88 — Anthropic 官方 CLI 智能编程助手
> **来源**: 从 npm 发布包的 source map 中逆向还原的 TypeScript 源码 (1884 个文件)
> **技术栈**: TypeScript + React (Ink 终端UI) + Bun 运行时

---

## 核心价值速览

> 一张表看清这套代码"值钱"在哪里。

### 关键板块总览

| # | 板块 | 一句话定位 | 规模 | 核心文件 |
|---|------|-----------|------|---------|
| 1 | **Query Engine** (查询引擎) | 整套系统的心脏 — 驱动"用户输入→模型推理→工具调用→结果输出"的完整循环 | ~3,000 行核心 + 大量辅助 | `query.ts`, `QueryEngine.ts`, `tokenBudget.ts` |
| 2 | **Coordinator** (多 Agent 编排) | 一个指挥官调度 N 个工兵并行干活，实现真正的 AI 多智能体协作 | coordinator/ + AgentTool/ + SendMessage/ | `coordinatorMode.ts`, `AgentTool.tsx`, `SendMessageTool.ts` |
| 3 | **Memory System** (记忆系统) | 跨会话持久化知识，让 AI "记住"你是谁、项目在干什么 | memdir/ + extractMemories/ + teamMemorySync/ | `memdir.ts`, `findRelevantMemories.ts`, `memoryTypes.ts` |
| 4 | **Dream Engine** (梦境引擎) | 后台自动将杂乱会话记录蒸馏为精炼知识——AI 版"睡眠整理记忆" | autoDream/ + DreamTask/ | `autoDream.ts`, `consolidationPrompt.ts`, `consolidationLock.ts` |
| 5 | **KAIROS** (永驻助手) | 让 AI 从"一次性对话"升级为"24小时驻场工程师"，永不下线 | assistant/ + bridge/ + BriefTool/ | `sessionHistory.ts`, `bridgeMain.ts`, `BriefTool.ts` |
| 6 | **Anti-Distillation** (反蒸馏) | 三层防护防止竞争对手通过 API 交互"偷走"模型能力 | 分布于 api/ + utils/ | `claude.ts`, `betas.ts`, `streamlinedTransform.ts` |
| 7 | **Buddy** (AI 宠物伴侣) | 基于确定性哈希的 Gacha 抽卡系统 + 终端 ASCII 宠物动画 | buddy/ (8 文件) | `companion.ts`, `CompanionSprite.tsx`, `types.ts` |
| 8 | **Tool System** (工具体系) | 43 个工具覆盖文件/Shell/搜索/MCP/LSP/Web，构成 AI 的"手和脚" | tools/ (43 模块) | `Tool.ts`, `BashTool.ts`, `FileEditTool.ts` |

### 关键技术点 & 亮点

| 技术点 | 所属板块 | 为什么值钱 | 技术亮点 |
|--------|---------|-----------|---------|
| **流式工具执行 (Streaming Tool Execution)** | Query Engine | 工具调用块一到达就立即执行，不等模型流完成，**大幅缩短端到端延迟** | `StreamingToolExecutor` 并行管理多个工具生命周期，同时向上游 yield 流数据 |
| **三级消息压缩 (Snip → Microcompact → Autocompact)** | Query Engine | 让超长对话在有限上下文窗口内存活，**永不断档** | Snip 零成本删旧消息 → Microcompact 零成本压缩工具IO → Autocompact 用 Haiku 做全文摘要；413 时还有 Context Collapse + Reactive Compact 兜底 |
| **收益递减检测 (Diminishing Returns)** | Query Engine | 防止模型空转浪费 token — 连续 3+ 轮增长 <500 token 自动停止 | 每轮 delta 比对 + 阈值判断，优雅退出而非硬截断 |
| **4阶段多 Agent 工作流** | Coordinator | 真正的并行 AI 协作：研究→综合→实现→验证，**不是玩具 demo** | Worker 无 Agent 工具（防递归）；Coordinator 必须"亲自理解"后才能给指令（禁止懒委派）；XML 结构化通知带 usage 指标 |
| **Prompt Cache 优化** | Coordinator | Fork 子进程共享字节相同的 API 前缀，**N 个 Worker 只付 1 份缓存成本** | `buildForkedMessages()` 构造相同 placeholder，只有末尾指令不同 → 命中率极高 |
| **异步消息队列 + 广播** | Coordinator | 非阻塞通信：Worker 执行中也能收消息；`to: "*"` 一键广播全员 | `queuePendingMessage()` 在工具轮次边界投递，`SendMessage` 支持单播/广播/邮箱路由 |
| **4种记忆分类法 (User/Feedback/Project/Reference)** | Memory | 不是简单"存个笔记"——区分**谁的知识、什么类型、该不该共享** | User=永远私有；Feedback=带 Why/How 结构化；Project=倾向团队共享+日期绝对化；Reference=外部系统指针 |
| **Sonnet 智能检索 Top-5** | Memory | 不是全量加载——用 Sonnet 从 200 个记忆中**精选 5 条最相关的** | 只读 frontmatter（零全文开销）→ Sonnet 排序 → 缓存已浮现记忆避免重复 |
| **团队记忆同步 + 密钥扫描** | Memory | 多人协作共享项目知识，同时**自动拦截密钥/凭证泄露** | ETag 版本控制 + SHA-256 校验 + gitleaks 密钥扫描 + 冲突合并策略 |
| **三重门控触发 (Time → Session → Lock)** | Dream Engine | 不浪费资源——只在"确实积累了足够新知识"时才触发后台整合 | 门控按成本递增排序（1次 stat → N次 readdir → 1次锁争夺）；10分钟扫描节流防空转；PID 检测 + 60分钟过期自动回收死锁 |
| **4阶段整合协议 (Orient→Gather→Consolidate→Prune)** | Dream Engine | 不是简单追加——**主动发现过时信息、合并重复、解决矛盾、控制体积** | MEMORY.md ≤200行/25KB 硬限；相对日期→绝对日期；矛盾事实自动删除 |
| **GrowthBook 动态配置** | Dream / Anti-Distill | 不发版就能调参——服务端实时控制做梦频率、反蒸馏策略等 | `tengu_onyx_plover` 控制 minHours/minSessions；`tengu_anti_distill_fake_tool_injection` 控制诱饵工具 |
| **会话持久化 + 崩溃恢复** | KAIROS | AI 进程崩了也不丢状态——自动从上次断点恢复 | crashRecoveryPointer 写入磁盘 → `--continue` 读取 → environment_id 匹配验证 → WebSocket 重连 |
| **分页历史懒加载** | KAIROS | 永驻会话可能有海量历史——滚动到顶部才按需加载，**不炸内存** | `anchor_to_latest` 首页 → `before_id` 游标分页 → 滚动锚定防跳 → 视口填充链（最多10页自动加载） |
| **Connector Text 签名摘要** | Anti-Distillation | 攻击者看到摘要、合法用户通过签名还原原文——**信息不对称防护** | API 缓冲 tool 间文本 → 返回 summary + signature → 后续 turn 用 signature 还原 |
| **Fake Tools 注入** | Anti-Distillation | 在真实工具列表中混入诱饵——攻击者**无法区分真实能力边界** | `anti_distillation: ['fake_tools']` 请求体 → API 服务端注入 → 仅第一方 CLI 启用 |
| **Streamlined Output 脱敏** | Anti-Distillation | 只输出工具计数不输出具体调用 + 剥离 thinking/model info | 按类别（search/read/write/command）聚合计数 → "searched 3, read 5" 而非完整调用链 |
| **Mulberry32 确定性生成** | Buddy | 同一 userId **永远生成同一宠物**，不需要服务端存储 | userId + salt → Hash → Mulberry32 PRNG → 稀有度/种族/眼睛/帽子/属性值全确定性 |
| **Bones 不持久化设计** | Buddy | 宠物"基因"从 hash 重算——**可随时加新种族、防篡改稀有度** | 只持久化 Soul（名字+性格）；Bones 每次启动重新 roll → 种族表变了也不 break |
| **稀有度加权属性系统** | Buddy | Legendary 底线 50、Common 底线 5——**稀有度真的"值钱"** | 1峰值+1短板+3散布；RARITY_FLOOR 决定下限；RARITY_WEIGHTS 决定抽中概率 |

### 工程能力亮点

| 维度 | 亮点 | 具体体现 |
|------|------|---------|
| **可测试性** | 依赖注入贯穿核心路径 | Query Engine 的 4 个 I/O deps（callModel/microcompact/autocompact/uuid）全部可替换；autoDream 闭包作用域隔离支持 beforeEach 重置 |
| **可观测性** | 全链路 Analytics + Profile | `CLAUDE_CODE_PROFILE_QUERY=1` 输出每阶段耗时；GrowthBook 事件（fired/completed/failed）全覆盖；TTFT 首 token 延迟独立追踪 |
| **容错性** | 多层错误恢复不死机 | 413 → Collapse → Compact → 报错；MaxOutput → Escalation → 3次 Resume → 报错；Dream 锁崩溃 → PID 检测 + 60分钟自动回收 |
| **安全性** | 多维度防护 | 反蒸馏三层防护；团队记忆密钥扫描；Worker 无 Agent 工具（防递归炸弹）；memory 目录路径校验防逃逸 |
| **性能优化** | 从 API 到 UI 全栈优化 | Prompt Cache 共享（N 个 fork 付 1 份钱）；Microcompact 零成本（缓存 diff）；Buddy hash 单次缓存（3 个热路径复用）；10分钟扫描节流 |
| **动态运营** | 不发版即可调参 | GrowthBook feature flags 控制：做梦频率、反蒸馏开关、Buddy 上线窗口、Brief 权限——全部服务端热更新 |
| **渐进式体验** | 从简单到强大平滑过渡 | 普通模式 → KAIROS 永驻模式 → Coordinator 多 Agent 模式；`--bare` 最简模式关闭一切后台功能；Buddy 愚人节彩蛋窗口式软上线 |

---

## 一、整体架构

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Claude Code 架构总览                           │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────┐                  │
│  │  CLI 入口 │──▶│  QueryEngine │──▶│  Anthropic API │                  │
│  │ main.tsx  │   │  query.ts    │   │  (Claude Model) │                  │
│  └──────────┘   └──────┬───────┘   └────────────────┘                  │
│       │                │                                                │
│       ▼                ▼                                                │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────┐                  │
│  │ React/Ink│   │  Tool System │   │  Coordinator   │                  │
│  │ 终端 UI  │   │  (43 Tools)  │   │  (多 Agent)     │                  │
│  └──────────┘   └──────────────┘   └────────────────┘                  │
│       │                │                    │                           │
│       ▼                ▼                    ▼                           │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────┐                  │
│  │ Components│   │   Services   │   │  Memory System │                  │
│  │ (146个)   │   │ (API/MCP/...) │   │ (memdir/dream) │                  │
│  └──────────┘   └──────────────┘   └────────────────┘                  │
│       │                │                    │                           │
│       ▼                ▼                    ▼                           │
│  ┌──────────┐   ┌──────────────┐   ┌────────────────┐                  │
│  │  Buddy   │   │Anti-Distill  │   │    KAIROS      │                  │
│  │ 宠物系统  │   │ 反蒸馏防护    │   │  (长驻助手)     │                  │
│  └──────────┘   └──────────────┘   └────────────────┘                  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 核心链路

```
用户输入
  │
  ▼
main.tsx (CLI 引导 / 命令路由)
  │
  ▼
QueryEngine.submitMessage(prompt)    ◀── 系统提示词 + 记忆 + 上下文
  │
  ├─ 消息预处理 (斜杠命令 / 附件 / model 选择)
  ├─ 系统提示词构建 (默认 + 自定义 + 记忆机制 + 附加)
  │
  ▼
query() 核心循环 (async generator)
  │
  ├─ Stage 1: 消息压缩 (Snip → Microcompact → Autocompact)
  ├─ Stage 2: API 调用准备 (Token 预算 / 工具 Schema)
  ├─ Stage 3: 流式调用 Claude API + StreamingToolExecutor
  ├─ Stage 4: 错误恢复 (413 → Compact / MaxOutput → Escalation)
  ├─ Stage 5: 工具执行 (Bash / FileEdit / Grep / MCP / ...)
  ├─ Stage 6: 后置附件 (记忆预取 / Skill 发现 / 文件变更)
  ├─ Stage 7: StopHooks (extractMemories / autoDream / ...)
  │
  ▼
终止条件: 无工具调用 / 预算耗尽 / 最大轮次 / 用户中断
  │
  ▼
结果输出 → React/Ink 终端渲染
```

---

## 二、关键技术深度分析

---

### 2.1 KAIROS — 永驻 AI 助手系统

#### 概念

KAIROS 是 Claude Code 的"常驻守护进程"模式。不同于普通会话（对话结束即退出），KAIROS 让 Claude 作为一个**永久在线的 AI 助手**运行，跨多次调用维持持续状态、积累记忆和上下文。

#### 架构图

```
┌─────────────────────────────────────────────────┐
│                 KAIROS 架构                      │
│                                                  │
│  ┌─────────┐     ┌──────────────┐                │
│  │ CLI 入口 │────▶│ Bridge 桥接  │                │
│  │ --continue│    │ (WebSocket)  │                │
│  │ --session│    └──────┬───────┘                │
│  └─────────┘           │                         │
│                        ▼                         │
│  ┌──────────────────────────────────┐            │
│  │      Session Manager             │            │
│  │  ┌──────────┐  ┌──────────────┐  │            │
│  │  │ 崩溃恢复  │  │ 会话元数据    │  │            │
│  │  │ Pointer  │  │ (环境/ID)    │  │            │
│  │  └──────────┘  └──────────────┘  │            │
│  └──────────────────┬───────────────┘            │
│                     │                            │
│     ┌───────────────┼───────────────┐            │
│     ▼               ▼               ▼            │
│  ┌───────┐   ┌───────────┐   ┌──────────┐       │
│  │ Brief │   │ Daily Log │   │ History  │       │
│  │ Tool  │   │ 每日日志   │   │ 分页加载  │       │
│  └───────┘   └───────────┘   └──────────┘       │
│                                                  │
│  Feature Gate: feature('KAIROS')                 │
│  GrowthBook:   tengu_kairos_brief                │
└─────────────────────────────────────────────────┘
```

#### 原理图 — 会话恢复流程

```
用户执行: claude --continue
       │
       ▼
 读取 crashRecoveryPointer ──▶ 获取 sessionId
       │
       ▼
 从后端获取会话 ──▶ 验证 environment_id 匹配
       │
       ▼
 注册 Bridge 环境 ──▶ 复用 environment_id
       │
       ▼
 重连基础设施会话 (cse_* ID)
       │
       ▼
 恢复轮询 ──▶ 助手继续工作
```

#### 代码示例：Brief Tool — KAIROS 的主要输出通道

在 `restored-src/src/tools/BriefTool/BriefTool.ts` 中，Brief (SendUserMessage) 是 KAIROS 模式下助手与用户通信的唯一窗口：

```typescript
// 入口判断：Brief 是否激活
export function isBriefEnabled(): boolean {
  return (
    isBriefEntitled() &&           // GrowthBook 权限检查
    (getKairosActive() ||          // KAIROS 模式激活
      getUserMsgOptIn())            // 或用户手动开启
  )
}

// Tool Schema — 助手可以发送消息+附件
input_schema: {
  message: string,                // Markdown 格式消息
  attachments?: string[],         // 文件路径列表
  status: 'normal' | 'proactive'  // 常规 vs 主动通知
}
```

**科普例子**：想象你有一个 24 小时值班的 AI 助手。普通模式下，你问一句它答一句，对话结束它就"下班"了。KAIROS 让这个助手变成"驻场工程师" — 它永远在线，通过 Brief Tool 主动向你发消息（"嘿，我发现测试挂了"），同时维护每日日志记录自己做了什么，第二天你来了可以无缝继续。

---

### 2.2 Buddy 系统 — AI 宠物伴侣

#### 概念

Buddy 是一个基于确定性伪随机生成的**AI 宠物伴侣系统**。每个用户根据其 userId 生成一个独一无二的宠物，拥有种族、稀有度、帽子、眼睛和属性值。这是一个完整的 Gacha（抽卡）系统。

#### 架构图

```
┌───────────────────────────────────────────────────────┐
│                 Buddy 宠物系统架构                      │
│                                                        │
│  ┌──────────┐                                          │
│  │ userId   │                                          │
│  │ + salt   │                                          │
│  └────┬─────┘                                          │
│       │ Hash (Bun.hash / FNV-1a)                       │
│       ▼                                                │
│  ┌──────────┐                                          │
│  │Mulberry32│ ◀── 种子 PRNG                            │
│  │  PRNG    │                                          │
│  └────┬─────┘                                          │
│       │ 确定性随机序列                                   │
│       ├──────────────────────────────────┐              │
│       ▼                ▼                 ▼              │
│  ┌─────────┐    ┌───────────┐    ┌──────────┐          │
│  │ BONES   │    │   SOUL    │    │  SPRITE  │          │
│  │ (每次生成)│    │ (一次持久化)│    │ (UI 渲染) │          │
│  │         │    │           │    │          │          │
│  │ 稀有度   │    │ 名字      │    │ ASCII 艺术│          │
│  │ 种族     │    │ 性格      │    │ 动画帧    │          │
│  │ 眼睛     │    │           │    │ 气泡对话  │          │
│  │ 帽子     │    │ 存储:     │    │ 拍头动画  │          │
│  │ 闪光     │    │ config.   │    │          │          │
│  │ 属性值   │    │ companion │    │ 18 种形态 │          │
│  └─────────┘    └───────────┘    └──────────┘          │
│                                                        │
│  稀有度分布:                                             │
│  ████████████████████░░░░░░ 60% Common                 │
│  ██████████░░░░░░░░░░░░░░░ 25% Uncommon                │
│  ████░░░░░░░░░░░░░░░░░░░░ 10% Rare                    │
│  ██░░░░░░░░░░░░░░░░░░░░░░  4% Epic                    │
│  █░░░░░░░░░░░░░░░░░░░░░░░  1% Legendary               │
└───────────────────────────────────────────────────────┘
```

#### 核心算法 — Mulberry32 伪随机数生成器

在 `restored-src/src/buddy/companion.ts:16` 中：

```typescript
// Mulberry32 — 轻量种子 PRNG，足够为宠物"掷骰子"
function mulberry32(seed: number): () => number {
  let a = seed >>> 0
  return function () {
    a |= 0
    a = (a + 0x6d2b79f5) | 0                    // 黄金比例常数
    let t = Math.imul(a ^ (a >>> 15), 1 | a)     // 位混合
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296  // 归一化到 [0,1)
  }
}
```

**关键设计**：Bones（骨骼/基因）**永不持久化** — 每次从 hash 重新生成。这样做的好处：
1. 可以随时增加新种族而不影响已有宠物
2. 防止用户通过修改配置文件"伪造"稀有度

#### 属性值分配策略

```typescript
// 一个高峰属性，一个低谷属性，其余散布
function rollStats(rng, rarity): Record<StatName, number> {
  const floor = RARITY_FLOOR[rarity]  // 稀有度越高底线越高
  const peak = pick(rng, STAT_NAMES)   // 随机选一个做巅峰
  let dump = pick(rng, STAT_NAMES)     // 随机选一个做短板

  // peak:  floor + 50 + rand(30)  → 最高可达 100
  // dump:  floor - 10 + rand(15)  → 最低到 1
  // other: floor + rand(40)       → 中间值
}
```

**科普例子**：就像 Pokémon 的个体值(IV)系统。你的 userId 就是你的"训练家ID"，通过哈希决定你会遇到什么宠物。一个 Legendary 等级的 Dragon 宠物（1%概率），所有属性底线从 50 开始，巅峰属性可以到 100 — 而 Common 的 Duck 底线只有 5。宠物还会在终端里用 ASCII 艺术"活过来"，有待机动画、说话动画和被摸头时的爱心动画。

---

### 2.3 Anti-Distillation — 反蒸馏防护体系

#### 概念

Anti-Distillation 是一套多层安全防护架构，旨在**防止第三方通过 API 交互窃取/复制 Claude 的行为模式和能力**（模型蒸馏攻击）。

#### 架构图

```
┌───────────────────────────────────────────────────────────┐
│               Anti-Distillation 三层防护                   │
│                                                            │
│  Layer 1: Connector Text Summarization                     │
│  ┌──────────────────────────────────────────────┐          │
│  │                                              │          │
│  │  Assistant 输出 ──▶ API 缓冲 ──▶ 摘要+签名   │          │
│  │                                    │         │          │
│  │  后续 Turn:  签名 ──▶ 还原原文 ──▶ 继续对话   │          │
│  │                                              │          │
│  │  攻击者看到: 摘要（非原文）                    │          │
│  │  合法用户:   通过签名还原完整上下文             │          │
│  └──────────────────────────────────────────────┘          │
│                                                            │
│  Layer 2: Fake Tools Injection                             │
│  ┌──────────────────────────────────────────────┐          │
│  │                                              │          │
│  │  真实工具:  [Bash, Read, Edit, Grep, ...]    │          │
│  │       +                                      │          │
│  │  诱饵工具:  [FakeTool_A, FakeTool_B, ...]    │          │
│  │                                              │          │
│  │  攻击者无法区分哪些是真实能力                   │          │
│  └──────────────────────────────────────────────┘          │
│                                                            │
│  Layer 3: Streamlined Output Mode                          │
│  ┌──────────────────────────────────────────────┐          │
│  │                                              │          │
│  │  原始输出:     "Read src/auth.ts → found     │          │
│  │                bug at line 42 → Edit fix..."  │          │
│  │       ↓                                      │          │
│  │  脱敏输出:     "searched 3 patterns,          │          │
│  │                read 5 files, ran 2 commands"  │          │
│  │                                              │          │
│  │  ✗ Thinking blocks → 完全删除                 │          │
│  │  ✗ Tool list/Model info → 完全剥离            │          │
│  └──────────────────────────────────────────────┘          │
└───────────────────────────────────────────────────────────┘
```

#### 代码示例：Fake Tools 注入

在 `restored-src/src/services/api/claude.ts:301` 中：

```typescript
// Anti-distillation: 仅对第一方 CLI 发送 fake_tools
if (
  feature('ANTI_DISTILLATION_CC')
    ? process.env.CLAUDE_CODE_ENTRYPOINT === 'cli' &&
      shouldIncludeFirstPartyOnlyBetas() &&
      getFeatureValue_CACHED_MAY_BE_STALE(
        'tengu_anti_distill_fake_tool_injection',
        false,
      )
    : false
) {
  result.anti_distillation = ['fake_tools']  // 请求 API 注入诱饵工具
}
```

#### 代码示例：Streamlined Output 工具分类

在 `restored-src/src/utils/streamlinedTransform.ts:38` 中：

```typescript
// 工具按功能分类，输出时只报告计数，不暴露具体调用
const SEARCH_TOOLS = [GREP, GLOB, WEB_SEARCH, LSP]
const READ_TOOLS   = [FILE_READ, LIST_MCP_RESOURCES]
const WRITE_TOOLS  = [FILE_WRITE, FILE_EDIT, NOTEBOOK_EDIT]
const COMMAND_TOOLS = [...SHELL_TOOLS, 'Tmux', TASK_STOP]

// 输出示例: "searched 3 patterns, read 5 files, wrote 2 files"
// 而非:     "Grep('auth bug') → FileRead('/src/auth.ts') → ..."
```

**科普例子**：假设你是一家餐厅的大厨（Claude），有人派了一个间谍来"偷师"你的菜谱。Anti-Distillation 就像三道防线：
1. **Connector Text**：间谍看到的不是你的完整烹饪过程，而是一份简短摘要（"做了一道红烧肉"），但你自己下次继续做的时候能通过"签名"回忆起所有细节
2. **Fake Tools**：你的厨房里放了一堆假工具（装饰用的锅铲），间谍搞不清你到底会用哪些
3. **Streamlined Output**：你只告诉间谍"切了3次、炒了5次"，而不是"先把五花肉切2cm见方..."

---

### 2.4 Dream Engine — 记忆整合引擎

#### 概念

Dream Engine（梦境引擎）是一套**后台异步记忆整合系统**。就像人在睡眠中整理白天的记忆一样，Claude Code 在后台自动将积累的会话记录蒸馏为精炼的、持久化的知识。

#### 架构图

```
┌────────────────────────────────────────────────────────────┐
│                  Dream Engine 架构                          │
│                                                             │
│  ┌─────────────────────────────────────────┐                │
│  │           三重门控 (Gate System)          │                │
│  │                                         │                │
│  │  Gate 1: 时间门控                        │                │
│  │  ┌─────────────────────────────────┐    │                │
│  │  │ now - lastConsolidatedAt ≥ 24h  │    │                │
│  │  └──────────────┬──────────────────┘    │                │
│  │                 │ PASS                   │                │
│  │                 ▼                        │                │
│  │  Gate 2: 会话门控 (每10分钟扫描一次)       │                │
│  │  ┌─────────────────────────────────┐    │                │
│  │  │ 新增 transcript 数量 ≥ 5        │    │                │
│  │  └──────────────┬──────────────────┘    │                │
│  │                 │ PASS                   │                │
│  │                 ▼                        │                │
│  │  Gate 3: 锁门控                          │                │
│  │  ┌─────────────────────────────────┐    │                │
│  │  │ .consolidate-lock 未被占用       │    │                │
│  │  │ (PID 检测 + 60分钟过期)          │    │                │
│  │  └──────────────┬──────────────────┘    │                │
│  │                 │ PASS                   │                │
│  └─────────────────┼───────────────────────┘                │
│                    ▼                                        │
│  ┌─────────────────────────────────────────┐                │
│  │         Dream 四阶段执行                  │                │
│  │                                         │                │
│  │  Phase 1: Orient (定位)                  │                │
│  │  ├─ ls memory/                          │                │
│  │  ├─ cat MEMORY.md                       │                │
│  │  └─ skim topic files                    │                │
│  │              │                           │                │
│  │  Phase 2: Gather Signal (收集信号)        │                │
│  │  ├─ 读取每日日志 logs/YYYY/MM/...        │                │
│  │  ├─ 检查过时事实                          │                │
│  │  └─ grep 会话记录 (窄范围)                │                │
│  │              │                           │                │
│  │  Phase 3: Consolidate (整合)              │                │
│  │  ├─ 写入/更新 topic 文件                   │                │
│  │  ├─ 合并信号到已有主题                     │                │
│  │  └─ 删除矛盾事实                          │                │
│  │              │                           │                │
│  │  Phase 4: Prune & Index (修剪+索引)       │                │
│  │  ├─ MEMORY.md ≤ 200行 / 25KB            │                │
│  │  ├─ 每条 ≤ 150字符                       │                │
│  │  └─ 解决矛盾、删除过期条目                 │                │
│  └─────────────────────────────────────────┘                │
│                                                             │
│  执行方式: 后台 Forked Subagent (非阻塞)                     │
│  权限限制: 只读 Bash + 仅 memory 目录可写                     │
└────────────────────────────────────────────────────────────┘
```

#### 代码示例：门控系统

在 `restored-src/src/services/autoDream/autoDream.ts` 中：

```typescript
// 默认配置：24小时 + 5个会话
const DEFAULTS: AutoDreamConfig = {
  minHours: 24,     // 距上次整合至少 24 小时
  minSessions: 5,   // 至少积累 5 个新会话
}

// 扫描节流：时间门通过但会话门未通过时，
// 锁的 mtime 不变，时间门会每轮都通过 → 需要节流
const SESSION_SCAN_INTERVAL_MS = 10 * 60 * 1000  // 10 分钟
```

#### 锁机制与故障恢复

```
正常流程:
  tryAcquireConsolidationLock()
    → 写入 PID 到 .consolidate-lock
    → 返回 priorMtime (用于回滚)
    → Dream Agent 执行
    → 完成后锁自动释放

失败回滚:
  rollbackConsolidationLock(priorMtime)
    → 将锁 mtime 恢复到执行前
    → 下次时间门仍可通过（不需要再等 24h）

崩溃恢复:
  → 下一个进程读取锁文件
  → 检测 PID 是否存活 (kill(pid, 0))
  → 锁超过 60 分钟 → 自动回收
```

**科普例子**：把你的项目记忆想象成一个书桌。每天你在上面堆各种便签（会话记录）。Dream Engine 就像一个"夜间整理员"——在你不用电脑的时候（24小时+5个会话后），它悄悄来到书桌前，把便签分类归档到对应的文件夹里（topic files），然后更新一份总目录（MEMORY.md），扔掉过时的便签。而且它很有礼貌：先检查有没有其他整理员在忙（Lock），确认没人后才开始工作。

---

### 2.5 autoDream — 自动梦境触发器

#### 概念

autoDream 是 Dream Engine 的**自动触发器**，嵌入在每次 query 循环结束后的 stopHooks 中。它负责判断"是否该做梦了"。

#### 链路图

```
用户完成一次对话
       │
       ▼
query() 循环结束
       │
       ▼
stopHooks.ts → executeAutoDream()
       │
       ├── 前置检查 ──┐
       │              ├─ isAutoMemoryEnabled()?
       │              ├─ !getKairosActive()?      (KAIROS 用 disk-skill)
       │              ├─ !getIsRemoteMode()?
       │              ├─ isAutoDreamEnabled()?     (GrowthBook/settings)
       │              └─ !--bare && !agentId?
       │
       ▼ (全部通过)
   Gate 1: 时间门
       │ (≥24h → PASS)
       ▼
   Gate 2: 会话门 (10min 节流)
       │ (≥5 sessions → PASS)
       ▼
   Gate 3: 锁门
       │ (lock 空闲 → 获取)
       ▼
   runForkedAgent(consolidationPrompt)
       │
       ├── 4 个 Phase 执行 ──▶ 记忆整合完成
       │
       ▼
   Analytics 记录:
   tengu_auto_dream_fired / completed / failed
```

#### 代码示例：从 GrowthBook 获取动态配置

```typescript
function getConfig(): AutoDreamConfig {
  const raw = getFeatureValue_CACHED_MAY_BE_STALE<Partial<AutoDreamConfig>>(
    'tengu_onyx_plover',   // GrowthBook feature flag
    null,
  )
  return {
    minHours:    typeof raw?.minHours === 'number'    ? raw.minHours    : DEFAULTS.minHours,
    minSessions: typeof raw?.minSessions === 'number' ? raw.minSessions : DEFAULTS.minSessions,
  }
}
```

这意味着 Anthropic 可以在服务端**动态调整**做梦频率，比如从24小时改为12小时，不需要发布新版本。

---

### 2.6 记忆系统 — 持久化知识管理

#### 概念

记忆系统是 Claude Code 跨会话保持上下文的核心机制。它采用**文件式存储 + 四种记忆类型 + 多层次检索 + 团队协作**的架构。

#### 架构图

```
┌───────────────────────────────────────────────────────────────┐
│                    记忆系统完整架构                              │
│                                                                │
│  ~/.claude/projects/<project>/memory/                          │
│  │                                                             │
│  ├── MEMORY.md          ◀── 索引文件 (≤200行, ≤25KB)          │
│  │   │                                                         │
│  │   ├── [User] 用户偏好 → user_role.md                       │
│  │   ├── [Feedback] 工作方式 → feedback_testing.md            │
│  │   ├── [Project] 项目背景 → project_auth_rewrite.md         │
│  │   └── [Reference] 外部资源 → reference_linear.md           │
│  │                                                             │
│  ├── team/              ◀── 团队共享记忆                       │
│  │   ├── MEMORY.md                                             │
│  │   └── *.md           (ETag 同步 + 密钥扫描)                │
│  │                                                             │
│  └── logs/              ◀── 每日日志 (KAIROS 模式)             │
│      └── YYYY/MM/                                              │
│          └── YYYY-MM-DD.md  (仅追加)                           │
│                                                                │
│  ┌──────────────────────┐  ┌──────────────────────┐            │
│  │   写入路径            │  │   读取路径            │            │
│  │                      │  │                      │            │
│  │  extractMemories     │  │  findRelevantMemories│            │
│  │  (每轮结束自动提取)   │  │  (Sonnet 选 Top-5)   │            │
│  │       │              │  │       │              │            │
│  │  autoDream           │  │  memoryAge           │            │
│  │  (后台整合)          │  │  (过时警告)           │            │
│  │       │              │  │       │              │            │
│  │  用户直接写入         │  │  系统提示词注入       │            │
│  │  ("请记住...")       │  │  (MEMORY.md 全文)    │            │
│  └──────────────────────┘  └──────────────────────┘            │
│                                                                │
│  ┌─────────────────────────────────────────────┐               │
│  │         记忆类型与存储规则                     │               │
│  │                                             │               │
│  │  User     → 私有 (角色/知识/偏好)            │               │
│  │  Feedback → 默认私有 (工作纠正/确认)          │               │
│  │  Project  → 倾向团队 (目标/deadline/决策)     │               │
│  │  Reference→ 通常团队 (外部系统指针)           │               │
│  └─────────────────────────────────────────────┘               │
└───────────────────────────────────────────────────────────────┘
```

#### 记忆文件格式

每个记忆文件包含 YAML frontmatter：

```yaml
---
name: auth-middleware-rewrite
description: Auth middleware rewrite driven by legal compliance, not tech debt
type: project
---

Auth middleware rewrite is driven by legal/compliance requirements around
session token storage, not tech-debt cleanup.

**Why:** Legal flagged session tokens stored in a non-compliant way
**How to apply:** Scope decisions should favor compliance over ergonomics
```

#### 代码示例：智能记忆检索

在 `restored-src/src/memdir/findRelevantMemories.ts` 中：

```typescript
// 使用 Sonnet 模型智能选择最相关的 5 条记忆
async function findRelevantMemories(query: string): Promise<MemoryFile[]> {
  // 1. 扫描 memory 目录所有 .md 文件 (最多 200 个)
  // 2. 读取每个文件的 frontmatter (name + description + type)
  // 3. 将文件列表 + 用户查询发给 Sonnet
  // 4. Sonnet 返回 Top-5 最相关文件路径
  // 5. 缓存已浮现的记忆，避免重复选择
}
```

#### 记忆新鲜度追踪

```typescript
// memoryAge.ts — 记忆超过 1 天就加过时警告
function getMemoryAgeString(mtime: Date): string {
  // "today" | "yesterday" | "47 days ago"
  // 附带警告: "这是某一时间点的观察，非实时状态"
}
```

**科普例子**：把记忆系统想象成一个"智能笔记本"。你在和 Claude 合作开发项目时，它会自动记下你的角色（User: "我是后端工程师"）、你的偏好（Feedback: "测试不要用 mock"）、项目背景（Project: "3月5日后冻结合并"）和外部资源（Reference: "bug 追踪在 Linear INGEST 项目"）。下次你开新对话时，它用 Sonnet 模型从笔记中找出最相关的5条，让对话从"上次聊到哪里"继续。过时的笔记会被 Dream Engine 自动清理。

---

### 2.7 Coordinator — 多 Agent 协调系统

#### 概念

Coordinator 是 Claude Code 的**多智能体编排框架**。一个 Coordinator（指挥官）可以同时调度多个 Worker（工兵），让它们并行执行研究、实现和验证任务，最后由 Coordinator 综合结果。

#### 架构图

```
┌────────────────────────────────────────────────────────────────┐
│                    Coordinator 多 Agent 架构                    │
│                                                                 │
│                    ┌──────────────────┐                          │
│                    │      User        │                          │
│                    └────────┬─────────┘                          │
│                             │                                    │
│                             ▼                                    │
│               ┌─────────────────────────┐                        │
│               │     Coordinator Agent    │                        │
│               │  (主线程 / 指挥官)        │                        │
│               │                         │                        │
│               │  工具箱:                 │                        │
│               │  ├─ Agent (派遣工兵)     │                        │
│               │  ├─ SendMessage (通信)   │                        │
│               │  ├─ TaskStop (停止)      │                        │
│               │  ├─ TeamCreate (建队)    │                        │
│               │  └─ TeamDelete (解散)    │                        │
│               └──────┬──────┬──────┬────┘                        │
│                      │      │      │                              │
│          ┌───────────┘      │      └───────────┐                  │
│          ▼                  ▼                   ▼                  │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐            │
│  │  Worker A     │ │  Worker B     │ │  Worker C     │            │
│  │  (研究)       │ │  (实现)       │ │  (验证)       │            │
│  │              │ │              │ │              │            │
│  │ Bash, Read,  │ │ Bash, Read,  │ │ Bash, Read,  │            │
│  │ Edit, Grep,  │ │ Edit, Write, │ │ Grep, MCP,   │            │
│  │ WebSearch    │ │ MCP, Skill   │ │ Skill        │            │
│  │              │ │              │ │              │            │
│  │ ✗ 无 Agent   │ │ ✗ 无 Agent   │ │ ✗ 无 Agent   │            │
│  │ ✗ 无递归派遣 │ │ ✗ 无递归派遣 │ │ ✗ 无递归派遣 │            │
│  └──────┬────────┘ └──────┬────────┘ └──────┬────────┘            │
│         │                 │                 │                     │
│         └────────┐  ┌─────┘                 │                     │
│                  ▼  ▼                       ▼                     │
│         ┌────────────────────────────────────────┐                │
│         │          Task Notification             │                │
│         │  <task-notification>                   │                │
│         │    <status>completed</status>          │                │
│         │    <summary>Fixed auth bug</summary>   │                │
│         │    <usage>                              │                │
│         │      <total_tokens>15234</total_tokens>│                │
│         │      <duration_ms>8420</duration_ms>   │                │
│         │    </usage>                            │                │
│         │  </task-notification>                  │                │
│         └────────────────────────────────────────┘                │
│                                                                    │
│  通信模式:                                                         │
│  ├─ SendMessage(to: "worker-a", msg)   → 单播                     │
│  ├─ SendMessage(to: "*", msg)          → 广播                     │
│  └─ queuePendingMessage()              → 异步消息队列              │
└────────────────────────────────────────────────────────────────┘
```

#### 四阶段工作流

```
Phase 1: Research (研究)          Phase 2: Synthesis (综合)
┌──────────────────────┐         ┌──────────────────────┐
│  Worker A: 探索 bug   │         │  Coordinator 阅读    │
│  Worker B: 查看测试    │  ──▶    │  所有 Worker 的发现   │
│  Worker C: 研究 API   │         │  形成精确实施方案     │
│  (并行执行)           │         │  (不偷懒委派！)       │
└──────────────────────┘         └──────────────────────┘
         │                                │
         ▼                                ▼
Phase 3: Implementation (实现)   Phase 4: Verification (验证)
┌──────────────────────┐         ┌──────────────────────┐
│  Worker A: 按规格修改  │         │  Worker V: 独立验证  │
│  (Coordinator 给精确   │  ──▶    │  运行测试、检查行为   │
│   spec，非模糊指令)   │         │  证明代码正确工作     │
└──────────────────────┘         └──────────────────────┘
```

#### 代码示例：Coordinator 的核心判断 — 继续 vs 新建

```typescript
// coordinatorMode.ts 系统提示词中的关键原则：
//
// "Continue vs. spawn by context overlap:
//   - 如果 Worker 已经研究了需要修改的文件 → SendMessage 继续
//   - 如果新任务和之前的上下文无关 → 新建 Worker"
//
// 反面模式（严格禁止）：
// "Based on your findings, implement X"  ← Coordinator 必须自己理解后
//                                           才能给出精确指令

// Worker 的完成通知 — XML 结构化，直接注入为 user-role 消息
`<task-notification>
  <task-id>${agentId}</task-id>
  <status>completed</status>
  <summary>Found null pointer in auth.ts:42</summary>
  <result>${agent_final_response}</result>
  <usage>
    <total_tokens>15234</total_tokens>
    <tool_uses>12</tool_uses>
    <duration_ms>8420</duration_ms>
  </usage>
</task-notification>`
```

#### Prompt Cache 优化

```
Fork 子进程使用字节相同的 API 前缀 → 最大化缓存命中

Parent 会话:  [SystemPrompt][History][Tool-A-result]
                    ↓ 完全相同             ↓ 完全相同
Child A:      [SystemPrompt][History][Placeholder ] + "研究 auth 模块"
Child B:      [SystemPrompt][History][Placeholder ] + "研究 API 端点"

只有最后的指令文本不同 → API 缓存命中率极高
```

**科普例子**：想象你是一个项目经理（Coordinator），手下有3个工程师（Workers）。你不会自己去写代码，但你要：
1. **派任务**：让工程师A研究bug、工程师B查测试、工程师C看API文档（并行）
2. **听汇报**：三人完成后发来结构化报告（task-notification）
3. **做决策**：你读完所有报告，**亲自理解问题后**，给工程师A写一份精确的修复规格书
4. **盯验证**：派工程师V（独立第三方）验证修复确实有效

关键原则：你不能偷懒说"根据你的发现去修吧" — 你必须自己消化发现，形成明确指令。

---

### 2.8 Query Engine — 查询引擎

#### 概念

Query Engine 是 Claude Code 的**核心对话引擎**，负责管理从用户输入到模型响应的完整生命周期，包括多轮工具调用、token 预算管理、错误恢复和流式处理。

#### 架构图

```
┌──────────────────────────────────────────────────────────────────┐
│                     Query Engine 架构                             │
│                                                                   │
│  ┌──────────────────────────────────────────────────────┐         │
│  │              QueryEngine (高层门面)                    │         │
│  │                                                      │         │
│  │  submitMessage(prompt)                                │         │
│  │  ├─ 用户输入处理 (斜杠命令 / 附件 / model)            │         │
│  │  ├─ 系统提示词构建                                    │         │
│  │  ├─ 孤儿权限处理 (CCR 恢复)                           │         │
│  │  └─ 调用 query() 核心循环                             │         │
│  └────────────────────────┬─────────────────────────────┘         │
│                           │                                       │
│                           ▼                                       │
│  ┌──────────────────────────────────────────────────────┐         │
│  │              query() 核心循环                         │         │
│  │                                                      │         │
│  │  ┌─────────────────────────────────────────────┐     │         │
│  │  │        消息压缩三级策略                       │     │         │
│  │  │                                             │     │         │
│  │  │  Snip ──▶ Microcompact ──▶ Autocompact     │     │         │
│  │  │  (删旧消息)  (压缩工具IO)  (全文摘要)         │     │         │
│  │  │                                             │     │         │
│  │  │  触发: 每轮    每轮          Token阈值       │     │         │
│  │  │  成本: 0       0 (缓存)     ~Haiku 成本     │     │         │
│  │  └─────────────────────────────────────────────┘     │         │
│  │                    │                                  │         │
│  │                    ▼                                  │         │
│  │  ┌─────────────────────────────────────────────┐     │         │
│  │  │            API 流式调用                       │     │         │
│  │  │                                             │     │         │
│  │  │  Claude API ──stream──▶ StreamingToolExecutor│     │         │
│  │  │                        │                    │     │         │
│  │  │              tool_use_block 到达即执行       │     │         │
│  │  │              (不等全部流完成)                 │     │         │
│  │  └─────────────────────────────────────────────┘     │         │
│  │                    │                                  │         │
│  │                    ▼                                  │         │
│  │  ┌─────────────────────────────────────────────┐     │         │
│  │  │            错误恢复策略                       │     │         │
│  │  │                                             │     │         │
│  │  │  413 Prompt-Too-Long:                       │     │         │
│  │  │  ├─ Context Collapse Drain (低成本)          │     │         │
│  │  │  └─ Reactive Compact (全摘要)                │     │         │
│  │  │                                             │     │         │
│  │  │  Max-Output-Tokens:                         │     │         │
│  │  │  ├─ Escalation: 8K → 64K                   │     │         │
│  │  │  └─ Recovery: 最多 3 次 "Resume" 重试       │     │         │
│  │  └─────────────────────────────────────────────┘     │         │
│  │                    │                                  │         │
│  │                    ▼                                  │         │
│  │  ┌─────────────────────────────────────────────┐     │         │
│  │  │            终止条件                           │     │         │
│  │  │                                             │     │         │
│  │  │  ✓ 无工具调用 (自然结束)                     │     │         │
│  │  │  ✓ Token 预算耗尽 (<90% 剩余)               │     │         │
│  │  │  ✓ 最大轮次到达                              │     │         │
│  │  │  ✓ 最大 USD 消费                             │     │         │
│  │  │  ✓ 用户中断 (AbortController)                │     │         │
│  │  │  ✓ 收益递减 (3+轮 <500 token 增长)           │     │         │
│  │  └─────────────────────────────────────────────┘     │         │
│  └──────────────────────────────────────────────────────┘         │
└──────────────────────────────────────────────────────────────────┘
```

#### Token 预算管理原理图

```
上下文窗口 (Context Window)
┌─────────────────────────────────────────────────────┐
│█████████████████████████████████████░░░░░░░░░░░░░░░│
│◀────── 已使用 Token ──────▶│◀── 剩余空间 ──▶│
│                             │                      │
│  当剩余 < 10%:             │                      │
│  ├─ Snip: 删除最老的消息    │                      │
│  ├─ Microcompact: 压缩工具IO│                      │
│  └─ Autocompact: Haiku 摘要整个对话                │
│                                                     │
│  当 API 返回 413:                                   │
│  ├─ Context Collapse: 批量折叠待处理消息             │
│  └─ Reactive Compact: 紧急全文摘要                  │
└─────────────────────────────────────────────────────┘

Token 预算跟踪 (tokenBudget.ts):
  继续阈值: 已使用 < 90% of 总预算
  收益递减检测: 连续 3+ 轮 && 每轮增长 < 500 tokens → 停止
```

#### 代码示例：流式工具执行

```typescript
// query.ts — 工具一到即执行，不等流结束
async function* queryLoop(params: QueryParams) {
  // Stage 3: 模型流式响应
  const stream = deps.callModel(apiParams)

  for await (const chunk of stream) {
    if (chunk.type === 'tool_use') {
      // 工具调用块到达 → 立即执行（不等后续块）
      // StreamingToolExecutor 管理并行执行
      executor.execute(chunk)
    }
    yield chunk  // 同时向上游输出
  }

  // Stage 5: 收集所有工具结果
  const toolResults = await executor.waitAll()

  // Stage 7: StopHooks (extractMemories, autoDream, ...)
  await executeStopHooks(context)

  // Stage 8: 如果有工具结果 → 递归继续
  if (toolResults.length > 0) {
    yield* queryLoop({ ...params, messages: [...messages, ...toolResults] })
  }
}
```

#### 依赖注入设计

```typescript
// deps.ts — 4 个核心 I/O 依赖，便于测试
type QueryDeps = {
  callModel:    (params) => AsyncStream    // API 调用
  microcompact: (msgs) => Message[]        // 消息压缩
  autocompact:  (msgs) => Message[]        // 全文摘要
  uuid:         () => string               // ID 生成
}
```

**科普例子**：把 Query Engine 想象成一个**交通指挥中心**。用户的每句话就像一辆车驶入高速公路：
1. **入口收费站**（消息预处理）：检查车辆合规、分配车道
2. **主干道**（API 调用）：车辆在路上行驶，沿途可能需要"停靠服务区"（工具调用）
3. **服务区并行服务**（流式执行）：不用等所有车到齐，每辆车到服务区就立刻服务
4. **拥堵处理**（错误恢复）：路堵了（413）就开辟应急车道（Compact）；出口太窄（MaxOutput）就拓宽（8K→64K）
5. **计费系统**（Token 预算）：总里程费不能超预算，连续3轮跑不动（收益递减）就自动熄火

---

## 三、系统全局链路总览

```
┌──────────────────────────────────────────────────────────────────────┐
│                       Claude Code 完整链路                            │
│                                                                       │
│  用户 ──▶ CLI ──▶ QueryEngine ──▶ query() 循环 ──▶ Claude API        │
│                                       │                               │
│                                       ├──▶ Tool System (43 工具)      │
│                                       │    ├── Bash / FileEdit / Grep  │
│                                       │    ├── MCP / LSP / WebSearch   │
│                                       │    └── Agent (→ Coordinator)   │
│                                       │                               │
│                                       ├──▶ StopHooks (每轮结束)        │
│                                       │    ├── extractMemories         │
│                                       │    ├── autoDream               │
│                                       │    └── promptSuggestion        │
│                                       │                               │
│                                       ├──▶ Memory System              │
│                                       │    ├── MEMORY.md (索引)        │
│                                       │    ├── topic files (详情)      │
│                                       │    ├── team/ (团队共享)        │
│                                       │    └── logs/ (KAIROS 日志)     │
│                                       │                               │
│                                       ├──▶ Anti-Distillation          │
│                                       │    ├── Connector Text          │
│                                       │    ├── Fake Tools              │
│                                       │    └── Streamlined Output      │
│                                       │                               │
│                                       └──▶ React/Ink UI               │
│                                            ├── 146 Components          │
│                                            ├── Buddy Sprite            │
│                                            └── Coordinator Panel       │
│                                                                       │
│  ──────────────── 特殊模式 ────────────────                           │
│                                                                       │
│  KAIROS 模式: Bridge(WebSocket) ──▶ 永驻会话 ──▶ Brief Tool ──▶ 用户  │
│  Coordinator:  主 Agent ──▶ 派遣 Workers ──▶ Notification ──▶ 综合    │
│  Dream:        StopHook ──▶ 3重门控 ──▶ Fork Agent ──▶ 4阶段整合      │
│  Buddy:        userId Hash ──▶ Mulberry32 ──▶ 宠物生成 ──▶ ASCII 渲染  │
│                                                                       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 四、总结

| 模块 | 核心思想 | 关键技术 |
|------|---------|---------|
| **KAIROS** | AI 从"临时工"变"驻场员" | 会话持久化、Bridge WebSocket、崩溃恢复指针 |
| **Buddy** | 确定性抽卡系统 | Mulberry32 PRNG、FNV-1a Hash、Bones 不持久化 |
| **Anti-Distillation** | 三层防护防模型窃取 | Connector Text 签名、Fake Tools 注入、输出脱敏 |
| **Dream Engine** | "睡眠整理"记忆 | 4阶段整合、3重门控、进程锁+PID检测 |
| **autoDream** | Dream 的自动触发器 | GrowthBook 动态配置、10分钟扫描节流 |
| **记忆系统** | 跨会话持久知识 | 4种类型、Sonnet 智能检索、团队同步+密钥扫描 |
| **Coordinator** | 多 Agent 并行协作 | 4阶段工作流、Prompt Cache 优化、XML 通知 |
| **Query Engine** | 核心对话引擎 | 3级压缩、流式工具执行、多层错误恢复、Token 预算 |

这套代码展示了一个**生产级 AI 编程助手**的完整工程实践：从底层的查询循环和 Token 管理，到中层的记忆和多 Agent 协调，再到顶层的安全防护和用户体验（宠物系统），构成了一个精心设计、层次分明的系统。
