# Command Code CLI v1.27.1 与 `commandcode-proxy` 协议转换说明

## 1. 结论与边界

本工程是协议转换器，不是把 CLI 原生接口直接暴露给下游的透明代理：

```text
OpenAI /v1/chat/completions  ─┐
                              ├─> Command Code /alpha/generate (NDJSON)
Anthropic /v1/messages        ─┘                  │
                                                  v
                                  OpenAI SSE / Anthropic SSE
```

- 下游保留 OpenAI Chat Completions 和 Anthropic Messages 两个兼容入口。
- 上游生成、指纹、生命周期和额度请求使用 CLI v1.27.1 的认证头、JSON 信封和 NDJSON 终止语义。
- `/provider/v1/models` 是代理专用的可选模型发现扩展，不属于 CLI 原生路由。
- key pool、server gate、额度冷却、单请求一次 failover、超时和日志仍是代理边界策略。
- 本次不新增 CLI 当前未使用的 whoami、subscriptions、namespaces、agent、web-search、share、Taste、sandbox 等辅助路由。

## 2. 交互流程

### 2.1 OpenAI / Anthropic 入站

```text
客户端请求
  │
  ├─ 解析 JSON、server gate、解析/选择 user_ API key
  ├─ 为本次请求创建 ProtocolContext
  │    ├─ sessionId：入站 session 或按 key 复用的长期 session
  │    ├─ 合法 x-thread-id，否则生成 UUID
  │    ├─ mode / environment / projectSlug / tasteLearning / coFlag
  │    └─ config：proxy 本地事实，可由 x-working-dir / x-git-* 覆盖
  ├─ 首次或刷新时 POST /alpha/fingerprint/record
  │    └─ telemetry 未关闭时并行 POST /alpha/lifecycle-events
  ├─ 将下游消息转换为 CC 自有消息块
  ├─ POST /alpha/generate，params.stream 固定为 true
  ├─ 按换行消费上游 NDJSON
  │    ├─ finish：完成本轮
  │    ├─ pause_turn：追加 assistant 内容并继续同一 session/thread
  │    ├─ abort / error：转为下游错误
  │    └─ EOF 无终止帧：truncated_stream，不伪造正常完成
  └─ 转为 OpenAI SSE 或 Anthropic SSE/JSON
```

### 2.2 上游实际调用

| 方法 | 路由 | 用途 | 协议状态 |
|---|---|---|---|
| POST | `/alpha/fingerprint/record` | 每 key 初始化/刷新设备指纹 | CLI 头集合，辅助头不继承 session/project |
| POST | `/alpha/lifecycle-events` | `cli_session_exists` telemetry | `DO_NOT_TRACK`、`CC_TELEMETRY=false` 或 `telemetry=false` 时跳过 |
| POST | `/alpha/generate` | 主模型生成 | CLI v1.27.1 body + NDJSON |
| GET | `/alpha/billing/credits` | key pool 额度展示/预检 | CLI 通用头集合 |
| GET | `/provider/v1/models` | 可选动态模型列表 | 代理扩展，共享认证/版本/环境头 |

## 3. CLI v1.27.1 出站请求头

### 3.1 `/alpha/generate`

```http
Content-Type: application/json
User-Agent: cli
Authorization: Bearer user_xxx
x-cli-environment: production|staging|local
x-command-code-version: 1.27.1
x-session-id: <session id>
x-project-slug: <project slug>
x-taste-learning: true|false
x-co-flag: true|false
```

满足条件时追加：

```http
x-cmd-zdr: 1
x-cmd-provider-deepseek-internal: 1
x-oss-primary-provider: <provider>
x-oauth-token: Bearer <provider OAuth token>
x-oauth-provider: anthropic|openai|copilot
```

来源：`CC_CLI_VERSION` 默认 `1.27.1`；`CC_API_ENV` 或 `CC_API_BASE` 推导 environment；入站/环境变量提供可选开关；project slug 优先使用入站 header，其次配置，最后使用确定性的 proxy slug。`traceparent` 仅在入站明确传入时保留，不再每次伪造。

### 3.2 辅助请求

指纹、生命周期、计费和模型扩展使用：

```http
Content-Type: application/json
User-Agent: cli
Authorization: Bearer user_xxx
x-cli-environment: production|staging|local
x-command-code-version: 1.27.1
```

这些请求不自动继承生成请求的 `x-session-id`、`x-project-slug`、`x-taste-learning` 和 `x-co-flag`，符合 CLI 辅助 API 的头差异。

## 4. `/alpha/generate` JSON 转换

代理发送的结构为：

```json
{
  "config": {
    "workingDir": "/proxy/workdir",
    "date": "2026-08-20",
    "environment": "darwin",
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
    "model": "deepseek/deepseek-v4-flash",
    "messages": [],
    "tools": [],
    "max_tokens": 64000,
    "stream": true
  }
}
```

转换规则：

| 下游输入 | 上游 wire |
|---|---|
| system message | 合并为 `params.system` |
| user text | `{type:"text",text}` |
| OpenAI `image_url` | `{type:"image",image,mimeType?}` |
| assistant text/reasoning | `text` / `reasoning` block |
| OpenAI `tool_calls` | `tool-call`，参数解析为 JSON object |
| Anthropic `tool_use` | 先转内部 tool call，再生成 `tool-call` |
| tool result | 独立 `role:"tool"` + `tool-result` |
| tool definitions | 只发送 `name`、`description`、`input_schema` |
| `tool_choice`、`parallel_tool_calls` | 仅下游使用，不进入 `params` |
| `providerExecuted=true` tool call | 不重复写入 wire 消息 |

`memory`、`taste`、`skills` 固定为 `null`；`params.tools` 始终为数组。`config` 反映 proxy 进程本地上下文，普通 OpenAI/Anthropic 客户端无法提供的 Git 项目事实可用显式 `x-working-dir`、`x-is-git-repo`、`x-git-*` header 覆盖。

## 5. NDJSON 状态机

上游响应按 `TextDecoder` + `\n` 分行，空行、非 JSON 行和 `[DONE]` 噪声忽略；不解析 SSE `data:` 前缀。

| 事件 | 处理 |
|---|---|
| `text-delta` | 累加 assistant 文本并转下游文本增量 |
| `reasoning-delta` | 累加 reasoning，并转 OpenAI `reasoning_content` 或 Anthropic thinking block |
| `tool-call` | 记录 id/name/arguments，转下游工具调用 |
| `tool-result` | 记录 provider tool result，续接时追加为 `role:"tool"` |
| `finish` | 保存 normalized/raw finish reason 和 usage，标记 `finished` |
| `abort` | 标记 `aborted`，不发送正常完成标记 |
| `error` | 保留 message/type/statusCode/isRetryable，映射为下游错误 |
| EOF 无 `finish`/`abort` | 返回 retryable `truncated_stream` |

### `pause_turn` continuation

`rawFinishReason= pause_turn` 不是下游最终完成。代理会把本轮新增的 assistant text、reasoning、tool-call 和 tool-result 追加到同一个 `params.messages`，复用相同 `x-session-id`、`threadId` 和 `mode`，再次 POST `/alpha/generate`。最多执行三次 continuation，超限返回 retryable 错误，防止无限循环。

## 6. 下游差异与代理策略

- OpenAI 流式响应为 `text/event-stream`，仅在收到最终 finish 后发送正常 finish chunk 和 `data: [DONE]`。
- Anthropic 流式响应为 `message_start`、content blocks、`message_delta`、`message_stop`；`pause_turn` 中间轮次不发送最终 stop。
- OpenAI/Anthropic 非流式响应先完整消费上游 NDJSON，再返回 JSON。
- `outputTokens=0` 是代理的计费保护策略，返回 429；但只有收到 `finish` 后才执行，截断优先返回 `truncated_stream`。
- 上游 HTTP 错误沿用现有状态映射；额度/认证错误仍可触发单次 key failover。流已经开始后不切 key 重放同一轮。

## 7. 明确的非目标

当前 proxy 只承诺“下游 OpenAI/Anthropic ↔ 上游 CLI v1.27.1 主生成协议”的转换，不承诺把 proxy 直接作为完整 Command Code CLI `apiBase`。要覆盖 CLI 编译产物中的其他辅助路由，应另行扩展并逐项补齐请求/响应 schema。

## 8. 验证记录

新增 `test/protocol-compat.test.mjs`，使用本地 mock upstream 捕获真实出站请求，覆盖：

- CLI v1.27.1 headers、environment、session/thread、slug、taste/co、tools/body 字段；
- provider model 扩展启停与共享头；
- 指纹头和 telemetry opt-out；
- OpenAI/Anthropic 流式 abort、非流式 abort/JSON、缺少终止帧；
- OpenAI/Anthropic `pause_turn` continuation 与同 session/thread；
- 既有 key failover 测试和合法额度 mock。

当前验证命令：

```text
node --check proxy.mjs
node --test test/*.test.mjs
```

结果：17 tests passed, 0 failed。
