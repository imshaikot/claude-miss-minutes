#!/usr/bin/env node
// Miss Minutes body bridge.
//
// A zero-dependency MCP server (stdio, newline-delimited JSON-RPC 2.0) that
// Claude Code launches via --mcp-config. It exposes her body as tools and
// forwards each call to the app over a loopback socket:
//
//   Claude Code ⇄ (MCP stdio) ⇄ this bridge ⇄ (TCP 127.0.0.1, token) ⇄ MissMinutes.app
//
// The app passes MINUTES_PORT and MINUTES_TOKEN in the environment. Tool
// schemas live here; the app decodes them in MinutesCore/Body/BodyCommand.swift.

import net from 'node:net';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';

export const SERVER_INFO = { name: 'minutes', version: '0.1.0' };

export const MOODS = ['neutral', 'happy', 'excited', 'thinking', 'surprised', 'sly', 'sad', 'annoyed', 'love', 'worried', 'sleepy'];
export const GESTURES = ['wave', 'point', 'shrug', 'clap', 'jump', 'bow', 'nod', 'shake_head', 'ring', 'tap_foot', 'explain', 'look_around', 'stretch', 'blow_kiss'];

export const TOOLS = [
  {
    name: 'emote',
    description: "Change Miss Minutes' facial expression and/or play a gesture with her body. Instant and free; use it to act out what you say.",
    inputSchema: {
      type: 'object',
      properties: {
        mood: { type: 'string', enum: MOODS, description: 'Facial expression to hold.' },
        gesture: { type: 'string', enum: GESTURES, description: 'A one-off body gesture. "point" points at the mouse pointer.' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'move_to',
    description: "Move Miss Minutes somewhere on the screen. She walks, hops or teleports (hologram style) depending on the distance, and replies once she has arrived.",
    inputSchema: {
      type: 'object',
      properties: {
        target: {
          type: 'string',
          enum: ['app', 'floor', 'pointer', 'left', 'right', 'random'],
          description: 'app: sit on a window of the app named in "app". floor: stand on the Dock / bottom of the screen. pointer: come next to the mouse pointer. left/right: a bottom corner. random: any sensible spot.',
        },
        app: { type: 'string', description: 'App name for target "app", e.g. "Safari" or "Xcode".' },
        style: { type: 'string', enum: ['auto', 'walk', 'hop', 'teleport'], description: 'How to travel. Default auto.' },
      },
      required: ['target'],
      additionalProperties: false,
    },
  },
  {
    name: 'look_at_screen',
    description: "See what is on the user's screen: the open windows (app, title, position) front to back, plus a screenshot of the main display when the user allows it.",
    inputSchema: {
      type: 'object',
      properties: {
        screenshot: { type: 'boolean', description: 'Include a screenshot image (default true).' },
      },
      additionalProperties: false,
    },
  },
  {
    name: 'set_reminder',
    description: 'Set a timer or reminder. When it fires, Miss Minutes pops up next to the pointer, rings like an alarm clock and says the message aloud.',
    inputSchema: {
      type: 'object',
      properties: {
        minutes: { type: 'number', description: 'Minutes from now (may be fractional).' },
        seconds: { type: 'number', description: 'Seconds from now, added to minutes.' },
        message: { type: 'string', description: 'What she should say when it fires, in her voice.' },
      },
      required: ['message'],
      additionalProperties: false,
    },
  },
];

/** Forwards one tool call to the app and resolves with `{ ok, text, image? }`. */
export function callApp(tool, args, { port = Number(process.env.MINUTES_PORT), token = process.env.MINUTES_TOKEN ?? '', timeoutMs = 120_000 } = {}) {
  return new Promise((resolve, reject) => {
    if (!port) {
      reject(new Error('MINUTES_PORT is not set'));
      return;
    }
    const socket = net.createConnection({ host: '127.0.0.1', port });
    let buffer = '';
    const timer = setTimeout(() => {
      socket.destroy();
      reject(new Error('timed out waiting for Miss Minutes'));
    }, timeoutMs);
    socket.setEncoding('utf8');
    socket.on('connect', () => socket.write(JSON.stringify({ token, tool, args }) + '\n'));
    socket.on('data', (chunk) => {
      buffer += chunk;
      const newline = buffer.indexOf('\n');
      if (newline < 0) return;
      clearTimeout(timer);
      socket.end();
      try {
        resolve(JSON.parse(buffer.slice(0, newline)));
      } catch (error) {
        reject(error);
      }
    });
    socket.on('error', (error) => {
      clearTimeout(timer);
      reject(error);
    });
  });
}

const result = (id, value) => ({ jsonrpc: '2.0', id, result: value });
const failure = (id, code, message) => ({ jsonrpc: '2.0', id, error: { code, message } });

/** Handles one JSON-RPC message; returns the response, or null for notifications. */
export async function handle(message, call = callApp) {
  const { id, method, params } = message ?? {};
  switch (method) {
    case 'initialize':
      return result(id, {
        protocolVersion: params?.protocolVersion ?? '2025-06-18',
        capabilities: { tools: { listChanged: false } },
        serverInfo: SERVER_INFO,
        instructions: "These tools are Miss Minutes' body on the user's desktop. Use emote freely to act out replies.",
      });
    case 'ping':
      return result(id, {});
    case 'tools/list':
      return result(id, { tools: TOOLS });
    case 'tools/call': {
      const name = params?.name;
      if (!TOOLS.some((tool) => tool.name === name)) return failure(id, -32602, `Unknown tool: ${name}`);
      try {
        const reply = await call(name, params?.arguments ?? {});
        const content = [{ type: 'text', text: reply.text ?? '' }];
        if (reply.image?.data) content.push({ type: 'image', data: reply.image.data, mimeType: reply.image.mimeType ?? 'image/jpeg' });
        return result(id, { content, isError: reply.ok === false });
      } catch (error) {
        return result(id, { content: [{ type: 'text', text: `Miss Minutes' body is not reachable: ${error.message}` }], isError: true });
      }
    }
    default:
      if (id === undefined || id === null || method?.startsWith('notifications/')) return null;
      return failure(id, -32601, `Method not found: ${method}`);
  }
}

function main() {
  const send = (object) => process.stdout.write(JSON.stringify(object) + '\n');
  const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
  lines.on('line', async (line) => {
    if (!line.trim()) return;
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      send(failure(null, -32700, 'Parse error'));
      return;
    }
    const response = await handle(message);
    if (response) send(response);
  });
  lines.on('close', () => process.exit(0));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
