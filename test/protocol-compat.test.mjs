import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const proxyDir = new URL('..', import.meta.url).pathname;

function listen(server, host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, host, () => resolve(server.address().port));
  });
}

function close(server) {
  return new Promise(resolve => server.close(() => resolve()));
}

async function reservePort() {
  const server = http.createServer();
  const port = await listen(server);
  await close(server);
  return port;
}

function readJson(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', chunk => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString();
      try { resolve(raw ? JSON.parse(raw) : null); } catch (error) { reject(error); }
    });
    req.on('error', reject);
  });
}

function sendNdjson(res, events) {
  res.writeHead(200, { 'content-type': 'application/x-ndjson' });
  res.end(events.map(event => JSON.stringify(event)).join('\n') + '\n');
}

function sendJson(res, payload = {}) {
  res.writeHead(200, { 'content-type': 'application/json' });
  res.end(JSON.stringify(payload));
}

async function waitForHealth(url, child) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`proxy exited early: ${child.exitCode}`);
    try {
      const response = await fetch(`${url}/health`);
      if (response.ok) return;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 40));
  }
  throw new Error('proxy did not become healthy');
}

async function startProxy(upstreamHandler, extraEnv = {}) {
  const upstream = http.createServer(upstreamHandler);
  const upstreamPort = await listen(upstream);
  const tempDir = await mkdtemp(join(tmpdir(), 'commandcode-protocol-test-'));
  const proxyPort = await reservePort();
  const proxy = spawn(process.execPath, ['proxy.mjs'], {
    cwd: proxyDir,
    env: {
      ...process.env,
      PORT: String(proxyPort),
      HOST: '127.0.0.1',
      CC_API_BASE: `http://127.0.0.1:${upstreamPort}`,
      CC_KEYS_FILE: join(tempDir, 'missing-keys.json'),
      CC_USE_PROVIDER_MODELS: 'false',
      CC_CLI_VERSION: '1.27.1',
      ...extraEnv,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let output = '';
  proxy.stdout.on('data', chunk => { output += chunk; });
  proxy.stderr.on('data', chunk => { output += chunk; });

  const proxyUrl = `http://127.0.0.1:${proxyPort}`;
  await waitForHealth(proxyUrl, proxy);

  return {
    proxyUrl,
    output: () => output,
    async stop() {
      proxy.kill('SIGTERM');
      await new Promise(resolve => proxy.once('exit', resolve));
      await close(upstream);
      await rm(tempDir, { recursive: true, force: true });
    },
  };
}

function baseHeaders(extra = {}) {
  return {
    authorization: 'Bearer user_protocol_test',
    'content-type': 'application/json',
    ...extra,
  };
}

test('emits the CLI v1.27.1 headers and body shape upstream', async () => {
  const generateRequests = [];
  const upstream = async (req, res) => {
    const body = await readJson(req);
    if (req.url === '/alpha/generate') {
      generateRequests.push({ headers: req.headers, body });
      sendNdjson(res, [
        { type: 'text-delta', text: 'protocol-ok' },
        { type: 'finish', finishReason: 'stop', totalUsage: { inputTokens: 1, outputTokens: 1 } },
      ]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream, {
    CC_API_ENV: 'local',
    PROJECT_SLUG: 'protocol-project',
    CC_TASTE_LEARNING: 'true',
    CC_CO_FLAG: 'true',
  });

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders({
        'x-session-id': 'session-protocol-123',
        'x-thread-id': '123e4567-e89b-12d3-a456-426614174000',
        'x-command-code-mode': 'plan',
        'x-cmd-zdr': '1',
      }),
      body: JSON.stringify({
        model: 'deepseek/deepseek-v4-pro',
        messages: [{ role: 'user', content: 'hello' }],
        tools: [{ type: 'function', function: { name: 'read_file', parameters: { type: 'object' } } }],
        tool_choice: 'auto',
        parallel_tool_calls: true,
        stream: true,
      }),
    });
    const body = await response.text();

    assert.equal(response.status, 200, `${body}\n${server.output()}`);
    assert.match(body, /protocol-ok/);
    assert.equal(generateRequests.length, 1);

    const { headers, body: ccBody } = generateRequests[0];
    assert.equal(headers['user-agent'], 'cli');
    assert.equal(headers['x-cli-environment'], 'local');
    assert.equal(headers['x-command-code-version'], '1.27.1');
    assert.equal(headers['x-session-id'], 'session-protocol-123');
    assert.equal(headers['x-project-slug'], 'protocol-project');
    assert.equal(headers['x-taste-learning'], 'true');
    assert.equal(headers['x-co-flag'], 'true');
    assert.equal(headers['x-cmd-zdr'], '1');
    assert.equal(ccBody.threadId, '123e4567-e89b-12d3-a456-426614174000');
    assert.equal(ccBody.mode, 'plan');
    assert.equal(ccBody.skills, null);
    assert.equal(ccBody.params.stream, true);
    assert.equal('tool_choice' in ccBody.params, false);
    assert.equal('parallel_tool_calls' in ccBody.params, false);
    assert.deepEqual(ccBody.params.tools[0], {
      name: 'read_file',
      description: '',
      input_schema: { type: 'object' },
    });
  } finally {
    await server.stop();
  }
});

test('keeps provider model discovery optional and uses shared CLI headers when enabled', async () => {
  const providerRequests = [];
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/provider/v1/models') {
      providerRequests.push(req.headers);
      sendJson(res, { data: [{ id: 'provider-model' }] });
      return;
    }
    sendJson(res, {});
  };

  const enabledServer = await startProxy(upstream, {
    CC_USE_PROVIDER_MODELS: 'true',
    CC_API_ENV: 'staging',
  });
  try {
    const response = await fetch(`${enabledServer.proxyUrl}/v1/models`, { headers: baseHeaders() });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.equal(body.data[0].id, 'provider-model');
    assert.equal(providerRequests.length, 1);
    assert.equal(providerRequests[0]['user-agent'], 'cli');
    assert.equal(providerRequests[0]['x-cli-environment'], 'staging');
    assert.equal(providerRequests[0]['x-command-code-version'], '1.27.1');
  } finally {
    await enabledServer.stop();
  }

  providerRequests.length = 0;
  const disabledServer = await startProxy(upstream);
  try {
    const response = await fetch(`${disabledServer.proxyUrl}/v1/models`, { headers: baseHeaders() });
    const body = await response.json();
    assert.equal(response.status, 200);
    assert.notEqual(body.data[0].id, 'provider-model');
    assert.equal(providerRequests.length, 0);
  } finally {
    await disabledServer.stop();
  }
});

test('uses CLI helper headers and skips lifecycle telemetry when disabled', async () => {
  const helperRequests = [];
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/fingerprint/record' || req.url === '/alpha/lifecycle-events') {
      helperRequests.push({ path: req.url, headers: req.headers });
      sendJson(res, {});
      return;
    }
    if (req.url === '/alpha/generate') {
      sendNdjson(res, [
        { type: 'text-delta', text: 'initialized' },
        { type: 'finish', finishReason: 'stop', totalUsage: { inputTokens: 1, outputTokens: 1 } },
      ]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream, { CC_TELEMETRY: 'false' });

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders(),
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'hello' }] }),
    });
    assert.equal(response.status, 200, await response.text());

    assert.deepEqual(helperRequests.map(request => request.path), ['/alpha/fingerprint/record']);
    const { headers } = helperRequests[0];
    assert.equal(headers['user-agent'], 'cli');
    assert.equal(headers['x-cli-environment'], 'local');
    assert.equal(headers['x-command-code-version'], '1.27.1');
    assert.equal(headers['x-session-id'], undefined);
    assert.equal(headers['x-project-slug'], undefined);
  } finally {
    await server.stop();
  }
});

test('continues a pause_turn on the same upstream session and thread', async () => {
  const generateRequests = [];
  const upstream = async (req, res) => {
    const body = await readJson(req);
    if (req.url === '/alpha/generate') {
      generateRequests.push({ headers: req.headers, body });
      if (generateRequests.length === 1) {
        sendNdjson(res, [
          { type: 'text-delta', text: 'first ' },
          { type: 'finish', finishReason: 'pause_turn', rawFinishReason: 'pause_turn', totalUsage: { inputTokens: 1, outputTokens: 1 } },
        ]);
      } else {
        sendNdjson(res, [
          { type: 'text-delta', text: 'second' },
          { type: 'finish', finishReason: 'stop', totalUsage: { inputTokens: 1, outputTokens: 1 } },
        ]);
      }
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders({
        'x-session-id': 'session-pause-123',
        'x-thread-id': '123e4567-e89b-12d3-a456-426614174001',
      }),
      body: JSON.stringify({
        model: 'deepseek/deepseek-v4-pro',
        messages: [{ role: 'user', content: 'continue this' }],
        stream: true,
      }),
    });
    const body = await response.text();

    assert.equal(response.status, 200, `${body}\n${server.output()}`);
    assert.match(body, /first/);
    assert.match(body, /second/);
    assert.equal(generateRequests.length, 2);
    assert.equal(generateRequests[0].headers['x-session-id'], 'session-pause-123');
    assert.equal(generateRequests[1].headers['x-session-id'], 'session-pause-123');
    assert.equal(generateRequests[0].body.threadId, generateRequests[1].body.threadId);
    assert.equal(generateRequests[1].body.threadId, '123e4567-e89b-12d3-a456-426614174001');
    assert.ok(generateRequests[1].body.params.messages.some(message =>
      message.role === 'assistant' && message.content?.some(block => block.text === 'first ')));
  } finally {
    await server.stop();
  }
});

test('bounds OpenAI streaming pause_turn continuation', async () => {
  let generateCount = 0;
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      generateCount++;
      sendNdjson(res, [
        { type: 'text-delta', text: `part-${generateCount}` },
        { type: 'finish', finishReason: 'pause_turn', rawFinishReason: 'pause_turn', totalUsage: { inputTokens: 1, outputTokens: 1 } },
      ]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders(),
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'loop' }], stream: true }),
    });
    const body = await response.text();

    assert.equal(response.status, 200);
    assert.equal(generateCount, 4);
    assert.match(body, /continuation limit exceeded/i);
    assert.doesNotMatch(body, /data: \[DONE\]/);
  } finally {
    await server.stop();
  }
});

test('does not turn an unterminated upstream stream into normal completion', async () => {
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      res.writeHead(200, { 'content-type': 'application/x-ndjson' });
      res.end(JSON.stringify({ type: 'text-delta', text: 'partial' }) + '\n');
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders(),
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'truncate' }], stream: true }),
    });
    const body = await response.text();

    assert.equal(response.status, 200);
    assert.match(body, /truncated/i);
    assert.doesNotMatch(body, /data: \[DONE\]/);
  } finally {
    await server.stop();
  }
});

test('does not emit Anthropic message_stop for an unterminated upstream stream', async () => {
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      sendNdjson(res, [{ type: 'text-delta', text: 'partial' }]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/messages`, {
      method: 'POST',
      headers: { ...baseHeaders(), 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 100, messages: [{ role: 'user', content: 'truncate' }], stream: true }),
    });
    const body = await response.text();

    assert.equal(response.status, 200);
    assert.match(body, /truncated/i);
    assert.doesNotMatch(body, /"type":"message_stop"/);
  } finally {
    await server.stop();
  }
});

test('surfaces an upstream abort as an error instead of empty-response rate limiting', async () => {
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      sendNdjson(res, [{ type: 'abort' }]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders(),
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'abort' }], stream: true }),
    });
    const body = await response.text();

    assert.equal(response.status, 502);
    assert.match(body, /aborted/i);
  } finally {
    await server.stop();
  }
});

test('preserves a string-valued upstream error for OpenAI clients', async () => {
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      sendNdjson(res, [{ type: 'error', error: 'provider said no' }]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders(),
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'error' }], stream: true }),
    });
    const body = await response.text();

    assert.equal(response.status, 502);
    assert.match(body, /provider said no/);
  } finally {
    await server.stop();
  }
});

test('preserves a string-valued upstream error for Anthropic clients', async () => {
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      sendNdjson(res, [{ type: 'error', error: 'provider said no' }]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/messages`, {
      method: 'POST',
      headers: { ...baseHeaders(), 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 100, messages: [{ role: 'user', content: 'error' }], stream: true }),
    });
    const body = await response.text();

    assert.equal(response.status, 502);
    assert.match(body, /provider said no/);
  } finally {
    await server.stop();
  }
});

test('continues pause_turn for non-stream OpenAI responses before returning JSON', async () => {
  const generateRequests = [];
  const upstream = async (req, res) => {
    const body = await readJson(req);
    if (req.url === '/alpha/generate') {
      generateRequests.push({ headers: req.headers, body });
      if (generateRequests.length === 1) {
        sendNdjson(res, [
          { type: 'text-delta', text: 'first ' },
          { type: 'finish', finishReason: 'pause_turn', rawFinishReason: 'pause_turn', totalUsage: { inputTokens: 1, outputTokens: 1 } },
        ]);
      } else {
        sendNdjson(res, [
          { type: 'text-delta', text: 'second' },
          { type: 'finish', finishReason: 'stop', totalUsage: { inputTokens: 1, outputTokens: 1 } },
        ]);
      }
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders(),
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'continue json' }], stream: false }),
    });
    const body = await response.json();

    assert.equal(response.status, 200, JSON.stringify(body));
    assert.equal(body.choices[0].message.content, 'first second');
    assert.equal(generateRequests.length, 2);
  } finally {
    await server.stop();
  }
});

test('rejects an unterminated non-stream OpenAI response', async () => {
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      res.writeHead(200, { 'content-type': 'application/x-ndjson' });
      res.end(JSON.stringify({ type: 'text-delta', text: 'partial' }) + '\n');
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: baseHeaders(),
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'truncate' }], stream: false }),
    });
    const body = await response.text();

    assert.equal(response.status, 502);
    assert.match(body, /truncated/i);
  } finally {
    await server.stop();
  }
});

test('surfaces an upstream abort as an Anthropic error', async () => {
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      sendNdjson(res, [{ type: 'abort' }]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/messages`, {
      method: 'POST',
      headers: { ...baseHeaders(), 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 100, messages: [{ role: 'user', content: 'abort' }], stream: true }),
    });
    const body = await response.text();

    assert.equal(response.status, 502);
    assert.match(body, /aborted/i);
  } finally {
    await server.stop();
  }
});

test('bounds Anthropic streaming pause_turn continuation', async () => {
  let generateCount = 0;
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      generateCount++;
      sendNdjson(res, [
        { type: 'text-delta', text: `part-${generateCount}` },
        { type: 'finish', finishReason: 'pause_turn', rawFinishReason: 'pause_turn', totalUsage: { inputTokens: 1, outputTokens: 1 } },
      ]);
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/messages`, {
      method: 'POST',
      headers: { ...baseHeaders(), 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 100, messages: [{ role: 'user', content: 'loop' }], stream: true }),
    });
    const body = await response.text();

    assert.equal(response.status, 200);
    assert.equal(generateCount, 4);
    assert.match(body, /continuation limit exceeded/i);
    assert.doesNotMatch(body, /"type":"message_stop"/);
  } finally {
    await server.stop();
  }
});

test('continues pause_turn for non-stream Anthropic responses before returning JSON', async () => {
  const generateRequests = [];
  const upstream = async (req, res) => {
    const body = await readJson(req);
    if (req.url === '/alpha/generate') {
      generateRequests.push({ headers: req.headers, body });
      if (generateRequests.length === 1) {
        sendNdjson(res, [
          { type: 'text-delta', text: 'first ' },
          { type: 'finish', finishReason: 'pause_turn', rawFinishReason: 'pause_turn', totalUsage: { inputTokens: 1, outputTokens: 1 } },
        ]);
      } else {
        sendNdjson(res, [
          { type: 'text-delta', text: 'second' },
          { type: 'finish', finishReason: 'stop', totalUsage: { inputTokens: 1, outputTokens: 1 } },
        ]);
      }
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/messages`, {
      method: 'POST',
      headers: { ...baseHeaders(), 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 100, messages: [{ role: 'user', content: 'continue json' }], stream: false }),
    });
    const body = await response.json();

    assert.equal(response.status, 200, JSON.stringify(body));
    assert.equal(body.content[0].text, 'first second');
    assert.equal(generateRequests.length, 2);
  } finally {
    await server.stop();
  }
});

test('rejects an unterminated non-stream Anthropic response', async () => {
  const upstream = async (req, res) => {
    await readJson(req);
    if (req.url === '/alpha/generate') {
      res.writeHead(200, { 'content-type': 'application/x-ndjson' });
      res.end(JSON.stringify({ type: 'text-delta', text: 'partial' }) + '\n');
      return;
    }
    sendJson(res, {});
  };
  const server = await startProxy(upstream);

  try {
    const response = await fetch(`${server.proxyUrl}/v1/messages`, {
      method: 'POST',
      headers: { ...baseHeaders(), 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({ model: 'claude-sonnet-4-6', max_tokens: 100, messages: [{ role: 'user', content: 'truncate' }], stream: false }),
    });
    const body = await response.text();

    assert.equal(response.status, 502);
    assert.match(body, /truncated/i);
  } finally {
    await server.stop();
  }
});
