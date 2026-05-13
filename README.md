# esp-emu

A Rust-based RISC-V emulator that runs ESP32-C3, ESP32-C6, ESP32-P4, and ESP32-S31 firmware binaries — CPU, memory, WiFi, BLE, Thread, Ethernet, crypto, and more. This repo distributes the installer, prebuilt release binaries, user-facing docs, and helper tools.

## Install

One-liner (Linux x86_64 / macOS Apple Silicon):

```sh
curl -fsSL https://raw.githubusercontent.com/mahavirj/esp-emulator/main/install.sh | sh
```

This downloads the latest binary to `$HOME/.local/bin/esp-emu`. If `~/.local/bin` is not on your `PATH`, the installer prints the `export PATH=...` line to add.

Pin a specific version:

```sh
curl -fsSL https://raw.githubusercontent.com/mahavirj/esp-emulator/main/install.sh | sh -s -- --version 0.29.0
```

Other options: `--check` (print latest, no install), `--bin-dir DIR`, `--force`, `--quiet`. Full help:

```sh
curl -fsSL https://raw.githubusercontent.com/mahavirj/esp-emulator/main/install.sh | sh -s -- --help
```

## Updating

After install:

```sh
esp-emu update           # refresh in place
esp-emu update --check   # only print latest version
esp-emu --version        # print currently installed version
```

`esp-emu update` re-runs the installer against the directory holding the running binary, so it updates wherever you first installed it.

## Features

- **CPU**: Full RV32IMAC on C3/C6; RV32IMAFC (with single-precision FP via Berkeley SoftFloat) on P4. Multi-hart scheduler supports P4's dual HP cores. RV32 PMP and Espressif PMA enforced via a fused two-level page table — catches the same access violations as silicon (IDF panic memprot tests, TEE REE-vs-TEE isolation, IRAM/IROM write protection).
- **WiFi**: Soft AP with WPA2-PSK, 802.11 management frames, DHCP server, and TAP networking for real connectivity
- **Ethernet**: OpenCores Ethernet MAC (OpenETH) for QEMU-compatible `CONFIG_ETH_USE_OPENETH` firmware, plus Synopsys DesignWare GMAC for ESP32-P4's built-in EMAC
- **Networking backends**: user-mode (zero-setup, QEMU-style NAT via smoltcp — DHCP, DNS forwarder, mDNS relay with optional record-rewriting NAT for Matter/HomeKit-style service discovery, IPv6 SLAAC, `hostfwd`, restrict mode, ICMP echo), TAP bridge (Linux), vmnet (macOS)
- **BLE**: NimBLE host stack support with HCI forwarding to Bumble (virtual controller) or physical Linux HCI adapters
- **Thread / 802.15.4**: OpenThread `ot_cli` and `ot_br` on ESP32-C6. Single-node forms a partition out of the box; two emulator instances form one Thread mesh (Leader + Child, or Border Router + end device) over a localhost UDP bridge
- **Crypto**: AES (ECB/CBC/OFB/CTR/CFB), SHA (1/224/256), RSA, ECC, HMAC-SHA256, Digital Signature, XTS-AES flash encryption, ECDSA (P-256/P-384, P4), Key Manager + HUK Generator (P4) — drives flash / HMAC / DS / ECDSA key sourcing for `CONFIG_SECURE_FLASH_ENCRYPTION_KEY_SOURCE_KEY_MGR`
- **Peripherals**: UART, USB Serial JTAG, GPIO, system timer, timer groups, interrupt controllers (PLIC for C3/C6, CLIC for P4), eFuse, SPI flash, GDMA
- **esptool / espefuse over `socket://`**: a `--uart-tcp HOST:PORT` bridge plus `--strap-mode 0x02` (UART download) lets esptool, espefuse, and `idf.py flash` drive the running emulator over TCP, matching the QEMU-Espressif workflow. See [esptool / espefuse](#esptool--espefuse-over-socket).
- **Chips**: ESP32-C3, ESP32-C6, and ESP32-P4 with per-chip memory maps and interrupt controllers
- **WASM**: Browser-based emulation via WebAssembly with JavaScript API
- **ROM stubs**: Intercepts key ROM functions (printf, UART, delay, WiFi TX) instead of emulating full ROM

## Quick Start

### Prerequisites

- A merged flash binary built with ESP-IDF (see [Building Firmware](#building-firmware-images))

Default ROM ELFs (C3 rev3, C6 rev0, P4 rev3) are embedded in the binary, so `--rom` is optional for the common case. Pass `--rom <path>` only to override with a different silicon revision or a custom ROM (e.g. from `~/.espressif/tools/esp-rom-elfs/`).

### Running

```sh
esp-emu \
  --chip esp32c3 \
  --firmware build/merged_flash.bin
```

### CLI Options

| Flag | Default | Description |
|------|---------|-------------|
| `--chip <CHIP>` | (required) | Target chip: `esp32c3`, `esp32c6`, or `esp32p4` |
| `--firmware <PATH>` | (required) | Path to merged flash binary |
| `--rom <PATH>` | embedded | Path to ROM ELF file (overrides the built-in default for `--chip`) |
| `--elf <PATH>` | — | Path to application ELF for BLE symbol lookup (e.g. `build/project.elf`) |
| `--efuse <PATH>` | — | Path to eFuse binary (336 bytes, QEMU-compatible). State is always saved back on exit (eFuses are one-time-programmable). |
| `--timeout <DURATION>` | — | Exit after duration (e.g. `5s`, `500ms`) |
| `--exit-on <STRING>` | — | Exit with code 0 when UART output contains this string |
| `--batch-size <N>` | `50000` | Instructions per iteration |
| `--skip-bootloader` | off | Load app directly from partition table, skipping 2nd-stage bootloader (firmware-entry path; only meaningful with `--skip-rom`) |
| `--skip-rom` | off | Reset the CPU at the firmware/bootloader entry instead of the real mask ROM. Default executes the ROM, which is required for KEY_SOURCE_KEY_MGR flash-key recovery and other eFuse-driven cold-boot decisions. |
| `--save-state` | off | Save flash state to disk on exit (overwrites firmware file) |
| `--inject <DATA>` | — | Payload to inject into UART RX (supports `\n` escape). Repeatable. |
| `--inject-on <STRING>` | — | Trigger string in UART output that causes injection (paired with `--inject`). Repeatable. |
| `--net <BACKEND>` | `tap0` if present on Linux, else `user` | Network backend: `user` (slirp-style, any OS), `user,hostfwd=tcp::H-:G,…`, `user,restrict=yes`, `user,dns=1.1.1.1`, `user,mdns-nat=yes` (Matter / mDNS service NAT), `tap,ifname=tap0` (Linux), `vmnet` (macOS) |
| `--wifi-ssid <SSID>` | `myssid` | WiFi soft AP SSID broadcast to firmware |
| `--wifi-password <PASS>` | `mypassword` | WPA2-PSK passphrase (8-63 chars). Empty string for open mode |
| `--ble-hci <BACKEND>` | — | BLE HCI backend: `tcp:host:port` for Bumble/virtual controller, `hci0` for Linux adapter |
| `--thread-sim <SPEC>` | — | IEEE 802.15.4 / Thread bridge, e.g. `bind:9001,peer:127.0.0.1:9002`. Forwards radio frames over localhost UDP to another emulator instance. Requires `--elf`. |
| `--uart-tcp <HOST:PORT>` | — | Bridge UART0 to a TCP server (e.g. `127.0.0.1:5555`); esptool connects via `socket://`. Mirrors QEMU's `-serial tcp::PORT,server,nowait`. While active, UART RX comes from the socket and TX goes to it (stdin/stdout disconnected). |
| `--strap-mode <HEX>` | — | GPIO_STRAP value at reset. `0x02` = UART download mode (jumps to ROM entry instead of firmware entry); `0x08` = SPI flash boot (default). Mirrors QEMU's `-global driver=esp32cN.gpio,property=strap_mode,value=…`. |

### UART Injection

The `--inject` and `--inject-on` flags work in pairs to send data to the firmware's UART when specific output is detected:

```sh
esp-emu \
  --firmware app.bin \
  --inject "yes\n" --inject-on "Continue? [y/n]"
```

Standard input is also forwarded to UART RX line-by-line.

### Log Levels

Control verbosity via `RUST_LOG`:

```sh
RUST_LOG=info  esp-emu ...   # Default, boot messages
RUST_LOG=debug esp-emu ...   # Peripheral access details
RUST_LOG=trace esp-emu ...   # Every bus read/write
```

## WiFi Emulation

The emulator includes a built-in WiFi soft access point with WPA2-PSK support. Firmware that connects to WiFi will:

1. **Scan** — The AP sends beacons and probe responses with the configured SSID
2. **Authenticate** — Open System authentication
3. **Associate** — AP assigns AID=1
4. **WPA2 handshake** — Full 4-way EAPOL handshake (when password is set)
5. **DHCP** — Built-in DHCP server assigns 192.168.4.2 (gateway 192.168.4.1)

This works automatically — ESP-IDF WiFi station firmware will connect and receive an IP address. Use `--wifi-ssid` and `--wifi-password` to match your firmware's WiFi configuration. Default: SSID `myssid`, password `mypassword`.

For real network connectivity, run with either [User-mode Networking](#user-mode-networking-no-host-setup) (zero setup, the default when `--net` is omitted and no `tap0` is available) or [TAP Networking](#tap-networking) (bridged to host interface; picked automatically on Linux when `tap0` is set up).

## Ethernet Emulation (OpenETH)

The emulator includes an OpenCores Ethernet MAC, the same virtual NIC used by the Espressif QEMU fork. ESP-IDF firmware built with `CONFIG_ETH_USE_OPENETH=y` will use this driver for networking instead of WiFi.

OpenETH provides a simpler, faster networking path — raw Ethernet frames pass directly between the firmware and the TAP device without 802.11 frame wrapping or WPA2 encryption overhead.

```sh
# Build firmware with OpenETH (in your ESP-IDF project sdkconfig):
#   CONFIG_ETH_USE_OPENETH=y
#   CONFIG_EXAMPLE_CONNECT_ETHERNET=y

# Run with TAP networking (also requires dnsmasq for DHCP)
sudo dnsmasq --interface=tap0 --bind-interfaces --dhcp-range=192.168.4.2,192.168.4.100,12h
esp-emu \
  --chip esp32c6 \
  --firmware build/merged_flash.bin \
  --net "tap,ifname=tap0"
```

The routing is automatic: when firmware enables OpenETH (sets TXEN/RXEN in MODER), TAP frames go directly to the Ethernet MAC. When firmware uses WiFi instead, frames route through the WiFi soft AP as before. No CLI flag is needed to select the path.

## ESP32-P4 Support

ESP32-P4 is a dual-core RV32IMAFC chip with hardware single-precision floating point, a custom CLIC interrupt controller, and a Synopsys DesignWare GMAC at `0x50098000`. The emulator boots ROM → 2nd-stage bootloader → ESP-IDF app, runs SMP firmware (`xTaskCreatePinnedToCore` on both cores), and supports the built-in EMAC over any networking backend (`--net user`, TAP, vmnet).

```sh
esp-emu \
  --chip esp32p4 \
  --firmware build/merged_flash.bin \
  --net user
```

Build firmware with `idf.py set-target esp32p4 && idf.py build`. The emulator targets ROM rev 0; set `CONFIG_ESP32P4_REV_MIN_0=y` and `CONFIG_ESP32P4_SELECTS_REV_LESS_V3=y` to match.

CPU1 is brought up dynamically once the firmware releases its reset (`LP_AON_CLKRST_HPCPU_RESET_CTRL0`); single-core firmware (`CONFIG_FREERTOS_UNICORE=y`) runs on hart 0 only with no dual-core overhead. PSRAM is backed as zero-init RAM; PTP, jumbo Ethernet frames, and the LP core are not modelled.

## User-mode Networking (no host setup)

`--net user` enables a QEMU-style user-mode backend that proxies the guest's
TCP/UDP flows through host sockets. No TAP device, no `sudo`, no `dnsmasq` —
it works out of the box on Linux, macOS, and other Unix platforms.

```sh
esp-emu \
  --chip esp32c6 \
  --firmware build/merged_flash.bin \
  --net user
```

Addressing matches the WiFi soft AP (`192.168.4.0/24`, guest `192.168.4.2`,
gateway `192.168.4.1`). Traffic to the gateway IP is redirected to
`127.0.0.1` on the host, mirroring slirp's `10.0.2.2` convention.

### What's included

- **DHCP** + **ARP** so the guest can get an IPv4 lease on both WiFi and
  OpenETH paths
- **TCP/UDP outbound NAT** via smoltcp's TCP stack + non-blocking host sockets
- **Built-in DNS forwarder**: parses `/etc/resolv.conf`; the guest is told the
  gateway is its DNS server and queries are forwarded transparently
- **mDNS relay**: binds `224.0.0.251:5353` on the host (via `SO_REUSEPORT`, so
  it coexists with Avahi / systemd-resolved) and proxies multicast queries
- **IPv6**: smoltcp IPv6 stack, link-local + ULA addresses, Router Advertisement
  so the guest auto-configures a global IPv6 via SLAAC
  (`fd00:6573:702d:656d::/64`)
- **ICMP echo-reply spoof** — `ping` from the guest "succeeds" without real
  ICMP leaving the host (same as QEMU/libslirp without `CAP_NET_RAW`)

### Host → guest via `hostfwd` (QEMU-compatible syntax)

```sh
esp-emu ... --net "user,hostfwd=tcp::18080-:80,hostfwd=udp::1053-:53"

# From the host:
curl http://127.0.0.1:18080/hello
dig @127.0.0.1 -p 1053 example.com
```

Format: `hostfwd=PROTO:[HOST_ADDR]:HOST_PORT-:GUEST_PORT`. An empty host addr
(`tcp::10080-:80`) binds `0.0.0.0` (any interface) — match QEMU. Use
`tcp:127.0.0.1:10080-:80` to restrict to localhost.

### mDNS NAT (Matter, HomeKit, etc.)

Zero-setup Matter commissioning and control — no TAP needed. Adds on top of the
basic mDNS relay by **rewriting** the guest's A/AAAA records to host loopback
and automatically binding hostfwd listeners for each SRV-advertised port.

```sh
esp-emu ... --net "user,mdns-nat=yes"

# In another terminal:
chip-tool pairing ble-wifi 1 myssid mypassword 20202021 3840 --ble-controller 1
chip-tool onoff toggle 1 1
```

When the guest announces `_matter._tcp … port=5540 target=<name>.local` with
A/AAAA records pointing at `192.168.4.2` / `fd00:...`, the backend:

1. Rewrites A → `127.0.0.1`, AAAA → `::1` in the mDNS response (both the
   multicast announcements and the unicast replies to QU-bit queries).
2. Extracts the SRV port and auto-binds `127.0.0.1:5540` UDP + TCP hostfwds
   that forward to the guest.

chip-tool's Matter resolver sees the service at `127.0.0.1:5540`, the hostfwd
bridges the CASE/operational traffic into the guest, and post-commissioning
control (toggle, read, invoke, etc.) works without any kernel-level routing.
This is beyond what QEMU's libslirp does — QEMU silently drops all mDNS.

### Restrict mode

```sh
esp-emu ... --net "user,restrict=yes"
```

Blocks all guest-initiated TCP/UDP except DNS. Useful for CI to prove a
firmware doesn't phone home.

### Limitations vs. TAP

- **Not reachable from the host by IP**: `ping 192.168.4.2` does not work.
  The guest IP lives inside the emulator process; use `hostfwd` to expose
  specific ports instead.
- **No packet capture on a host interface**: `tcpdump` sees nothing because
  the frames never leave user space. Use `RUST_LOG=esp_emu::net_user=trace`
  for backend-level tracing.
- Not yet implemented: IP fragmentation, TFTP server, `guestfwd`.

## TAP Networking

TAP mode bridges the emulated network (WiFi or Ethernet) to a host network interface, giving the firmware real TCP/IP connectivity. WiFi firmware uses the built-in DHCP server; Ethernet (OpenETH) firmware needs an external DHCP server on the TAP interface (e.g., dnsmasq). Use this mode when you need real LAN visibility (`ping`, `tcpdump`, multi-emulator bridging) — otherwise `--net user` above is easier.

### Linux (TAP)

```sh
# Create TAP interface with NAT (auto-detects outbound interface)
sudo ./tools/setup-tap.sh

# Run with TAP
esp-emu \
  --chip esp32c3 \
  --firmware app.bin \
  --net "tap,ifname=tap0"

# Cleanup
sudo ./tools/setup-tap.sh --teardown
```

### macOS (vmnet)

```sh
# vmnet requires sudo or com.apple.vm.networking entitlement
sudo esp-emu \
  --chip esp32c3 \
  --firmware app.bin \
  --net vmnet
```

## BLE Emulation

BLE firmware (NimBLE host stack) runs natively in the emulator. HCI commands are either handled by a built-in virtual controller or forwarded to an external backend via `--ble-hci`. Requires `--elf` to provide firmware symbols for HCI interception.

### Bumble (software-only, no hardware needed)

[Google Bumble](https://github.com/google/bumble) acts as a virtual BLE controller and GATT client over TCP.

```sh
pip3 install bumble
python3 tools/bumble_test.py &        # Virtual controller on port 9544
esp-emu \
  --chip esp32c3 \
  --firmware build/merged_flash.bin \
  --elf build/bleprph.elf \
  --ble-hci tcp:localhost:9544
```

The test script scans, connects, discovers GATT services, reads/writes characteristics, and subscribes to notifications. Works with both ESP32-C3 and ESP32-C6.

### Physical adapter (Linux)

Forward HCI to a real Bluetooth adapter for phone interaction:

```sh
sudo hciconfig hci0 down
sudo setcap 'cap_net_admin+eip' "$(command -v esp-emu)"
esp-emu \
  --chip esp32c3 \
  --firmware build/merged_flash.bin \
  --elf build/bleprph.elf \
  --ble-hci hci0
```

## Thread Emulation (ESP32-C6)

OpenThread `ot_cli` runs on an unmodified ESP32-C6 emulator — the node
boots, drives the CLI (`ot ifconfig up`, `ot thread start`, `ot state`,
`ot dataset …`), and becomes Leader of its own partition after MLE
attach times out (no peer to find).

```sh
esp-emu \
  --chip esp32c6 \
  --firmware /tmp/ot_cli_c6/build/merged_flash.bin \
  --elf /tmp/ot_cli_c6/build/esp_ot_cli.elf \
  --timeout 40s
```

For **two-node** Thread networks, `--thread-sim bind:P,peer:H:P` bridges
raw 802.15.4 frames between emulator instances over localhost UDP. With
both firmwares built using `OPENTHREAD_NETWORK_AUTO_START=y` (so they
share an identical compile-time Active Dataset), the second node joins
the first as a Child — verified with `ot state` + `ot parent` on the
device and matching `ot partitionid` on both sides.

```sh
# Border Router
esp-emu --chip esp32c6 \
  --firmware /tmp/ot_br_c6/build/merged_flash.bin \
  --elf /tmp/ot_br_c6/build/esp_ot_br.elf \
  --thread-sim "bind:9001,peer:127.0.0.1:9002" &
sleep 2
# End device
esp-emu --chip esp32c6 \
  --firmware /tmp/ot_cli_c6/build/merged_flash.bin \
  --elf /tmp/ot_cli_c6/build/esp_ot_cli.elf \
  --thread-sim "bind:9002,peer:127.0.0.1:9001"
```

See [docs/guides/THREAD.md](docs/guides/THREAD.md) for the full flow:
firmware builds (`ot_cli`, native-radio `ot_br`), shared-dataset setup,
trigger-based CLI injection, and troubleshooting.

## esptool / espefuse over `socket://`

esp-emu can expose its emulated UART as a TCP server so `esptool.py`, `espefuse.py`, and `idf.py flash` can drive it via `socket://host:port`, matching the workflow documented for [QEMU-Espressif](https://github.com/espressif/esp-toolchain-docs/blob/main/qemu/esp32c3/README.md#using-esptoolpy-and-espefusepy-to-interact-with-qemu).

### Setup

Two CLI flags work together:

- `--uart-tcp <HOST:PORT>` — bridges UART0 to a TCP server (mirrors QEMU's `-serial tcp::PORT,server,nowait`). One client at a time; the listener stays up across reconnects.
- `--strap-mode 0x02` — sets the strapping pin so the ROM enters UART download mode at reset. Without this the chip still boots normally from flash.

```sh
# Start the emulator in download mode with UART bridged to TCP 5555
esp-emu \
  --chip esp32c3 \
  --firmware build/merged_flash.bin \
  --efuse /tmp/qemu_efuse.bin \
  --strap-mode 0x02 \
  --uart-tcp 127.0.0.1:5555
```

In another shell, point esptool/espefuse at the socket. The `--no-stub --before no-reset --after no-reset` flags are required (see [Caveats](#caveats)):

```sh
# Identify the chip / read flash JEDEC
esptool.py -p socket://localhost:5555 --chip esp32c3 \
  --no-stub --before no-reset --after no-reset flash_id

# Write part of flash
esptool.py -p socket://localhost:5555 --chip esp32c3 \
  --no-stub --before no-reset --after no-reset \
  write_flash 0x100000 build/myapp.bin

# Burn an eFuse (custom MAC)
espefuse.py --port socket://localhost:5555 --chip esp32c3 \
  --do-not-confirm burn_custom_mac aa:bb:cc:dd:ee:ff

# Flash from idf.py
ESPPORT=socket://localhost:5555 idf.py flash
```

### What works

End-to-end verified on **C3, C6, and P4**:

| command                     | C3 | C6 | P4 |
|-----------------------------|----|----|----|
| `esptool chip-id`           | ✅ | ✅ | ✅ |
| `esptool flash-id`          | ✅ | ✅ | ✅ |
| `esptool read-mac`          | ✅ | ✅ | ✅ |
| `esptool read-flash`        | ✅ | ✅ | ✅ |
| `esptool write-flash`       | ✅ | ✅ | ✅ |
| `esptool verify-flash`      | ✅ | ✅ | ✅ |
| `esptool erase-region`      | ✅ | ✅ | ✅ |
| `espefuse summary`          | ✅ | ✅ | ✅ |
| `espefuse get-custom-mac`   | ✅ | ✅ | ✅ |
| `espefuse burn-custom-mac`  | ✅ | ✅ | ✅ |

eFuse burns persist back to the file passed via `--efuse <path>` on graceful exit (timeout, Ctrl+C, or `exit-on` match). Flash writes persist with `--save-state`.

### Caveats

- **`--no-stub` is required.** esptool's RAM-uploaded stub flasher is not yet wired through; ROM-mode commands work for everything in the table above and are slightly slower. Same caveat applies to QEMU-Espressif on C3.
- **`--before no-reset --after no-reset` are required.** RTS isn't transmissible over a TCP socket, so esptool can't auto-reset the target. To reboot the emulated chip, restart the `esp-emu` process.

## Building Firmware Images

The emulator runs merged flash binaries built with ESP-IDF. Requires ESP-IDF environment (`source export.sh`).

```sh
cd your-esp-idf-project
idf.py set-target esp32c3    # or esp32c6, esp32p4
idf.py build
idf.py merge-bin -o build/merged_flash.bin
```

## Releases

Binary tarballs (single-file artifacts containing only the `esp-emu` executable) are published as [GitHub Releases](https://github.com/mahavirj/esp-emulator/releases). Each release ships three assets:

- `esp-emu-<version>-x86_64-unknown-linux-gnu.tar.gz` — Linux x86_64 native
- `esp-emu-<version>-aarch64-apple-darwin.tar.gz` — macOS Apple Silicon native
- `esp-emu-<version>-wasm.tar.gz` — browser WebAssembly bundle
- `SHA256SUMS` — sha256 for each tarball; verified automatically by `install.sh`

## Docs

User guides live at [`docs/guides/`](docs/guides/) and track the latest release:

- [`BROWSER.md`](docs/guides/BROWSER.md) — running the WASM build in a browser
- [`MATTER.md`](docs/guides/MATTER.md) — Matter / Thread testing
- [`HOSTED.md`](docs/guides/HOSTED.md) — ESP-Hosted P4↔C6 setup
- [`THREAD.md`](docs/guides/THREAD.md) — 802.15.4 / OpenThread
- [`RAINMAKER.md`](docs/guides/RAINMAKER.md) — RainMaker provisioning flow

## Helper tools

Companion scripts live at [`tools/`](tools/):

- `setup-tap.sh` — create the `tap0` device for TAP networking on Linux
- `bumble_test.py` — virtual BLE controller (Google Bumble) over TCP for HCI testing
- `ws-net-proxy.py` / `ws-net-proxy.rs` — WebSocket↔raw-Ethernet bridge for the browser build
- `vhci_bridge.py` — Linux VHCI HCI bridge

## Manual install (without install.sh)

```sh
# Download the asset for your platform from
# https://github.com/mahavirj/esp-emulator/releases/latest
tar -xzf esp-emu-<version>-<platform>.tar.gz
cp esp-emu-<version>-<platform>/esp-emu ~/.local/bin/
~/.local/bin/esp-emu --help
```
