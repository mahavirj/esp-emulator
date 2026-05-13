# Browser Emulation Guide

Run ESP32-C3/C6/P4 firmware in a web browser using the WASM build of ESP-EMU.

## Quick Start

### 1. Build the WASM package

```sh
# Install wasm-pack (one-time)
cargo install wasm-pack

# Build WASM package into www/pkg/
wasm-pack build --target web --out-dir www/pkg --no-typescript -- --features wasm --no-default-features
```

### 2. Serve the web UI

```sh
cd www
python3 -m http.server 8080
```

Open `http://localhost:8080` in Chrome/Firefox/Safari.

### 3. Load and run firmware

1. Select the target chip — the ROM button labels itself with the embedded default (e.g. `esp32c3 rev3 (embedded)`) and updates live when you change the chip. Click it to upload a custom ROM ELF as an override; the label switches to `Custom: <filename>`.
2. Set the **WiFi SSID** and **Password** fields to match your firmware's WiFi config
3. Click **Load Firmware** — select a merged flash binary (`.bin`)
4. Click **Run**

UART output appears in the terminal. The firmware will connect to the emulated WiFi AP and get an IP address via DHCP.

## Browser Networking

By default, the browser emulator runs in internal-only mode: WiFi association and DHCP work, but the firmware has no path to the real network. To enable real connectivity, use the WebSocket-to-TAP proxy.

### Architecture

```
Browser (WASM emulator)
  ↕ WebSocket (binary Ethernet frames)
ws-net-proxy (Rust or Python)
  ↕ read/write
TAP interface (tap0)
  ↕ IP forwarding + NAT
Host network / Internet
```

### Setup

#### 1. Create TAP interface with NAT

```sh
sudo ./tools/setup-tap.sh
```

This creates `tap0` with IP `192.168.4.1/24`, enables IP forwarding, and adds iptables NAT rules. Run `sudo ./tools/setup-tap.sh --teardown` to clean up.

#### 2. Start the WebSocket proxy

**Rust proxy** (recommended — lower latency):

```sh
# Build (one-time)
cargo build --release --features ws-proxy --bin ws-net-proxy

# Run
./target/release/ws-net-proxy
```

**Python proxy** (no build step, requires `pip install websockets`):

```sh
python3 tools/ws-net-proxy.py
```

Both listen on `ws://localhost:8765` by default. Use `--port` to change.

#### 3. Connect from the browser

1. In the web UI, the **Network** field shows `ws://localhost:8765`
2. Click **Connect Net** — the button turns red and shows "Disconnect" when connected
3. Click **Run** — the firmware now has real network access through the TAP interface

### Proxy options

| Flag | Default | Description |
|------|---------|-------------|
| `--tap NAME` | `tap0` | TAP interface name |
| `--port PORT` | `8765` | WebSocket listen port |
| `--host ADDR` | `0.0.0.0` (Rust) / `localhost` (Python) | Bind address |

### Verifying connectivity

After the firmware gets an IP (`192.168.4.2`), you can verify the network path:

```sh
# From the host, ping the emulated device
ping 192.168.4.2

# Watch traffic on the TAP interface
sudo tcpdump -i tap0 -n
```

## WiFi Configuration

The web UI has SSID and Password fields in the toolbar:

| Field | Default | Description |
|-------|---------|-------------|
| WiFi SSID | `myssid` | Must match the SSID configured in your firmware |
| Password | `mypassword` | WPA2-PSK passphrase (8-63 chars). Leave empty for Open mode |

These are applied when firmware is loaded. To change them, reload the firmware.

## Limitations

- **No TAP in browser** — Real networking requires the WebSocket proxy running on the host
- **Performance** — WASM runs ~2-5x slower than native. TCP-heavy workloads may experience higher latency
- **Single connection** — The WebSocket proxy supports one browser tab at a time per TAP interface
- **Linux only** — TAP networking and the proxy require Linux. The emulator itself (without networking) runs in any modern browser

## Troubleshooting

### "WASM module loaded" never appears
- Make sure you're serving via HTTP (`python3 -m http.server`), not opening `index.html` directly (`file://` URLs block WASM imports)

### Firmware doesn't connect to WiFi
- Check that the SSID/Password fields match your firmware's WiFi configuration
- The fields must be set **before** clicking Load Firmware

### Network timeout after WiFi connects
- Verify the WebSocket proxy is running: `./target/release/ws-net-proxy`
- Verify TAP is up: `ip addr show tap0`
- Click **Connect Net** in the browser before clicking Run
- Check proxy output for "Client connected" message

### Staircase text in terminal
- This is fixed by `convertEol: true` in the terminal config. If you see it, hard-refresh the page (Ctrl+Shift+R)

## File Structure

```
www/
├── index.html          # Main page with terminal, controls, and side panel
├── app.js              # UI orchestration, worker communication
├── worker.js           # Web Worker: WASM emulation loop, WebSocket networking
└── pkg/                # wasm-pack output (generated)
    ├── esp_emu.js      # JS bindings
    └── esp_emu_bg.wasm # WASM binary

tools/
├── setup-tap.sh        # Create/teardown TAP interface with NAT
├── ws-net-proxy.rs     # Rust WebSocket-to-TAP proxy (build with --features ws-proxy)
└── ws-net-proxy.py     # Python WebSocket-to-TAP proxy (requires websockets package)
```
