# Command Code CLI v1.27.1 出站协议兼容设计

## 目标

在不移除 `commandcode-proxy` 现有 OpenAI/Anthropic 入站接口、服务器模式闸门、
key pool 和额度策略的前提下，把 proxy 做成两个明确边界之间的协议转换器：
下游继续提供 OpenAI/Anthropic 协议；所有实际发往 Command Code server 的请求，
严格遵循 `commandcode-cli-server-protocol-v1.27.1.md`。

“严格遵循”指上游请求的 route、method、headers、wire body、上下文字段、NDJSON
framing、终止事件和错误状态机与 CLI v1.27.1 一致。下游格式转换、key 轮换、
超时、日志属于 proxy 边界策略；它们不能改变发往上游的 CLI wire contract。

## 边界

### 下游边界（保留）

- 入站 `POST /v1/chat/completions`。
- 入站 `POST /v1/messages`。
- 入站 `GET /v1/models`、`/pool/usage`、`/pool/state` 和健康检查。
- server mode 的 bootstrap key gate。
- key pool、额度预检、冷却和单请求最多一次 failover。

### 上游边界（严格对齐）

- 所有 proxy 实际发出的 CLI 文档端点，包括 `/alpha/generate`、
  `/alpha/fingerprint/record`、`/alpha/lifecycle-events` 和
  `/alpha/billing/credits`，都使用 v1.27.1 的请求头、认证、JSON body 和错误
  语义。
- OpenAI/Anthropic 入站消息到 CC 自有消息块的归一化；转换后的 body 必须符合
  CLI 文档，不得把下游专有字段直接带入上游。
- `/alpha/generate` 的 NDJSON framing、事件状态机、continuation、终止和错误
  语义。
- proxy 的 `/provider/v1/models` 是当前实现的 proxy 扩展，不属于
  `commandcode-cli-server-protocol-v1.27.1.md`；它必须与主协议适配层隔离，
  不能被当作 CLI 原生协议的一部分，也不能影响 `/alpha/generate`。

### 本次不新增的能力

- 不新增当前 proxy 没有调用的 Taste、Share、Sandbox、Web Search/Web Fetch、
  agent 等 CLI 辅助端点；如果未来要让 CLI 直接把 proxy 当完整 `apiBase`，需另
  开任务覆盖这些路由。
- 不修改下游 OpenAI 或 Anthropic 的公开协议，只修复其到上游协议的转换。
- 更换 key pool 的轮换和额度策略。

## 出站身份和上下文

新增一个每请求协议上下文，概念字段如下：

```text
ProtocolContext {
  apiKey
  sessionId
  threadId
  mode
  environment
  cliVersion
  projectSlug
  tasteLearning
  coFlag
  optionalHeaders
  config
}
```

### 来源和默认值

- `apiKey`：沿用现有 server gate、请求 key、配置 key 和 key pool 选择逻辑。
- `sessionId`：优先使用入站 `x-session-id` 或
  `x-claude-code-session-id`，否则使用当前 key 的长期 session。
- `threadId`：优先使用合法入站 `x-thread-id`；没有时为当前入站请求生成一个
  UUID，并写入 `/alpha/generate` body。相同请求的 continuation 必须复用它。
- `mode`：使用入站 `x-command-code-mode`，没有时为 `interactive`。
- `environment`：由 `CC_API_BASE` 的主机和显式 `CC_API_ENV` 推导，默认
  `production`；不再固定为 production。
- `cliVersion`：默认 `1.27.1`，可由 `CC_CLI_VERSION` 覆盖；npm 动态刷新只
  用于模型展示或日志，不覆盖协议版本。
- `projectSlug`：优先入站 `x-project-slug`，否则配置 `projectSlug`，最后才
  使用确定性的 proxy slug；不再伪造与 session 绑定的 Windows 工作目录。
- `tasteLearning`：配置/环境值，默认 `true`，以字符串布尔值发送。
- `coFlag`：配置/环境值，默认 `false`，以字符串布尔值发送。
- 可选头从入站对应 header 或环境变量传入：`x-cmd-zdr`、
  `x-cmd-provider-deepseek-internal`、`x-oss-primary-provider`、
  `x-oauth-token`、`x-oauth-provider`。

### CLI 头集合

主生成和初始化请求使用同一组通用头：

```http
Content-Type: application/json
User-Agent: cli
Authorization: Bearer <apiKey>
x-cli-environment: production|staging|local
x-command-code-version: 1.27.1
x-session-id: <session UUID>
x-project-slug: <slug>
x-taste-learning: true|false
x-co-flag: true|false
```

满足条件时追加协议文档列出的可选头。`traceparent` 只在入站明确提供或
proxy 有活动 trace context 时发送，不再每次伪造。

## `/alpha/generate` 请求体

`buildCcRequest` 输出以下结构：

```json
{
  "config": {
    "workingDir": "...",
    "date": "YYYY-MM-DD",
    "environment": "...",
    "structure": [],
    "isGitRepo": false,
    "currentBranch": "",
    "mainBranch": "",
    "gitStatus": "",
    "recentCommits": []
  },
  "memory": null,
  "taste": null,
  "skills": null,
  "permissionMode": "standard",
  "threadId": "<UUID>",
  "mode": "interactive",
  "params": {
    "model": "...",
    "messages": [],
    "tools": [],
    "system": "...",
    "max_tokens": 64000,
    "stream": true
  }
}
```

入站 OpenAI/Anthropic 特有字段只在适配层使用；`params` 不发送 CLI v1.27.1
原生生成器没有的 `tool_choice` 和 `parallel_tool_calls`。工具定义统一为
`name`、`description`、`input_schema`。消息块按基线文档保留 text、image、
reasoning、tool-call、tool-result，并丢弃已标记 provider 已执行的工具调用。

`config` 的远端项目上下文无法从普通 OpenAI/Anthropic 请求可靠取得，因此保持
proxy 本地事实；允许显式入站 `x-working-dir`、`x-git-*` header 覆盖对应字段，
以便高级客户端提供 CLI 等价上下文。

## NDJSON 状态机

### 输入 framing

- 使用 `TextDecoder` 累积字节并按 `\n` 切分。
- 空行和非 JSON 行忽略。
- 不把 `data:` 当作 JSON 前缀；上游仍是原生 NDJSON。
- `[DONE]` 只作为兼容性噪声忽略，不能替代 `finish`/`abort`。

### 状态

```text
idle -> streaming -> finished
                    -> aborted
                    -> errored
```

只有 `finish` 或 `abort` 可以结束正常上游回合。上游 EOF 时若没有终止事件，
适配器产生 retryable truncated-stream 错误，不伪造正常完成。

### 事件

- `text-delta`、`reasoning-delta`：累加并向下游转换。
- `reasoning-start`、`reasoning-end`：更新内部思考段边界。
- `tool-call`：记录 tool call 并向下游转换。
- `tool-result`：记录 provider tool result，供后续消息/续接使用。
- `finish`：保存 `finishReason`、`rawFinishReason`、usage，结束当前回合。
- `abort`：结束为 aborted，不再发普通完成标志。
- `error`：解析 `error`、`statusCode`、`isRetryable`；未开始下游响应时映射为
  HTTP 错误，已开始时发送下游错误事件并关闭连接。

`pause_turn` 只表示需要 continuation，不是最终完成。适配器在同一个入站请求
内使用相同 `sessionId`/`threadId`，把已接收的 assistant 内容追加到下一次
`/alpha/generate` 请求；设置最大 continuation 次数为 3，超过后返回可重试错误，
避免无限循环。

## 错误和重试

- 上游非 2xx 继续使用现有状态码到下游错误的映射。
- 网络、429、5xx 和 retryable 流错误可以触发现有 key failover/下游重试。
- 认证或额度错误只允许现有的单次 key failover；不得在流中半途重新发送同一
  回合。
- server 返回的 `{error:{message,type}}`、`statusCode` 和 `isRetryable` 必须保留
  到日志/下游错误映射中。
- `outputTokens=0` 的额度保护保持为 proxy 策略，但只有在收到 `finish` 后触发；
  缺少终止帧优先按 truncated-stream 处理。

## 初始化请求

指纹和生命周期请求使用 CLI 头集合中的 `User-Agent`、环境、版本和 Bearer
认证。保留每 key 独立状态与刷新节流，但把 lifecycle metadata 的 `sessionId`
绑定到同一协议 `sessionId`，并允许 `DO_NOT_TRACK=1/true` 或
`CC_TELEMETRY=false` 跳过 lifecycle 请求。

## 测试策略

新增集成测试，使用本地 mock server 捕获真实 proxy 出站请求，至少覆盖：

1. `/alpha/generate` 头集合：User-Agent、environment、版本、session、slug、
   taste/co 和可选头。
2. body 顶层 `threadId`、`mode`、`skills: null`、config 覆盖和原生 params 字段。
3. message/tool/image/reasoning 转换和不发送 `tool_choice`/parallel 字段。
4. `finish`、`abort`、`error`、`pause_turn`、缺少终止帧的行为。
5. continuation 使用同一 session/thread，并限制最大次数。
6. 初始化请求和 telemetry 关闭开关。

现有 key failover 测试继续运行；测试 mock 必须返回最小合法额度响应，避免
额度预检把测试 key 误判为无额度。

## 非目标和风险

- 本次目标是“下游 OpenAI/Anthropic ↔ 上游 CLI v1.27.1 协议”的转换，不承诺
  proxy 已经实现 CLI 的全部 apiBase 辅助路由。
- 普通 OpenAI/Anthropic 客户端没有 CLI 的 Git 项目结构；只能使用 proxy 本地
  上下文或显式 header 覆盖。
- 自动 continuation 会增加单个入站请求的上游调用次数，必须在日志中记录
  continuation 序号和最终 finish reason。
