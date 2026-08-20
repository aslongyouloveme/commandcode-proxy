import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';

const proxyDir = new URL('..', import.meta.url).pathname;

function listen(server) {
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
}

function close(server) {
  return new Promise(resolve => server.close(() => resolve()));
}

async function reservePort() {
  const server = http.createServer();
  const port = await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', () => resolve(server.address().port));
  });
  await close(server);
  return port;
}

async function waitForHealth(url, child) {
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    if (child.exitCode !== null) throw new Error(`proxy exited early: ${child.exitCode}`);
    try {
      const response = await fetch(`${url}/health`);
      if (response.ok) return;
    } catch {}
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  throw new Error('proxy did not become healthy');
}

test('retries a 400 insufficient-credits response with the next key', async () => {
  const exhaustedKey = 'user_exhausted';
  const healthyKey = 'user_healthy';
  const generateKeys = [];
  const upstream = http.createServer((req, res) => {
    if (req.url === '/alpha/generate') {
      const key = String(req.headers.authorization || '').replace(/^Bearer\s+/, '');
      generateKeys.push(key);
      if (key === exhaustedKey) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({
          error: {
            message: 'You have insufficient credits to make this request. Please purchase more credits to continue using the service.',
          },
        }));
        return;
      }
      res.writeHead(200, { 'content-type': 'application/x-ndjson' });
      res.end([
        JSON.stringify({ type: 'text-delta', text: 'ok' }),
        JSON.stringify({ type: 'finish', finishReason: 'stop', totalUsage: { inputTokens: 1, outputTokens: 1 } }),
        '',
      ].join('\n'));
      return;
    }
    if (req.url === '/alpha/billing/credits') {
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({
        windowLimits: { fiveHour: { cap: 100, used: 1 } },
        credits: { monthlyCredits: 100, belowThreshold: false },
      }));
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{}');
  });

  const upstreamPort = await listen(upstream);
  const tempDir = await mkdtemp(join(tmpdir(), 'commandcode-proxy-test-'));
  const keysFile = join(tempDir, 'keys.json');
  await writeFile(keysFile, JSON.stringify([exhaustedKey, healthyKey]));

  const proxyPort = await reservePort();
  const proxyUrl = `http://127.0.0.1:${proxyPort}`;
  const child = spawn(process.execPath, ['proxy.mjs'], {
    cwd: proxyDir,
    env: {
      ...process.env,
      PORT: String(proxyPort),
      HOST: '127.0.0.1',
      CC_API_BASE: `http://127.0.0.1:${upstreamPort}`,
      CC_KEYS_FILE: keysFile,
      CC_KEY_ROTATION_MIN_MINUTES: '60',
      CC_KEY_ROTATION_MAX_MINUTES: '60',
      CC_USE_PROVIDER_MODELS: 'false',
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stderr.on('data', chunk => { output += chunk; });

  try {
    await waitForHealth(proxyUrl, child);
    const response = await fetch(`${proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: { authorization: `Bearer ${exhaustedKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'hi' }] }),
    });
    const body = await response.text();

    assert.equal(response.status, 200, `proxy response: ${body}\nlogs:\n${output}`);
    assert.match(body, /"content":"ok"/);

    const secondResponse = await fetch(`${proxyUrl}/v1/chat/completions`, {
      method: 'POST',
      headers: { authorization: `Bearer ${exhaustedKey}`, 'content-type': 'application/json' },
      body: JSON.stringify({ model: 'deepseek/deepseek-v4-pro', messages: [{ role: 'user', content: 'again' }] }),
    });
    assert.equal(secondResponse.status, 200, await secondResponse.text());
    assert.deepEqual(generateKeys, [exhaustedKey, healthyKey, healthyKey]);
  } finally {
    child.kill('SIGTERM');
    await new Promise(resolve => child.once('exit', resolve));
    await close(upstream);
    await rm(tempDir, { recursive: true, force: true });
  }
});
