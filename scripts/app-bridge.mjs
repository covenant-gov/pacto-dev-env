#!/usr/bin/env node
// Headless client for the tauri-plugin-mcp-bridge WebSocket protocol.
//
// Lets shell scripts drive a running pacto-app debug build without an MCP
// client in the loop: connect to the bridge's WebSocket port, send an
// execute_js command, print the JSON result.
//
// Wire protocol (tauri-plugin-mcp-bridge 0.12.0, src/websocket.rs):
//   Request  (client -> server, JSON text frame):
//     { "id": "<string>", "command": "execute_js",
//       "args": { "script": "<js source>" } }
//   Response (server -> client, JSON text frame, matched by "id"):
//     { "id": "<string>", "success": bool, "data": <any>, "error": <string|null> }
// dispatch_command() reads `command`/`args` and routes "execute_js" to
// handle_execute_js(), which replies with exactly that shape. The server
// also broadcasts unrelated event frames on the same socket, so responses
// must be matched by "id", not assumed to be the next frame.
//
// Node 20+ ships a stable global WebSocket (undici); this box runs Node 24,
// so we use it directly instead of hand-rolling RFC 6455 framing.

import { randomUUID } from 'node:crypto';

const USAGE = `Usage: app-bridge.mjs --port <mcpBridgePort> --eval '<javascript source>' [--timeout <seconds>]

Evaluates JavaScript in a running pacto-app debug build's webview via the
tauri-plugin-mcp-bridge WebSocket and prints the result as JSON on stdout.

  --port <n>       mcpBridge port from sandbox-handle.json (required)
  --eval <js>       JavaScript source to evaluate in the webview (required)
  --timeout <secs>  seconds to wait for a response (default: 30)
  --help            show this message

Exit codes: 0 on success, 1 on connection failure, evaluation error, or timeout.
Diagnostics go to stderr; stdout carries only the JSON result.`;

function parseArgs(argv) {
  const args = { port: null, eval: null, timeout: 30, help: false };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    switch (arg) {
      case '--help':
      case '-h':
        args.help = true;
        break;
      case '--port':
        args.port = argv[++i];
        break;
      case '--eval':
        args.eval = argv[++i];
        break;
      case '--timeout':
        args.timeout = argv[++i];
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function fail(message) {
  console.error(message);
  process.exit(1);
}

async function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(e.message);
    console.error(USAGE);
    process.exit(1);
    return;
  }

  if (args.help) {
    console.log(USAGE);
    process.exit(0);
    return;
  }

  if (!args.port || !args.eval) {
    console.error('Missing required --port and/or --eval.');
    console.error(USAGE);
    process.exit(1);
    return;
  }

  const port = Number(args.port);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    fail(`Invalid --port: ${args.port}`);
    return;
  }

  const timeoutSeconds = Number(args.timeout);
  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds <= 0) {
    fail(`Invalid --timeout: ${args.timeout}`);
    return;
  }

  const url = `ws://127.0.0.1:${port}/`;
  const requestId = randomUUID();
  let settled = false;
  let lastErrorEvent = null;

  const ws = new WebSocket(url);
  const timer = setTimeout(() => {
    if (settled) return;
    settled = true;
    fail(`Timed out after ${timeoutSeconds}s waiting for a response from ${url}.`);
    try { ws.close(); } catch { /* already going down */ }
  }, timeoutSeconds * 1000);

  ws.addEventListener('open', () => {
    ws.send(JSON.stringify({
      id: requestId,
      command: 'execute_js',
      args: { script: args.eval },
    }));
  });

  ws.addEventListener('message', (event) => {
    if (settled) return;
    let parsed;
    try {
      parsed = JSON.parse(event.data);
    } catch {
      // Not JSON, or not our frame shape; ignore (could be a broadcast event).
      return;
    }
    if (!parsed || parsed.id !== requestId) return;

    settled = true;
    clearTimeout(timer);
    ws.close();

    if (parsed.success) {
      process.stdout.write(`${JSON.stringify(parsed.data ?? null)}\n`);
      process.exit(0);
    } else {
      fail(`Evaluation failed: ${parsed.error ?? 'unknown error'}`);
    }
  });

  ws.addEventListener('error', (event) => {
    lastErrorEvent = event;
  });

  ws.addEventListener('close', (event) => {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    const detail = lastErrorEvent?.message || lastErrorEvent?.error?.message;
    const reasonParts = [`code=${event.code}`];
    if (event.reason) reasonParts.push(`reason=${event.reason}`);
    if (detail) reasonParts.push(detail);
    fail(`Connection to ${url} closed before a response arrived (${reasonParts.join(', ')}). Is the app-bridge port right and the app running?`);
  });
}

main().catch((e) => {
  fail(`Unexpected error: ${e.stack || e.message || e}`);
});
