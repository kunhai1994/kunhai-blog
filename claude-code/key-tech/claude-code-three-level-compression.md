# Claude Code 三级消息压缩系统详解

## Snip → Microcompact → Autocompact

Claude 的上下文窗口是有限的（比如 200K token）。随着对话越来越长、工具调用越来越多，token 会迅速膨胀。三级压缩系统的目标是：**让超长对话在有限窗口内存活，永不断档**。

---

## 总览：三级压缩管线

每轮 query 循环入口，压缩管线按成本递增顺序依次执行:

```
messages[] (原始对话，可能 150K+ tokens)
     │
     ▼
┌─────────────────────────────────────────────────────────────────┐
│  Level 1: Snip Compact                                          │
│  成本: 0 (纯内存操作，无 API 调用)                                │
│  策略: 直接删除最老的消息对                                       │
│  触发: 每轮都执行                                                │
│  效果: 粗暴但免费，快速腾出空间                                   │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Level 2: Microcompact                                          │
│  成本: 0 (替换文本 / 缓存编辑，无 API 调用)                       │
│  策略: 压缩旧轮次的工具输入输出，保留最近的                        │
│  触发: 每轮都执行                                                │
│  效果: 工具输出是 token 大户，压缩它们性价比极高                   │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  Level 3: Autocompact                                           │
│  成本: ~1 次 Haiku API 调用 (约 $0.001-0.01)                     │
│  策略: 用小模型对全文做摘要，替换整个对话历史                       │
│  触发: token 用量超过 ~87% 上下文窗口时                           │
│  效果: 把 150K 对话压缩到 20-40K 的精炼摘要                       │
└────────────────────────────┬────────────────────────────────────┘
                             │
                             ▼
                    压缩后的 messages[]
                    (送入 Claude API)
```

---

## Level 1: Snip Compact — "直接扔掉最老的"

### 原理

对话最开始的几轮通常已经不重要了，直接删掉。

### 压缩示意

```
压缩前 (8 轮对话):
┌──────────────────────────────────────────────────────┐
│ [Turn 1] User: 帮我看看项目结构                        │ ← 很老了
│ [Turn 1] Asst: 项目结构如下...                         │ ← 很老了
│ [Turn 2] User: 这个函数是干什么的                       │ ← 较老
│ [Turn 2] Asst: 这个函数的作用是...                      │ ← 较老
│ [Turn 3] User: 有个 bug，帮我修                        │
│ [Turn 3] Asst: 我来看看... tool_use: Read a.ts         │
│ [Turn 4] User: [tool_result: a.ts 的内容]              │
│ [Turn 4] Asst: 找到问题了... tool_use: Edit a.ts       │
│ ...后续轮次...                                         │
│ [Turn 8] Asst: ← 最后一个 assistant (受保护的尾部)      │
└──────────────────────────────────────────────────────┘

Snip 执行后:
┌──────────────────────────────────────────────────────┐
│ ██████████ (Turn 1-2 被删除) ██████████               │
│ [Turn 3] User: 有个 bug，帮我修                        │ ← 保留
│ [Turn 3] Asst: 我来看看... tool_use: Read a.ts         │
│ ...后续轮次保持不变...                                  │
│ [Turn 8] Asst: ← 受保护，永远不删                      │
└──────────────────────────────────────────────────────┘
```

### 关键规则

- 总是成对删除（User + Assistant），保持消息交替格式
- **永远不删最后一个 assistant 消息**（"受保护的尾部"），因为它包含当前上下文的 token usage 信息
- 零成本——纯 `Array.slice()`，不调任何 API

---

## Level 2: Microcompact — "压缩工具的废话"

这是最精巧的一级。工具输出是 token 消耗的大户——一次 `Read` 一个 500 行文件就是几千 token，一次 `Bash` 跑测试输出几百行也是上千 token。但这些**旧轮次的工具输出对当前决策价值很低**。

### 哪些工具会被压缩

```typescript
// microCompact.ts
const COMPACTABLE_TOOLS = new Set([
  'Read',           // 读文件输出
  'Bash',           // shell 命令输出
  'Grep',           // 搜索结果
  'Glob',           // 文件匹配结果
  'WebSearch',      // 网页搜索结果
  'WebFetch',       // 网页抓取结果
  'Edit',           // 编辑结果
  'Write',          // 写文件结果
])
```

### 压缩路径 A：缓存编辑模式（Cached Microcompact）

不改消息内容，通过 API 的 `cache_edits` 指令让服务端删除。

```
原理: Anthropic API 支持 cache_edits 操作，可以在不改变本地消息的情况下
让服务端缓存中删除指定 tool_result 的内容

messages 本地保持不变（缓存 key 不变 → 命中率高）
只是在 API 请求中附加:
{
  cache_edits: [
    { type: "delete", tool_use_id: "toolu_01abc..." },
    { type: "delete", tool_use_id: "toolu_02def..." },
  ]
}

服务端收到后:
- 在缓存中标记这些 tool_result 为已删除
- 后续请求不再为这些内容计费
- 但缓存前缀保持不变 → 缓存命中率不受影响！
```

### 压缩路径 B：时间触发模式（Time-Based MC）

直接替换旧内容。

```
触发条件: 距离上次 assistant 回复超过 60 分钟
原因: 服务端缓存 TTL 是 1 小时，缓存已经过期了，改内容也不会影响命中率
```

### 压缩示例

```
压缩前:
┌─────────────────────────────────────────────────────────────┐
│ [Turn 1] Asst: tool_use: Read("package.json")               │
│ [Turn 1] User: tool_result: {                                │
│                  "name": "my-project",                       │
│                  "version": "1.0.0",                         │
│                  "dependencies": {                            │  ← 2000 tokens
│                    "react": "^18.2.0",                       │
│                    "typescript": "^5.0.0",                   │
│                    ...200 行 JSON...                          │
│                  }                                            │
│                }                                             │
│ [Turn 2] Asst: tool_use: Bash("npm test")                    │
│ [Turn 2] User: tool_result:                                  │
│                PASS src/App.test.tsx                          │
│                PASS src/utils.test.tsx                        │  ← 1500 tokens
│                ...50 行测试输出...                              │
│                Tests: 42 passed, 42 total                     │
│ [Turn 3] Asst: tool_use: Read("src/bug.ts")                  │
│ [Turn 3] User: tool_result: ...当前正在分析的文件...           │  ← 保留！
└─────────────────────────────────────────────────────────────┘

压缩后 (保留最近 N 个, 清除更早的):
┌─────────────────────────────────────────────────────────────┐
│ [Turn 1] Asst: tool_use: Read("package.json")               │
│ [Turn 1] User: tool_result:                                  │
│                [Old tool result content cleared]              │  ← 2000→7 tokens!
│ [Turn 2] Asst: tool_use: Bash("npm test")                    │
│ [Turn 2] User: tool_result:                                  │
│                [Old tool result content cleared]              │  ← 1500→7 tokens!
│ [Turn 3] Asst: tool_use: Read("src/bug.ts")                  │
│ [Turn 3] User: tool_result: ...当前正在分析的文件...           │  ← 保留不动
└─────────────────────────────────────────────────────────────┘

节省: ~3500 tokens, 成本: 0
```

### 为什么可以这样压缩？

```
模型在 Turn 3 做决策时:
- Turn 1 的 package.json 具体内容？ → 不重要了，模型已经在 Turn 1 读过并做了决策
- Turn 2 的测试输出详情？ → 不重要了，模型已经知道测试通过了
- Turn 3 的文件内容？ → 正在用！必须保留

关键洞察: tool_use block 本身保留（"我读了 package.json"），
只删 tool_result 内容（"package.json 里具体写了什么"）。
模型仍然知道自己做过什么，只是忘了具体看到了什么。
```

---

## Level 3: Autocompact — "用 AI 摘要整个对话"

当 Level 1 + 2 都不够用，token 仍然超过阈值时，出动终极武器——**用 Haiku（小模型）对整个对话做摘要**。

### 触发条件

```
上下文窗口 (例如 200K tokens)
┌────────────────────────────────────────────────────────────┐
│████████████████████████████████████████████░░░░░░░░░░░░░░░│
│◀──────── 已使用 tokens ────────▶│◀── 剩余 ──▶│
│                                  │                         │
│  Autocompact 阈值 = 窗口大小 - 预留输出(20K) - 缓冲(13K)   │
│                                                            │
│  200K 窗口:  阈值 ≈ 167K (约 83.5%)                        │
│  触发: 已使用 > 167K → 开始 autocompact                    │
│                                                            │
│  如果 3 次连续 compact 都失败 → 熔断，不再重试               │
│  (防止无限循环浪费 API 调用)                                 │
└────────────────────────────────────────────────────────────┘
```

### 压缩过程

```
Step 1: 构建摘要提示词
┌────────────────────────────────────────────────────┐
│  系统提示: "你的任务是创建对话的详细摘要..."          │
│                                                    │
│  要求覆盖 9 个维度:                                 │
│  1. 用户的主要请求和意图                             │
│  2. 关键技术概念                                    │
│  3. 涉及的文件和代码片段                             │
│  4. 遇到的错误和修复方式                             │
│  5. 问题解决过程                                    │
│  6. 所有用户消息 (非工具结果)                         │
│  7. 待完成任务                                      │
│  8. 当前正在做的工作 (最重要!)                        │
│  9. 建议的下一步                                    │
│                                                    │
│  先输出 <analysis> 思考过程                          │
│  再输出 <summary> 最终摘要                           │
│  (analysis 会被丢弃，只保留 summary)                 │
└────────────────────────────────────────────────────┘
        │
        ▼ 调用 Haiku (runForkedAgent, maxTurns: 1)
        │
        ▼
Step 2: 收到摘要结果

Step 3: 重建上下文
┌────────────────────────────────────────────────────┐
│  压缩后的 messages 结构:                             │
│                                                    │
│  [CompactBoundaryMessage]  ← 标记"这里发生过压缩"    │
│  [SystemMessage: 摘要内容]  ← Haiku 生成的摘要       │
│  [附件: 相关记忆文件]                                │
│  [附件: 最近修改的文件内容 (≤5个, 每个≤5K tokens)]    │
│  [附件: MCP 工具说明增量]                            │
│  [附件: Agent 列表增量]                              │
│  [附件: 活跃 Skill 说明]                             │
│  [附件: 当前 Plan 内容]                              │
└────────────────────────────────────────────────────┘
```

### 完整示例

```
压缩前 (167K tokens, 40 轮对话):
┌──────────────────────────────────────────────────────┐
│ [Turn 1]  User: 帮我搭建一个 React 项目               │
│ [Turn 1]  Asst: 好的，我来... Read package.json       │
│ [Turn 2]  User: tool_result: {...}                    │
│ [Turn 2]  Asst: 我看到了... Bash: npm init            │
│ [Turn 3]  User: tool_result: 初始化成功               │
│ ...                                                   │
│ [Turn 20] User: 现在帮我加个登录页面                    │
│ [Turn 20] Asst: Read src/App.tsx                      │
│ ...                                                   │
│ [Turn 38] User: 登录功能有 bug，提交后没反应            │
│ [Turn 38] Asst: 我来调试... Read src/Login.tsx        │
│ [Turn 39] User: tool_result: ...Login.tsx 内容...      │
│ [Turn 39] Asst: 找到了! onClick 没有 await...          │
│ [Turn 40] User: tool_result: 编辑成功                  │
│ [Turn 40] Asst: 已修复，帮你跑下测试... Bash: npm test │
└──────────────────────────────────────────────────────┘
         │
         ▼  Haiku 摘要 (约 1 秒, 花费约 $0.005)
         │
         ▼
压缩后 (~25K tokens):
┌──────────────────────────────────────────────────────┐
│ [CompactBoundary: 对话已压缩]                         │
│                                                      │
│ [Summary]:                                           │
│  1. 主要请求: 用户要求搭建 React 项目并实现登录功能     │
│  2. 技术栈: React 18, TypeScript, React Router        │
│  3. 文件:                                            │
│     - src/App.tsx: 主入口，配置了路由                   │
│     - src/Login.tsx: 登录组件，有 onClick bug          │
│     - src/api/auth.ts: 认证 API 调用                  │
│  4. 错误: Login.tsx 的 handleSubmit 缺少 await        │
│     用户反馈: "提交后没反应" → 已修复 async/await       │
│  5. 当前工作: 刚修复登录 bug，正在跑测试               │
│  6. 下一步: 等待测试结果，如果通过则完成                │
│                                                      │
│ [附件: src/Login.tsx 最新内容 (5K tokens)]             │
│ [附件: src/App.tsx 最新内容 (3K tokens)]               │
│ [附件: 记忆文件 (项目上下文)]                           │
└──────────────────────────────────────────────────────┘

167K → 25K, 压缩率 85%, 对话可以继续!
```

### Autocompact 摘要提示词的 9 个维度

摘要生成时，提示词要求 Haiku 覆盖以下维度（源码 `prompt.ts`）：

| 维度 | 内容 | 重要性 |
|------|------|--------|
| 1. Primary Request and Intent | 用户所有明确请求和意图 | 核心 |
| 2. Key Technical Concepts | 技术概念、框架、依赖 | 高 |
| 3. Files and Code Sections | 涉及的文件、代码片段、修改记录 | 高 |
| 4. Errors and Fixes | 遇到的错误、修复方式、用户反馈 | 高 |
| 5. Problem Solving | 解决问题的过程、调试思路 | 中 |
| 6. All User Messages | 所有非工具结果的用户消息 | 高 |
| 7. Pending Tasks | 明确被要求但尚未完成的任务 | 高 |
| 8. Current Work | 压缩前正在做什么（最重要！） | 核心 |
| 9. Optional Next Step | 建议的下一步（需与用户最近请求一致） | 中 |

---

## 三级联动：一次完整的压缩链路

```
一个真实场景: 用户和 Claude 已经对话 50 轮, tokens 快满了

                    消息数组 (175K tokens, 超过 167K 阈值)
                              │
                              ▼
┌─ Level 1: Snip ────────────────────────────────────────────────┐
│                                                                │
│  扫描消息，发现 Turn 1-5 非常老了                                │
│  删除 Turn 1-5 的 User+Assistant 对 (约 8K tokens)              │
│                                                                │
│  结果: 175K → 167K  (还是超阈值...)                              │
└────────────────────────────┬───────────────────────────────────┘
                             │
                             ▼
┌─ Level 2: Microcompact ───────────────────────────────────────┐
│                                                                │
│  扫描剩余消息中的 tool_result blocks                            │
│  找到 28 个可压缩的工具结果 (Read/Bash/Grep/Glob)               │
│  保留最近 5 个，压缩其余 23 个                                   │
│                                                                │
│  23 个 tool_result 替换为 "[Old tool result content cleared]"   │
│  节省约 45K tokens                                              │
│                                                                │
│  结果: 167K → 122K  (低于 167K 阈值，autocompact 不触发!)       │
└────────────────────────────┬───────────────────────────────────┘
                             │
                             ▼
┌─ Level 3: Autocompact ────────────────────────────────────────┐
│                                                                │
│  shouldAutoCompact(): 122K < 167K → false                      │
│                                                                │
│  跳过! 不需要花钱调 Haiku                                       │
│                                                                │
│  结果: 122K tokens 直接送入 Claude API                          │
└───────────────────────────────────────────────────────────────┘

如果 Microcompact 之后仍然 > 167K:
┌─ Level 3: Autocompact ────────────────────────────────────────┐
│                                                                │
│  shouldAutoCompact(): 170K > 167K → true!                      │
│                                                                │
│  调用 Haiku 生成摘要 → 170K 压缩到 ~25K                         │
│  重建上下文 (附件 + 记忆 + Plan)                                 │
│                                                                │
│  结果: ~30K tokens 送入 Claude API                              │
└───────────────────────────────────────────────────────────────┘
```

---

## 兜底机制：413 时的紧急压缩

如果三级压缩都跑了，消息还是太长（API 返回 413 Prompt-Too-Long），还有两个紧急机制：

```
正常的三级压缩管线执行完毕
        │
        ▼
调用 Claude API
        │
        ▼ 返回 413 Prompt-Too-Long!
        │
┌───────┴──────────────────────────────────────────┐
│  兜底 1: Context Collapse Drain                   │
│  把之前暂存（staged）的消息组折叠提交              │
│  成本: 0 (纯内存操作)                             │
│  如果空间够了 → 重试 API 调用                     │
└───────┬──────────────────────────────────────────┘
        │ 还是 413?
        ▼
┌───────┴──────────────────────────────────────────┐
│  兜底 2: Reactive Compact                         │
│  紧急调用 Haiku 做全文摘要 (和 Autocompact 类似)  │
│  但这次是被动的——已经 413 了才触发                 │
│  成本: ~1 次 Haiku API 调用                       │
│  摘要完成 → 重试 API 调用                         │
└───────┬──────────────────────────────────────────┘
        │ 还是失败?
        ▼
     报错退出 (return { reason: 'prompt_too_long' })
```

---

## 总结对比

| 级别 | 名称 | 触发条件 | API 成本 | 压缩方式 | 信息损失 |
|------|------|---------|---------|---------|---------|
| **L1** | Snip | 每轮 | **0** | 删除最老消息对 | 高（直接丢弃） |
| **L2** | Microcompact | 每轮 | **0** | 替换旧工具输出为占位符 | 低（保留工具调用记录） |
| **L3** | Autocompact | token > ~87% | **~$0.005** | Haiku 全文摘要 | 中（摘要有信息压缩损失） |
| 兜底1 | Context Collapse | API 413 | **0** | 提交暂存折叠 | 低 |
| 兜底2 | Reactive Compact | API 413 | **~$0.005** | 紧急 Haiku 摘要 | 中 |

---

## 设计哲学

> 先做免费的（Snip、Micro），不够再花小钱（Auto），实在不行紧急兜底（Reactive）。成本递增，信息保留递减——用最小代价保证对话永远不会因为上下文溢出而中断。

---

## 关键源码位置

| 模块 | 文件路径 | 核心函数 |
|------|---------|---------|
| Snip Compact | `services/compact/snipCompact.ts` | `snipCompactIfNeeded()` |
| Microcompact | `services/compact/microCompact.ts` | `microcompactMessages()` |
| Cached MC | `services/compact/cachedMicrocompact.ts` | `cachedMicrocompactPath()` |
| Time-Based MC | `services/compact/microCompact.ts` | `maybeTimeBasedMicrocompact()` |
| Autocompact | `services/compact/autoCompact.ts` | `autoCompactIfNeeded()` |
| 摘要生成 | `services/compact/compact.ts` | `compactConversation()` |
| 摘要提示词 | `services/compact/prompt.ts` | `getCompactPrompt()` |
| Reactive Compact | `services/compact/reactiveCompact.ts` | `tryReactiveCompact()` |
| Context Collapse | `services/contextCollapse/index.ts` | `applyCollapsesIfNeeded()` |
| 压缩管线入口 | `query.ts` | `queryLoop()` 的 Phase 1 |
| Token 预算 | `query/tokenBudget.ts` | `createBudgetTracker()` |
