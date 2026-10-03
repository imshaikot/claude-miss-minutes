import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import net from 'node:net';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

import { handle, TOOLS, callApp } from '../miss-minutes-mcp.mjs';

const script = fileURLToPath(new URL('../miss-minutes-mcp.mjs', import.meta.url));

/** A stand-in for the app's body bridge server. */
async function fakeApp(token, reply) {
  const seen = [];
  const server = net.createServer((socket) => {
    let buffer = '';
    socket.setEncoding('utf8');
    socket.on('data', (chunk) => {
      buffer += chunk;
      if (!buffer.includes('\n')) return;
      const request = JSON.parse(buffer.trim());
      seen.push(request);
      const body = request.token === token ? reply(request) : { ok: false, text: 'unauthorized' };
      socket.end(JSON.stringify(body) + '\n');
    });
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  return { server, port: server.address().port, seen };
}

test('initialize echoes the protocol version and advertises tools', async () => {
  const response = await handle({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-03-26' } });
  assert.equal(response.result.protocolVersion, '2025-03-26');
  assert.deepEqual(response.result.capabilities, { tools: { listChanged: false } });
  assert.equal(response.result.serverInfo.name, 'minutes');
});

test('tools/list returns every body tool with an object schema', async () => {
  const response = await handle({ jsonrpc: '2.0', id: 2, method: 'tools/list' });
  const names = response.result.tools.map((tool) => tool.name);
  assert.deepEqual(names, ['emote', 'move_to', 'look_at_screen', 'set_reminder']);
  for (const tool of TOOLS) assert.equal(tool.inputSchema.type, 'object');
});

test('notifications get no response and unknown methods an error', async () => {
  assert.equal(await handle({ jsonrpc: '2.0', method: 'notifications/initialized' }), null);
  const response = await handle({ jsonrpc: '2.0', id: 3, method: 'resources/list' });
  assert.equal(response.error.code, -32601);
});

test('tools/call forwards to the app and maps images to MCP image content', async () => {
  const response = await handle(
    { jsonrpc: '2.0', id: 4, method: 'tools/call', params: { name: 'look_at_screen', arguments: { screenshot: true } } },
    async (tool, args) => {
      assert.equal(tool, 'look_at_screen');
      assert.deepEqual(args, { screenshot: true });
      return { ok: true, text: 'Frontmost app: Safari', image: { data: 'AAAA', mimeType: 'image/jpeg' } };
    },
  );
  assert.equal(response.result.isError, false);
  assert.deepEqual(response.result.content[1], { type: 'image', data: 'AAAA', mimeType: 'image/jpeg' });
});

test('an unreachable app becomes a tool error, not a crash', async () => {
  const response = await handle(
    { jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'emote', arguments: { mood: 'happy' } } },
    async () => { throw new Error('ECONNREFUSED'); },
  );
  assert.equal(response.result.isError, true);
  assert.match(response.result.content[0].text, /not reachable/);
});

test('callApp sends the token and parses one JSON line back', async () => {
  const app = await fakeApp('secret', (request) => ({ ok: true, text: `did ${request.tool}` }));
  const reply = await callApp('emote', { gesture: 'wave' }, { port: app.port, token: 'secret' });
  assert.deepEqual(reply, { ok: true, text: 'did emote' });
  assert.deepEqual(app.seen[0], { token: 'secret', tool: 'emote', args: { gesture: 'wave' } });
  app.server.close();
});

test('end to end over stdio: Claude Code would see this exchange', async () => {
  const app = await fakeApp('tok', () => ({ ok: true, text: 'Arrived.' }));
  const child = spawn(process.execPath, [script], { env: { ...process.env, MINUTES_PORT: String(app.port), MINUTES_TOKEN: 'tok' } });
  const responses = [];
  let buffer = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf('\n')) >= 0) {
      responses.push(JSON.parse(buffer.slice(0, newline)));
      buffer = buffer.slice(newline + 1);
    }
  });
  const send = (message) => child.stdin.write(JSON.stringify(message) + '\n');
  send({ jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } } });
  send({ jsonrpc: '2.0', method: 'notifications/initialized' });
  send({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'move_to', arguments: { target: 'app', app: 'Safari' } } });
  const deadline = Date.now() + 5000;
  while (responses.length < 2 && Date.now() < deadline) await new Promise((r) => setTimeout(r, 20));
  child.stdin.end();
  app.server.close();
  assert.equal(responses.length, 2);
  assert.equal(responses[1].id, 2);
  assert.deepEqual(responses[1].result.content, [{ type: 'text', text: 'Arrived.' }]);
});
