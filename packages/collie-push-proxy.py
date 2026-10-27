#!/usr/bin/env python3
"""Allowlisted HTTP CONNECT proxy for Collie's Web Push sender.

Collie runs in a private network namespace with only `lo`, so its
`web-push` sender cannot reach FCM, Mozilla or Apple. The bridge starts a
`socat` listener on 127.0.0.1:3128 inside that namespace and points
`COLLIE_PUSH_PROXY` at it. The listener forwards to this Unix socket; this
process runs OUTSIDE the jail, resolves the push endpoint, and tunnels only
the allowlisted hosts.

The endpoint in a push subscription is client-supplied and is not
host-restricted by Collie, so the allowlist here is also what keeps a
compromised paired device from turning the sender into an arbitrary HTTPS
client.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import os
import signal
import socket
import stat
import sys

MAX_HEADER = 8192
CONNECT_TIMEOUT = 10
TUNNEL_IDLE_TIMEOUT = 120


def log(message: str) -> None:
    print(f"[push-proxy] {message}", file=sys.stderr, flush=True)


def host_allowed(host: str, suffixes: list[str]) -> bool:
    """Exact host or a subdomain of an allowlisted suffix."""
    host = host.rstrip(".").lower()
    for suffix in suffixes:
        suffix = suffix.strip().lstrip(".").rstrip(".").lower()
        if suffix and (host == suffix or host.endswith("." + suffix)):
            return True
    return False


def response(code: int, reason: str) -> bytes:
    return (
        f"HTTP/1.1 {code} {reason}\r\n"
        "Connection: close\r\n"
        "Content-Length: 0\r\n"
        "\r\n"
    ).encode("ascii")


async def close_writer(writer: asyncio.StreamWriter) -> None:
    writer.close()
    with contextlib.suppress(Exception):
        await writer.wait_closed()


async def pipe(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
) -> None:
    try:
        while True:
            chunk = await reader.read(65536)
            if not chunk:
                break
            writer.write(chunk)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        # Half-close rather than close: the other direction may still have a
        # response to deliver (a client can finish its request before the
        # push service has answered).
        with contextlib.suppress(Exception):
            if writer.can_write_eof():
                writer.write_eof()


async def handle(
    reader: asyncio.StreamReader,
    writer: asyncio.StreamWriter,
    suffixes: list[str],
) -> None:
    try:
        try:
            header = await asyncio.wait_for(
                reader.readuntil(b"\r\n\r\n"), timeout=CONNECT_TIMEOUT
            )
        except (
            asyncio.IncompleteReadError,
            asyncio.LimitOverrunError,
            asyncio.TimeoutError,
        ):
            return

        if len(header) > MAX_HEADER:
            writer.write(response(431, "Request Header Fields Too Large"))
            await writer.drain()
            return

        request_line = header.split(b"\r\n", 1)[0].decode("latin-1")
        parts = request_line.split()
        if len(parts) != 3 or parts[0] != "CONNECT" or parts[2] not in (
            "HTTP/1.1",
            "HTTP/1.0",
        ):
            log(f"rejected non-CONNECT request: {request_line!r}")
            writer.write(response(405, "Method Not Allowed"))
            await writer.drain()
            return

        authority = parts[1]
        if authority.startswith("["):
            end = authority.find("]")
            if end < 0 or not authority[end + 1 :].startswith(":"):
                log(f"rejected malformed authority: {authority!r}")
                writer.write(response(400, "Bad Request"))
                await writer.drain()
                return
            host = authority[1:end]
            port = authority[end + 2 :]
        else:
            host, separator, port = authority.rpartition(":")
            if not separator:
                host, port = authority, "443"
            elif ":" in host:
                log(f"rejected unbracketed IPv6 authority: {authority!r}")
                writer.write(response(400, "Bad Request"))
                await writer.drain()
                return

        if port != "443" or not host_allowed(host, suffixes):
            log(f"rejected CONNECT {authority!r}")
            writer.write(response(403, "Forbidden"))
            await writer.drain()
            return

        try:
            upstream_reader, upstream_writer = await asyncio.wait_for(
                asyncio.open_connection(host, 443), timeout=CONNECT_TIMEOUT
            )
        except (OSError, asyncio.TimeoutError) as error:
            log(f"connect to {host}:443 failed: {error}")
            writer.write(response(502, "Bad Gateway"))
            await writer.drain()
            return

        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()

        first = asyncio.create_task(pipe(reader, upstream_writer))
        second = asyncio.create_task(pipe(upstream_reader, writer))
        done, pending = await asyncio.wait(
            {first, second}, timeout=TUNNEL_IDLE_TIMEOUT
        )
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)
        for task in done:
            with contextlib.suppress(Exception):
                task.result()

        await close_writer(upstream_writer)
    finally:
        await close_writer(writer)


def prepare_socket(path: str) -> None:
    try:
        current = os.lstat(path)
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(current.st_mode):
        raise SystemExit(f"{path} exists and is not a socket")

    # A stale socket from a crashed instance is normal. A live one is not:
    # connecting before unlinking keeps two proxies from fighting over the
    # same path.
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.2)
    try:
        probe.connect(path)
    except OSError:
        os.unlink(path)
    else:
        raise SystemExit(f"another push proxy is already listening on {path}")
    finally:
        probe.close()


async def serve(path: str, suffixes: list[str]) -> None:
    prepare_socket(path)
    os.umask(0o077)
    server = await asyncio.start_unix_server(
        lambda reader, writer: handle(reader, writer, suffixes),
        path=path,
        limit=MAX_HEADER,
    )
    os.chmod(path, 0o600)

    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for signal_number in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(signal_number, stop.set)

    log(f"listening on {path}; allowing: {', '.join(suffixes) or '(none)'}")
    try:
        async with server:
            await stop.wait()
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(path)
        log("stopped")


def main() -> int:
    parser = argparse.ArgumentParser(description="Allowlisted CONNECT proxy for Collie Web Push")
    parser.add_argument("--socket", required=True, help="Unix socket to listen on")
    parser.add_argument(
        "--allow",
        default="",
        help="Comma-separated host suffixes to allow (empty rejects every host)",
    )
    args = parser.parse_args()
    suffixes = [part.strip() for part in args.allow.split(",") if part.strip()]
    try:
        asyncio.run(serve(args.socket, suffixes))
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
