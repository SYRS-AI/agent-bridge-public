#!/usr/bin/env python3
"""Minimal MCP stdio channel server for Agent Bridge wake webhooks."""

from __future__ import annotations

import json
import os
import sys
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


class JsonRpcWriter:
    def __init__(self) -> None:
        self._lock = threading.Lock()

    def send(self, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        header = f"Content-Length: {len(body)}\r\n\r\n".encode("ascii")
        with self._lock:
            sys.stdout.buffer.write(header)
            sys.stdout.buffer.write(body)
            sys.stdout.buffer.flush()

    def response(self, request_id: Any, result: dict[str, Any]) -> None:
        self.send({"jsonrpc": "2.0", "id": request_id, "result": result})

    def error(self, request_id: Any, code: int, message: str) -> None:
        self.send({"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}})

    def notification(self, method: str, params: dict[str, Any]) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params})


class BridgeChannelServer:
    def __init__(self) -> None:
        self.agent = os.environ.get("BRIDGE_WEBHOOK_AGENT", "").strip()
        self.state_dir = Path(os.environ.get("BRIDGE_STATE_DIR", Path.home() / ".agent-bridge" / "state"))
        self.port = int(os.environ.get("BRIDGE_WEBHOOK_PORT", "9001"))
        self.writer = JsonRpcWriter()
        self.instructions = (
            "Agent Bridge webhook channel. Messages are wake signals only. "
            "Do not answer the webhook itself. Check inbox with `agb inbox` and process queued tasks."
        )

    def clear_idle_marker(self) -> None:
        if not self.agent:
            return
        agent_dir = self.state_dir / "agents" / self.agent
        idle_file = agent_dir / "idle-since"
        try:
            idle_file.unlink(missing_ok=True)
        except TypeError:
            if idle_file.exists():
                idle_file.unlink()
        try:
            agent_dir.rmdir()
        except OSError:
            pass

    def deliver(self, content: str) -> None:
        self.clear_idle_marker()
        self.writer.notification(
            "notifications/claude/channel",
            {
                "content": content,
                "meta": {
                    "source": "agent_bridge",
                    "chat_id": self.agent or "bridge",
                    "message_id": str(uuid.uuid4()),
                    "user": "agent_bridge",
                    "ts": datetime.now(timezone.utc).isoformat(),
                },
            },
        )

    def handle_request(self, message: dict[str, Any]) -> None:
        method = message.get("method")
        request_id = message.get("id")
        params = message.get("params") or {}

        if request_id is None:
            return

        if method == "initialize":
            protocol_version = params.get("protocolVersion") or "2025-03-26"
            self.writer.response(
                request_id,
                {
                    "protocolVersion": protocol_version,
                    "capabilities": {"experimental": {"claude/channel": {}}},
                    "serverInfo": {"name": "bridge-webhook", "version": "0.1.0"},
                    "instructions": self.instructions,
                },
            )
            return

        if method == "ping":
            self.writer.response(request_id, {})
            return

        if method == "tools/list":
            self.writer.response(request_id, {"tools": []})
            return

        if method == "resources/list":
            self.writer.response(request_id, {"resources": []})
            return

        if method == "prompts/list":
            self.writer.response(request_id, {"prompts": []})
            return

        self.writer.error(request_id, -32601, f"Method not found: {method}")

    def serve_stdio(self) -> None:
        stream = sys.stdin.buffer
        while True:
            headers: dict[str, str] = {}
            while True:
                line = stream.readline()
                if not line:
                    return
                if line in (b"\r\n", b"\n", b""):
                    break
                text = line.decode("utf-8", errors="replace").strip()
                if ":" not in text:
                    continue
                key, value = text.split(":", 1)
                headers[key.strip().lower()] = value.strip()
            if not headers:
                continue
            length = int(headers.get("content-length", "0"))
            if length <= 0:
                continue
            body = stream.read(length)
            if not body:
                return
            try:
                payload = json.loads(body.decode("utf-8"))
            except json.JSONDecodeError:
                continue
            try:
                self.handle_request(payload)
            except Exception as exc:  # pragma: no cover - defensive
                request_id = payload.get("id")
                if request_id is not None:
                    self.writer.error(request_id, -32000, str(exc))

    def serve_http(self) -> ThreadingHTTPServer:
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, fmt: str, *args: Any) -> None:
                return

            def _send(self, status: int, payload: dict[str, Any]) -> None:
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:  # noqa: N802
                if self.path != "/health":
                    self._send(404, {"ok": False})
                    return
                self._send(200, {"ok": True, "agent": outer.agent, "port": outer.port})

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("Content-Length", "0"))
                raw = self.rfile.read(length).decode("utf-8") if length else ""
                content = raw.strip()
                if not content:
                    self._send(400, {"ok": False, "error": "empty body"})
                    return
                try:
                    if self.headers.get("Content-Type", "").startswith("application/json"):
                        parsed = json.loads(content)
                        if isinstance(parsed, dict):
                            content = str(parsed.get("content") or "")
                except json.JSONDecodeError:
                    pass
                if not content:
                    self._send(400, {"ok": False, "error": "missing content"})
                    return
                outer.deliver(content)
                self._send(200, {"ok": True})

        server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        return server


def main() -> int:
    server = BridgeChannelServer()
    http_server = server.serve_http()
    try:
        server.serve_stdio()
    finally:
        http_server.shutdown()
        http_server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
