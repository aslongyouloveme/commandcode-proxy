# Command Code CLI v1.27.1 Protocol Compatibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the existing OpenAI/Anthropic proxy surface while making every proxy request to the documented Command Code server protocol match CLI v1.27.1 on the wire and in stream state semantics.

**Architecture:** Add a small protocol-context layer inside `proxy.mjs` that owns CLI-compatible headers, request context and body normalization. Reuse that context for initialization and generation requests. Extend the existing NDJSON translators with terminal/error state, then wrap upstream generation in a bounded continuation loop for `pause_turn` while preserving downstream OpenAI/Anthropic output formats.

**Tech Stack:** Node.js ESM, built-in `http`, `fetch`, `node:test`, no new runtime dependencies.

**Spec:** `docs/superpowers/specs/2026-08-20-commandcode-cli-protocol-compat-design.md`

## Global Constraints

- Keep `/v1/chat/completions`, `/v1/messages`, `/v1/models`, pool endpoints and server-mode authentication working.
- Upstream `/alpha/generate`, fingerprint, lifecycle and billing calls use the CLI v1.27.1 headers and documented JSON/NDJSON semantics.
- Do not send `tool_choice` or `parallel_tool_calls` in native `params`.
- Every upstream generation attempt must end with `finish` or `abort`; EOF without either is retryable truncation.
- Continuation is bounded at three attempts and reuses the same session/thread identity.
- Write tests before production changes and run the focused test after each task.

### Task 1: Add failing protocol capture tests

**Files:**
- Create: `test/protocol-compat.test.mjs`
- Modify: `test/key-failover.test.mjs`

**Interfaces:**
- Tests spawn `proxy.mjs` with a local mock upstream and capture request headers/body.
- The mock returns minimal valid JSON for initialization and billing probes, and NDJSON for generation.

- [x] **Step 1: Write the failing capture test**

  Assert that a normal OpenAI request causes an upstream `/alpha/generate` request with `User-Agent: cli`, `x-cli-environment`, `x-command-code-version: 1.27.1` by default, a valid `x-session-id`, a configured/forwarded slug, `skills: null`, top-level `threadId` and `mode`, and no `tool_choice`/`parallel_tool_calls`.

- [x] **Step 2: Add event-state tests**

  Add cases for `abort`, `error`, missing `finish`, and `pause_turn`; assert that missing termination is not reported as a normal `[DONE]` and that a pause causes a second upstream generation request with the same session/thread.

- [x] **Step 3: Make the existing failover fixture valid**

  Return a minimal `windowLimits`/credits payload for non-generation requests so quota precheck does not disable the test keys before the failover assertion.

- [x] **Step 4: Run the focused tests and verify RED**

  Run `node --test test/protocol-compat.test.mjs test/key-failover.test.mjs`.
  Expected: the new protocol assertions fail against current `proxy.mjs`; the failover test reaches its generation assertion instead of failing during quota precheck.

### Task 2: Implement CLI-compatible context, headers and body

**Files:**
- Modify: `proxy.mjs:24-110, 397-755, 1007-1079`
- Test: `test/protocol-compat.test.mjs`

**Interfaces:**
- Add `getProtocolEnvironment()`, `getProtocolVersion()`, `getOptionalProtocolHeaders()`, `createProtocolContext()` and `buildCcHeaders(context)`.
- Update `buildCcRequest(openaiReq, context)` to write `threadId`, `mode`, `skills: null` and omit proxy-only native params.
- Update `forwardToCC(body, apiKey, incomingHeaders, signal, context)` to use the canonical CLI header set.

- [x] **Step 1: Implement environment/version and optional-header helpers**

  Default environment to `production`, derive staging/local from `CC_API_ENV` or the configured API base, default protocol version to `1.27.1`, and read the documented optional flags from incoming headers or environment variables.

- [x] **Step 2: Implement request context construction**

  Reuse incoming session headers, accept valid `x-thread-id`/`x-command-code-mode`, select configured or forwarded project slug, and keep a per-request `threadId` for continuation.

- [x] **Step 3: Update body normalization**

  Emit CLI-shaped top-level fields, preserve CLI-compatible message blocks, map images with MIME metadata when available, and remove `tool_choice`/`parallel_tool_calls` from native params.

- [x] **Step 4: Update generation and initialization headers**

  Add `User-Agent: cli`, use the context in `/alpha/generate`, fingerprint, lifecycle and billing requests, and gate lifecycle on `DO_NOT_TRACK`/`CC_TELEMETRY=false`.

- [x] **Step 5: Run the focused capture test**

  Run `node --test test/protocol-compat.test.mjs`.
  Expected: header/body assertions pass; event-state assertions remain RED until Task 3.

### Task 3: Enforce NDJSON terminal semantics and bounded continuation

**Files:**
- Modify: `proxy.mjs:763-915, 1083-1441, 1637-1838, 2040-2149`
- Test: `test/protocol-compat.test.mjs`

**Interfaces:**
- Extend the OpenAI translator and Anthropic translator context with `finished`, `aborted`, `terminalError`, `pauseTurn`, `rawFinishReason`, and accumulated assistant blocks.
- Add a bounded helper that reissues `/alpha/generate` with the same protocol context and appended assistant continuation content.

- [x] **Step 1: Make event tests fail for the right reason**

  Run the new abort/error/truncation/pause tests and confirm failures are caused by current normal-EOF/DONE behavior, not test setup.

- [x] **Step 2: Track terminal events and raw finish reasons**

  Mark `finish`/`abort` as terminal, preserve `rawFinishReason`, capture structured `error`, and treat `tool-result` as state rather than an unknown event.

- [x] **Step 3: Reject unterminated upstream streams**

  Before emitting downstream normal completion, require `finished` or `aborted`; otherwise return a retryable proxy error and never emit a normal `[DONE]`/`message_stop`.

- [x] **Step 4: Implement `pause_turn` continuation**

  Suppress an intermediate pause finish from the downstream stream, append accumulated assistant text/reasoning/tool blocks to the next CC body, re-fetch with the same session/thread, and stop after three attempts with a retryable error.

- [x] **Step 5: Propagate stream errors**

  Map upstream `error`/`abort` into the existing OpenAI/Anthropic downstream error formats while preserving `statusCode`, `type` and retryability where the downstream format allows it.

- [x] **Step 6: Run focused and legacy tests**

  Run `node --test test/protocol-compat.test.mjs test/key-failover.test.mjs`.
  Expected: all focused tests pass.

### Task 4: Isolate proxy-only model extension and update documentation

**Files:**
- Modify: `proxy.mjs:2155-2192`
- Modify: `README.md`, `README_zh.md`
- Test: `test/protocol-compat.test.mjs`

**Interfaces:**
- Keep `/provider/v1/models` as an explicitly proxy-only extension, but use the shared CLI-compatible authentication/version/environment headers when it is enabled.
- Document that downstream endpoints are adapters and that upstream generation is CLI v1.27.1 compatible.

- [x] **Step 1: Add a regression assertion**

  Verify the model extension does not alter the canonical `/alpha/generate` body or headers and remains optional when `CC_USE_PROVIDER_MODELS=false`.

- [x] **Step 2: Implement the shared headers for model/credits calls**

  Reuse the protocol header builder without claiming `/provider/v1/models` is a CLI route.

- [x] **Step 3: Update English and Chinese README sections**

  Describe the two protocol boundaries, strict upstream compatibility, retained key-pool behavior, and the non-goal of implementing unused CLI auxiliary routes.

- [x] **Step 4: Run syntax and focused tests**

  Run `node --check proxy.mjs` and `node --test test/protocol-compat.test.mjs test/key-failover.test.mjs`.

### Task 5: Full verification and branch handoff

**Files:**
- No new production files.

- [x] **Step 1: Run all Node tests**

  Run `node --test test/*.test.mjs` from `commandcode-proxy`.

- [x] **Step 2: Inspect the final diff**

  Run `git diff --check`, `git diff --stat`, and inspect that no API keys, OAuth tokens or log payloads were added.

- [x] **Step 3: Record verification results**

  Report passing tests, any unrelated baseline issues, changed files and the final commit identifiers.
