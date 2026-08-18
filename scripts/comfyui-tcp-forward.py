#!/usr/bin/env python3
"""Simple TCP forwarder for RunPod Direct TCP fallback access.

Listens on 0.0.0.0:8189 and forwards byte-for-byte to ComfyUI on
127.0.0.1:8188. RunPod can expose 8189 as a Direct TCP port while
keeping 8188 exposed through its normal HTTP proxy.
"""

import os
import selectors
import socket
import socketserver

LISTEN_HOST = os.environ.get("COMFYUI_TCP_BACKUP_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("COMFYUI_TCP_BACKUP_PORT", "8189"))
TARGET_HOST = os.environ.get("COMFYUI_TCP_TARGET_HOST", "127.0.0.1")
TARGET_PORT = int(os.environ.get("COMFYUI_TCP_TARGET_PORT", "8188"))


class ForwardHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            upstream = socket.create_connection((TARGET_HOST, TARGET_PORT), timeout=10)
        except OSError:
            return

        self.request.setblocking(False)
        upstream.setblocking(False)
        sel = selectors.DefaultSelector()
        sel.register(self.request, selectors.EVENT_READ, upstream)
        sel.register(upstream, selectors.EVENT_READ, self.request)

        try:
            while True:
                events = sel.select(timeout=60)
                if not events:
                    continue
                for key, _ in events:
                    src = key.fileobj
                    dst = key.data
                    try:
                        data = src.recv(65536)
                    except (BlockingIOError, ConnectionResetError, OSError):
                        return
                    if not data:
                        return
                    try:
                        dst.sendall(data)
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        return
        finally:
            sel.close()
            upstream.close()


class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    print(
        f"ComfyUI Direct TCP backup: {LISTEN_HOST}:{LISTEN_PORT} -> "
        f"{TARGET_HOST}:{TARGET_PORT}",
        flush=True,
    )
    with ThreadingTCPServer((LISTEN_HOST, LISTEN_PORT), ForwardHandler) as server:
        server.serve_forever()
