#!/usr/bin/env python3
"""Transparent TCP forwarder for RunPod Direct TCP fallback access.

Listens on 0.0.0.0:8189 and forwards byte-for-byte to ComfyUI on
127.0.0.1:8188. RunPod can expose 8189 as a Direct TCP port while
keeping 8188 exposed through its normal HTTP proxy.

The proxy uses asyncio streams with writer.drain() in both directions so
large uploads/downloads respect TCP backpressure instead of dropping the
connection when a socket temporarily cannot accept more data. It is fully
protocol-agnostic and therefore carries normal HTTP traffic, multipart file
uploads, downloads, and WebSocket connections used by ComfyUI.
"""

from __future__ import annotations

import asyncio
import itertools
import os
import socket

LISTEN_HOST = os.environ.get("COMFYUI_TCP_BACKUP_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("COMFYUI_TCP_BACKUP_PORT", "8189"))
TARGET_HOST = os.environ.get("COMFYUI_TCP_TARGET_HOST", "127.0.0.1")
TARGET_PORT = int(os.environ.get("COMFYUI_TCP_TARGET_PORT", "8188"))
CONNECT_TIMEOUT = float(os.environ.get("COMFYUI_TCP_CONNECT_TIMEOUT", "10"))
CHUNK_SIZE = int(os.environ.get("COMFYUI_TCP_CHUNK_SIZE", str(256 * 1024)))

# No idle timeout is intentionally applied. ComfyUI keeps WebSocket connections
# open for long periods even when no traffic is flowing.
_CONNECTION_IDS = itertools.count(1)


def _set_tcp_nodelay(writer: asyncio.StreamWriter) -> None:
    sock = writer.get_extra_info("socket")
    if sock is None:
        return
    try:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except OSError:
        pass


async def _close_writer(writer: asyncio.StreamWriter) -> None:
    try:
        writer.close()
        await writer.wait_closed()
    except (ConnectionError, OSError, RuntimeError):
        pass


async def _half_close(writer: asyncio.StreamWriter) -> None:
    """Propagate a clean EOF without immediately killing the reverse stream."""
    try:
        if writer.can_write_eof():
            writer.write_eof()
            await writer.drain()
    except (ConnectionError, OSError, RuntimeError, NotImplementedError):
        pass


async def _pump(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> tuple[str, int]:
    """Copy one direction with flow control.

    Returns (status, bytes_forwarded), where status is "eof" for a clean
    half-close or "error" for a connection-level failure.
    """
    total = 0
    try:
        while True:
            data = await reader.read(CHUNK_SIZE)
            if not data:
                await _half_close(writer)
                return "eof", total

            writer.write(data)
            # Critical for large file uploads/downloads: wait until the
            # transport buffer has room instead of overflowing a nonblocking
            # socket and terminating the connection.
            await writer.drain()
            total += len(data)
    except asyncio.CancelledError:
        raise
    except (ConnectionResetError, BrokenPipeError, ConnectionAbortedError, OSError):
        return "error", total


async def handle_client(
    client_reader: asyncio.StreamReader,
    client_writer: asyncio.StreamWriter,
) -> None:
    connection_id = next(_CONNECTION_IDS)
    peer = client_writer.get_extra_info("peername")
    _set_tcp_nodelay(client_writer)

    try:
        upstream_reader, upstream_writer = await asyncio.wait_for(
            asyncio.open_connection(TARGET_HOST, TARGET_PORT),
            timeout=CONNECT_TIMEOUT,
        )
    except (asyncio.TimeoutError, ConnectionError, OSError) as exc:
        print(
            f"[tcp-backup #{connection_id}] upstream connect failed "
            f"for {peer}: {exc}",
            flush=True,
        )
        await _close_writer(client_writer)
        return

    _set_tcp_nodelay(upstream_writer)

    client_to_upstream = asyncio.create_task(
        _pump(client_reader, upstream_writer),
        name=f"tcp-backup-{connection_id}-client-to-upstream",
    )
    upstream_to_client = asyncio.create_task(
        _pump(upstream_reader, client_writer),
        name=f"tcp-backup-{connection_id}-upstream-to-client",
    )
    tasks = {client_to_upstream, upstream_to_client}

    try:
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        first_results = []
        for task in done:
            try:
                first_results.append(task.result())
            except asyncio.CancelledError:
                pass

        # If one direction died because of a reset/broken pipe, the reverse
        # direction cannot be useful anymore. Cancel it promptly. For a clean
        # EOF, keep the reverse direction alive so HTTP responses after a
        # client half-close are not truncated.
        if any(status == "error" for status, _ in first_results):
            for task in pending:
                task.cancel()
        else:
            # Clean half-close: allow the opposite direction to finish
            # naturally. This also preserves WebSocket/full-duplex behavior.
            if pending:
                await asyncio.gather(*pending, return_exceptions=True)

        # Collect any task that was cancelled above.
        await asyncio.gather(*tasks, return_exceptions=True)
    finally:
        await _close_writer(upstream_writer)
        await _close_writer(client_writer)


async def main() -> None:
    if CHUNK_SIZE < 4096:
        raise ValueError("COMFYUI_TCP_CHUNK_SIZE must be at least 4096 bytes")

    server = await asyncio.start_server(
        handle_client,
        LISTEN_HOST,
        LISTEN_PORT,
        reuse_address=True,
    )

    addresses = ", ".join(str(sock.getsockname()) for sock in (server.sockets or []))
    print(
        "ComfyUI Direct TCP backup ready: "
        f"{addresses or f'{LISTEN_HOST}:{LISTEN_PORT}'} -> "
        f"{TARGET_HOST}:{TARGET_PORT} "
        f"(chunk={CHUNK_SIZE} bytes, backpressure=enabled)",
        flush=True,
    )

    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
