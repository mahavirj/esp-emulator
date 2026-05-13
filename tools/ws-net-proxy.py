#!/usr/bin/env python3
"""
WebSocket-to-TAP proxy for ESP-EMU browser networking.

Bridges Ethernet frames between a WebSocket client (browser) and a
Linux TAP interface, giving the browser-based emulator real network access.

Usage:
    # First set up TAP interface:
    sudo ./tools/setup-tap.sh

    # Then run the proxy (TAP must be owned by current user):
    python3 tools/ws-net-proxy.py [--tap tap0] [--port 8765]

    # In the browser, enter ws://localhost:8765 in the Network field.

Requirements:
    pip install websockets
"""

import argparse
import asyncio
import fcntl
import os
import struct
import sys

try:
    import websockets
    from websockets.asyncio.server import serve
except ImportError:
    print("Error: 'websockets' package required. Install with: pip install websockets")
    sys.exit(1)

# Linux TAP constants
TUNSETIFF = 0x400454CA
IFF_TAP = 0x0002
IFF_NO_PI = 0x1000

TAP_MTU = 1600


def open_tap(name: str) -> int:
    """Open an existing TAP device and return the file descriptor."""
    fd = os.open("/dev/net/tun", os.O_RDWR | os.O_NONBLOCK)
    ifr = struct.pack("16sH", name.encode(), IFF_TAP | IFF_NO_PI)
    fcntl.ioctl(fd, TUNSETIFF, ifr)
    return fd


async def handle_client(websocket, tap_fd: int):
    """Handle a single WebSocket client, bridging to TAP."""
    remote = websocket.remote_address
    print(f"[ws-net-proxy] Client connected: {remote}")

    loop = asyncio.get_event_loop()

    rx_queue: asyncio.Queue[bytes] = asyncio.Queue(maxsize=64)

    def tap_readable():
        """Callback when TAP fd has data ready."""
        try:
            data = os.read(tap_fd, TAP_MTU)
            if data:
                try:
                    rx_queue.put_nowait(data)
                except asyncio.QueueFull:
                    pass  # Drop frame if queue full
        except BlockingIOError:
            pass

    loop.add_reader(tap_fd, tap_readable)

    try:
        async def tap_to_ws():
            while True:
                frame = await rx_queue.get()
                await websocket.send(frame)

        async def ws_to_tap():
            async for message in websocket:
                if isinstance(message, bytes) and len(message) >= 14:
                    os.write(tap_fd, message)

        # When either task ends (client disconnect), cancel the other
        done, pending = await asyncio.wait(
            [asyncio.ensure_future(tap_to_ws()), asyncio.ensure_future(ws_to_tap())],
            return_when=asyncio.FIRST_COMPLETED,
        )
        for task in pending:
            task.cancel()

    finally:
        loop.remove_reader(tap_fd)
        print(f"[ws-net-proxy] Client disconnected: {remote}")


async def main(tap_name: str, host: str, port: int):
    tap_fd = open_tap(tap_name)
    print(f"[ws-net-proxy] TAP device '{tap_name}' opened (fd={tap_fd})")
    print(f"[ws-net-proxy] WebSocket server listening on ws://{host}:{port}")
    print(f"[ws-net-proxy] Enter ws://{host}:{port} in the browser Network field")

    async with serve(
        lambda ws: handle_client(ws, tap_fd),
        host,
        port,
        max_size=TAP_MTU + 100,
    ):
        await asyncio.Future()  # Run forever


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="WebSocket-to-TAP proxy for ESP-EMU")
    parser.add_argument("--tap", default="tap0", help="TAP interface name (default: tap0)")
    parser.add_argument("--host", default="localhost", help="WebSocket bind address (default: localhost)")
    parser.add_argument("--port", type=int, default=8765, help="WebSocket port (default: 8765)")
    args = parser.parse_args()

    try:
        asyncio.run(main(args.tap, args.host, args.port))
    except KeyboardInterrupt:
        print("\n[ws-net-proxy] Shutting down")
    except PermissionError:
        print(f"Error: cannot open TAP device '{args.tap}'. Run setup-tap.sh first.")
        sys.exit(1)
