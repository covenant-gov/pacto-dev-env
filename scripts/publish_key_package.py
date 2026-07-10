#!/usr/bin/env python3
"""Publish a KeyPackage for a bot by registering a temporary handler.

This script connects to the pacto-bot-api Unix socket, registers a temporary
handler with the SendGroupMessages capability, calls agent.publish_key_package,
and then unregisters.  It is intended to run inside a python:3-slim container
mounted to the pacto-bot-api-data volume.
"""

import asyncio
import json
import os
import sys

BOT_ID = os.environ.get("BOT_ID")
SOCKET_PATH = os.environ.get("PACTO_SOCKET_PATH", "/var/lib/pacto-bot-api/pacto-bot-api.sock")


def request(req_id, method, params=None):
    msg = {"jsonrpc": "2.0", "id": req_id, "method": method}
    if params is not None:
        msg["params"] = params
    return msg


def notification(method, params=None):
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None:
        msg["params"] = params
    return msg


async def send_json(writer, obj):
    line = json.dumps(obj, separators=(",", ":")) + "\n"
    writer.write(line.encode())
    await writer.drain()


async def read_json(reader):
    line = await reader.readline()
    if not line:
        raise EOFError("connection closed")
    return json.loads(line.decode())


async def rpc_call(reader, writer, req_id, method, params=None):
    await send_json(writer, request(req_id, method, params))
    while True:
        msg = await read_json(reader)
        if msg.get("id") == req_id:
            if "error" in msg:
                raise RuntimeError(f"{method} failed: {msg['error']}")
            return msg.get("result")


async def main():
    if not BOT_ID:
        print("BOT_ID is required", file=sys.stderr)
        sys.exit(1)

    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_unix_connection(SOCKET_PATH),
            timeout=5.0,
        )
    except (OSError, asyncio.TimeoutError) as exc:
        print(f"failed to connect to daemon socket: {exc}", file=sys.stderr)
        sys.exit(1)

    try:
        result = await rpc_call(
            reader,
            writer,
            1,
            "handler.register",
            {
                "bot_ids": [BOT_ID],
                "event_types": [],
                "capabilities": ["SendGroupMessages"],
            },
        )
        handler_id = result.get("handler_id")
        print(f"registered temporary handler {handler_id} for {BOT_ID}", file=sys.stderr)

        event_id = await rpc_call(
            reader,
            writer,
            2,
            "agent.publish_key_package",
            {"bot_id": BOT_ID},
        )
        print(event_id)
    except Exception as exc:  # noqa: BLE001
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        try:
            await send_json(writer, notification("handler.unregister", {}))
        except Exception:  # noqa: BLE001
            pass
        writer.close()
        await writer.wait_closed()


if __name__ == "__main__":
    asyncio.run(main())
