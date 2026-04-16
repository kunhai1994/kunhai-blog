# Claude Code 图片处理全链路解析

## 概览

当用户向 Claude Code 发送图片时，图片经历 **输入 → 压缩/缩放 → 编码 → 存储 → API 发送 → 后续轮次处理** 的完整链路。本文档基于源码深度分析每个阶段的实现。

---

## 一、全链路总览图

```
用户发送图片
  │
  │  来源: 粘贴剪贴板 / 拖拽文件 / Read tool 读取 / @附件
  │
  ▼
┌─────────────────────────────────────────────────────────────┐
│                  阶段 1: 图片输入                            │
│                                                             │
│  剪贴板 → getImageFromClipboard()                           │
│    macOS 快速路径: NSPasteboard native reader (~5ms)         │
│    回退路径: osascript (~1.5s)                              │
│                                                             │
│  文件路径 → tryReadImageFromPath()                           │
│    支持: .png .jpg .jpeg .gif .webp                         │
│    BMP → 自动转 PNG (API 不支持 BMP)                        │
│                                                             │
│  Read tool → readImageWithTokenBudget()                     │
│    通过 magic bytes 检测格式, 不信任文件扩展名               │
│                                                             │
│  输出: Buffer + media_type                                  │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                  阶段 2: 压缩 & 缩放                         │
│                                                             │
│  maybeResizeAndDownsampleImageBuffer()                      │
│  (imageResizer.ts, 核心 ~400 行)                            │
│                                                             │
│  详见下方 "压缩策略" 章节                                    │
│                                                             │
│  输出: 压缩后的 Buffer + media_type + dimensions            │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                  阶段 3: 编码为 ContentBlock                 │
│                                                             │
│  {                                                          │
│    type: 'image',                                           │
│    source: {                                                │
│      type: 'base64',                                        │
│      media_type: 'image/png' | 'image/jpeg' | ...,         │
│      data: '<base64 字符串>'                                │
│    }                                                        │
│  }                                                          │
│                                                             │
│  + 可选的 metadata 文本块:                                   │
│  "[Image: source: foo.png, original 4000x3000,              │
│   displayed at 2000x1500. Multiply coordinates              │
│   by 2.00 to map to original image.]"                       │
│                                                             │
└───────────┬─────────────────────────┬───────────────────────┘
            │                         │
            ▼                         ▼
┌─────────────────────┐   ┌──────────────────────────────────┐
│ 阶段 4a: 磁盘存储    │   │ 阶段 4b: API 发送前校验           │
│                     │   │                                  │
│ imageStore.ts       │   │ validateImagesForAPI()            │
│                     │   │                                  │
│ 路径:               │   │ 遍历所有 user messages             │
│ ~/.claude/          │   │ 检查每个 image block 的            │
│   image-cache/      │   │ base64 data.length ≤ 5MB          │
│     {sessionId}/    │   │                                  │
│       {id}.{ext}    │   │ 超限 → throw ImageSizeError       │
│                     │   │ (安全网, 正常不应触发)             │
│ 内存缓存:           │   │                                  │
│ Map<id, path>       │   └──────────────────────────────────┘
│ 最多 200 条, LRU    │
│                     │
│ 会话结束后清理       │
│ 旧 session 的缓存   │
└─────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────┐
│                  阶段 5: 对话中的图片生命周期                  │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ 正常对话轮次 (未触发压缩)                             │    │
│  │                                                     │    │
│  │ 图片原样保留在 messages 数组中                        │    │
│  │ 每次 API 调用都带上完整 base64                        │    │
│  │ (即: 图片每轮都重新发送给 LLM)                        │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ 触发 Compact (上下文压缩) 时                          │    │
│  │                                                     │    │
│  │ stripImagesFromMessages() 将图片替换为:               │    │
│  │   { type: 'text', text: '[image]' }                  │    │
│  │                                                     │    │
│  │ 压缩后: 图片永久丢失, 只剩文字摘要                    │    │
│  │ LLM 后续只能看到 summary 中 "用户曾发送图片" 的描述   │    │
│  └─────────────────────────────────────────────────────┘    │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐    │
│  │ 触发 Media Recovery (API 报错图片太大) 时              │    │
│  │                                                     │    │
│  │ reactive compact 介入:                               │    │
│  │ strip 图片 → 重试 API 调用                            │    │
│  │ 避免因单张大图导致整个对话失败                         │    │
│  └─────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## 二、硬性约束 (API Limits)

```
常量定义: src/constants/apiLimits.ts

┌──────────────────────────────┬──────────┬──────────────────────────┐
│ 常量                         │ 值       │ 说明                     │
├──────────────────────────────┼──────────┼──────────────────────────┤
│ API_IMAGE_MAX_BASE64_SIZE    │ 5 MB     │ base64 编码后的字符串长度 │
│ IMAGE_TARGET_RAW_SIZE        │ 3.75 MB  │ 原始字节 (5MB × 3/4)    │
│ IMAGE_MAX_WIDTH              │ 2000 px  │ 最大宽度                 │
│ IMAGE_MAX_HEIGHT             │ 2000 px  │ 最大高度                 │
│ API_MAX_MEDIA_PER_REQUEST    │ 100      │ 单次请求最多图片+PDF数    │
└──────────────────────────────┴──────────┴──────────────────────────┘

关系: 原始 3.75MB × base64 膨胀系数 4/3 ≈ 5MB
所以代码用 3.75MB 作为压缩目标, 保证编码后不超 5MB
```

---

## 三、压缩策略详解

### 3.1 入口判断

```
maybeResizeAndDownsampleImageBuffer(imageBuffer, originalSize, ext)
                    │
                    ▼
           ┌───────────────────────────────┐
           │ 原始大小 ≤ 3.75MB             │
           │ AND 宽度 ≤ 2000px             │
           │ AND 高度 ≤ 2000px ?           │
           └───────┬───────────┬───────────┘
                  YES         NO
                   │           │
                   ▼           ▼
            直接返回原图    进入压缩流程
```

### 3.2 压缩流程 (阶段式降级)

```
Stage 1: 尺寸不超标, 但体积太大
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    PNG 图片?
    ├─ YES → 先试 PNG 压缩 (compressionLevel=9, palette=true)
    │        ≤ 3.75MB? → 返回 ✅ (保留透明通道)
    │
    └─ 降级为 JPEG, 逐步降低 quality:
         quality=80 → ≤ 3.75MB? → 返回 ✅
         quality=60 → ≤ 3.75MB? → 返回 ✅
         quality=40 → ≤ 3.75MB? → 返回 ✅
         quality=20 → ≤ 3.75MB? → 返回 ✅
         全都不行 → 进入 Stage 2


Stage 2: 缩小尺寸
━━━━━━━━━━━━━━━━━

    constrain to 2000x2000 (保持宽高比)
    │
    ▼
    缩放后 ≤ 3.75MB? → 返回 ✅
    │
    ▼ 还是太大
    │
    PNG? → 试 PNG 压缩 (缩放后的尺寸) → ≤ 3.75MB? → 返回 ✅
    │
    ▼
    JPEG 逐步降 quality (80→60→40→20) → ≤ 3.75MB? → 返回 ✅


Stage 3: 暴力压缩 (最后手段)
━━━━━━━━━━━━━━━━━━━━━━━━━━━

    缩小到 1000px 宽度
    │
    ▼
    JPEG quality=20 → 返回 (不再检查大小)


失败兜底: sharp 库出错时
━━━━━━━━━━━━━━━━━━━━━━━

    检测 magic bytes 确定真实格式
    │
    ├─ base64 编码后 ≤ 5MB 且尺寸不超标? → 返回原图 (未压缩)
    │
    └─ 超限 → throw ImageResizeError (用户友好的错误提示)
```

### 3.3 用于 FileReadTool 的另一套压缩 (compressImageBuffer)

当 Read tool 读取图片文件时, 使用更激进的多阶段压缩:

```
compressImageBuffer(imageBuffer, maxBytes)
    │
    ▼
┌─ 阶段 1: 渐进式缩放 (保持原格式)
│    缩放因子: 100% → 75% → 50% → 25%
│    每步都带格式特定优化:
│      PNG:  compressionLevel=9, palette=true
│      JPEG: quality=80
│      WebP: quality=80
│
├─ 阶段 2: PNG 调色板优化 (仅 PNG)
│    缩放到 800x800, palette=true, colors=64
│
├─ 阶段 3: JPEG 转换
│    缩放到 600x600, quality=50
│
└─ 阶段 4: 极限 JPEG
     缩放到 400x400, quality=20
     (终极手段, 不再判断大小, 直接返回)
```

---

## 四、格式检测: 不信任扩展名

```
detectImageFormatFromBuffer(buffer)

检查 magic bytes (文件头):

  89 50 4E 47          → image/png
  FF D8 FF             → image/jpeg
  47 49 46             → image/gif  (GIF87a 或 GIF89a)
  52 49 46 46 ... WEBP → image/webp (RIFF....WEBP)
  其他                  → 默认 image/png

为什么不用扩展名:
  - 用户可能重命名文件 (screenshot.jpg 实际上是 PNG)
  - 剪贴板粘贴没有扩展名
  - BMP 文件需要先转 PNG, 不能按扩展名处理
```

---

## 五、图片存储系统 (imageStore.ts)

```
┌─────────────────────────────────────────────────────────┐
│                图片存储架构                               │
│                                                         │
│  ~/.claude/image-cache/                                 │
│  └── {sessionId}/          ← 按会话隔离                  │
│      ├── 1.png                                          │
│      ├── 2.jpeg                                         │
│      └── 3.webp                                         │
│                                                         │
│  内存层: Map<imageId, filePath>                          │
│  ├── 最多 200 条 (LRU 淘汰最旧的)                       │
│  ├── cacheImagePath(): 纯内存, 无 I/O, 快速             │
│  └── storeImage(): 写磁盘, 权限 0o600 + datasync        │
│                                                         │
│  生命周期:                                               │
│  ├── 会话启动 → cleanupOldImageCaches()                  │
│  │   删除所有非当前 sessionId 的目录                      │
│  ├── 会话进行中 → 按需写入                               │
│  └── 会话结束 → 下次启动时被清理                          │
│                                                         │
│  注意: 这是磁盘备份, 不是 LLM 的上下文缓存              │
│  图片在 messages 数组中仍然是 base64 内联形式            │
└─────────────────────────────────────────────────────────┘
```

**与 FileStateCache 的区别:**

```
FileStateCache (文本文件缓存):
  ├── LRU Cache, 100 条, 25MB 上限
  ├── 缓存 content + timestamp
  ├── 用于编辑冲突检测 (mtime 比较)
  └── 注释明确写着: "Images are not cached"

imageStore (图片磁盘缓存):
  ├── 按 session 隔离的磁盘目录
  ├── 内存索引 200 条上限
  ├── 仅用于持久化引用, 不参与冲突检测
  └── 图片文件不进 FileStateCache
```

---

## 六、后续轮次中图片怎么处理？

这是最关键的问题。答案分两种情况:

### 6.1 未触发 Compact: 图片每轮都发

```
Turn 1: 用户发送 [文字 + 图片A + 图片B]
                    │
                    ▼
         messages = [ UserMsg(text + imageA + imageB) ]
                    │
Turn 2:  LLM 回复, 用户追问
                    │
                    ▼
         messages = [ UserMsg(text + imageA + imageB),  ← 图片还在!
                      AssistantMsg(...),
                      UserMsg("继续") ]
                    │
Turn 3:  又一轮
                    │
                    ▼
         messages = [ UserMsg(text + imageA + imageB),  ← 图片还在!
                      AssistantMsg(...),
                      UserMsg("继续"),
                      AssistantMsg(...),
                      UserMsg("好的") ]
                    │
                    ▼
         整个 messages 数组发给 API
         图片的 base64 每次都在请求中重新传输
         ↓
         token 计费: 每张图按 (width×height)/750 计算
         估算常量: ~2000 tokens/张 (用于上下文预算)
```

**图片不会被转成文本。在 compact 之前, 它们始终以 base64 形式存在于 messages 中, 每轮 API 调用都完整发送。**

### 6.2 触发 Compact: 图片永久丢失

```
上下文窗口快满了 → 触发 autoCompact / reactiveCompact
                    │
                    ▼
         stripImagesFromMessages(messages)
                    │
                    ▼
         所有 image block 被替换为:
         { type: 'text', text: '[image]' }
                    │
                    ▼
         替换后的消息发给 compact API 生成摘要:
         "用户之前发送了一张截图显示了..."
                    │
                    ▼
         compact 完成后, 原始消息被摘要取代
         图片的 base64 数据从 messages 中永久移除
                    │
         后续轮次: LLM 只能看到 summary 中的文字描述
                    无法再 "看到" 原始图片
```

compact.ts 注释 (line 134-139):
```
Strip image blocks from user messages before sending for compaction.
Images are not needed for generating a conversation summary and can
cause the compaction API call itself to hit the prompt-too-long limit,
especially in CCD sessions where users frequently attach images.
```

### 6.3 Media Recovery: API 报错时的应急

```
API 返回 media-size error (图片太大/太多)
                    │
                    ▼
reactiveCompact 介入:
  isWithheldMediaSizeError(message) === true
                    │
                    ▼
  strip 图片 → 触发 compact → 重试 API 调用
  (避免因图片问题导致整个对话卡死)
                    │
  如果 strip 后仍然失败:
  hasAttemptedReactiveCompact 标记防止无限循环
  错误上浮给用户
```

---

## 七、Token 估算

```
图片在上下文预算计算中的权重:

┌───────────────────────────┬───────────────────────────────┐
│ 场景                      │ 估算公式                       │
├───────────────────────────┼───────────────────────────────┤
│ API 实际计费              │ (width × height) / 750 tokens │
│ microCompact 预算计算     │ 固定 2000 tokens/张            │
│ tokenEstimation 预算计算  │ 固定 2000 tokens/张            │
│ MCP tool 图片估算         │ 固定 1600 tokens/张            │
│ 理论最大 (2000x2000)     │ 5333 tokens                   │
└───────────────────────────┴───────────────────────────────┘

为什么用保守固定值 (2000) 而不是精确计算:
  代码注释: "Use a conservative estimate that matches
  microCompact's IMAGE_MAX_TOKEN_SIZE to avoid underestimating
  and triggering auto-compact too late."

  即: 宁可高估图片 token, 也不要低估导致上下文溢出
```

---

## 八、图片相关的特殊处理

### 8.1 BMP 自动转换

```
BMP 文件 (Windows 剪贴板默认格式, WSL2 常见)
    │
    ▼
API 不支持 BMP → 自动通过 sharp 转为 PNG
    │
    ▼
imagePaste.ts:
  if (ext === 'bmp') {
    const sharp = await getImageProcessor()
    buffer = await sharp(buffer).png().toBuffer()
    mediaType = 'image/png'
  }
```

### 8.2 坐标映射 (Computer Use 场景)

```
如果图片被缩放了 (originalWidth !== displayWidth):

createImageMetadataText() 生成:
"[Image: source: screenshot.png,
  original 4000x3000, displayed at 2000x1500.
  Multiply coordinates by 2.00 to map to original image.]"

这让 LLM 在 computer-use 任务中能正确映射
从缩放后图片上的坐标 → 原始屏幕上的坐标
```

### 8.3 sharp 库的使用注意

```
关键 bug 防护 (imageResizer.ts:288-291 注释):

"IMPORTANT: Always create fresh sharp(imageBuffer) instances
 for each operation. The native image-processor-napi module
 doesn't properly apply format conversions when reusing a
 sharp instance after calling toBuffer()."

即: 每次压缩尝试都 new 一个 sharp 实例
    不能复用, 否则 PNG→JPEG 转换会失败
    (所有压缩结果返回一样的大小)
```

---

## 九、关键源码位置

| 模块 | 文件 | 核心行号 |
|------|------|---------|
| 图片压缩/缩放主逻辑 | `src/utils/imageResizer.ts` | 169-432 |
| 渐进式压缩 (Read tool 用) | `src/utils/imageResizer.ts` | 498-577 |
| 极限压缩阶段 | `src/utils/imageResizer.ts` | 646-762 |
| 格式检测 (magic bytes) | `src/utils/imageResizer.ts` | 769-812 |
| 坐标映射元数据 | `src/utils/imageResizer.ts` | 835-880 |
| 磁盘存储 | `src/utils/imageStore.ts` | 1-168 |
| API 校验安全网 | `src/utils/imageValidation.ts` | 65-104 |
| 剪贴板读取 | `src/utils/imagePaste.ts` | 86-417 |
| Compact 时 strip 图片 | `src/services/compact/compact.ts` | 133-200 |
| Compact 调用 strip | `src/services/compact/compact.ts` | 1293-1294 |
| Token 估算 (图片=2000) | `src/services/compact/microCompact.ts` | 147-157 |
| Token 估算 (API 层) | `src/services/tokenEstimation.ts` | 400-412 |
| API 限制常量 | `src/constants/apiLimits.ts` | 22-94 |
| Media Recovery | `src/query.ts` | 1074-1084 |
| Native 图片处理器 | `src/tools/FileReadTool/imageProcessor.ts` | 1-94 |

---

## 十、一句话总结

图片以 **base64 内联** 形式存在于 messages 中，经过 **sharp 库多阶段压缩** 确保不超 API 限制 (3.75MB/2000px)。在 compact 之前，**每轮对话都完整重发**给 LLM (不转文本、不缓存引用)；一旦触发 compact，图片被 **永久替换为 `[image]` 文本标记**，LLM 从此只能看到摘要中的文字描述，原始图片数据不可恢复。
