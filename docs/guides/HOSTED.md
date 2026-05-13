# ESP-Hosted (P4 ↔ C6 SDIO) Emulation

Run the [ESP-Hosted MCU](https://github.com/espressif/esp-hosted-mcu) demo
end-to-end inside ESP-EMU: an ESP32-P4 host (no native Wi-Fi/BLE) talks
over SDIO to an ESP32-C6 slave that brings up Wi-Fi + BLE on the host's
behalf. Two emulator processes are bridged through a Unix-domain stream
socket — no real hardware required.

## Overview

ESP-Hosted is Espressif's protocol for using a wireless co-processor over
SDIO/SPI/UART. ESP-EMU emulates the SDIO transport between the two MCUs:

```
  P4 instance (peer_data_example)         C6 instance (network_adapter)
  ┌─────────────────────────────┐         ┌─────────────────────────────┐
  │ peer_data app               │         │ Wi-Fi / BLE stack           │
  │   ↕ esp_hosted_*            │         │   ↕ slave RPC handler       │
  │ SDMMC host driver           │         │ SDIO slave driver           │
  │   ↕                         │         │   ↕                         │
  │ Synopsys MSHC + IDMAC model │         │ SLC / SLCHOST model         │
  │  (sdmmc_host.rs, BridgePeer)│         │  (sdio_slave.rs)            │
  └────────── Unix SOCK_STREAM ─┴─────────┴── (sdio_bridge.rs) ─────────┘
```

The bridge carries framed CMD52 / CMD53 / INT_RAISE messages. CMD52
exchanges run inline; CMD53 chains are walked through guest IDMAC
descriptors so DMA scatter-gather works exactly as on real silicon. DAT1
(the SDIO IO interrupt line) is mirrored to GPIO 15 on the host so
IDF's `gpio_get_level()` fast-path drains queued packets without a
syscall.

## Prerequisites

- ESP-IDF v5.5 or newer environment sourced
  (`source $IDF_PATH/export.sh`).
- `esp-hosted-mcu` checked out for the firmware sources. Either:
  - Add it as a managed component to your project, or
  - Clone `https://github.com/espressif/esp-hosted-mcu` and follow its
    `examples/` README.
- ESP-EMU built: `cargo build --release`. The emulator binary is at
  `./target/release/esp-emu`.

## Build the firmware images

You need two firmware images: the **slave** (C6) and the **host** (P4).

### C6 slave: `network_adapter`

The standard ESP-Hosted slave firmware. It exposes SDIO endpoints and
runs Wi-Fi + BLE locally on the C6 on the host's behalf.

```sh
cp -r <esp-hosted-mcu>/slave /tmp/hosted_c6_build
cd /tmp/hosted_c6_build
idf.py set-target esp32c6
idf.py build
cd build && python -m esptool --chip esp32c6 merge-bin -o merged_flash.bin @flash_args
```

Artefacts:
- `/tmp/hosted_c6_build/build/merged_flash.bin`
- `/tmp/hosted_c6_build/build/network_adapter.elf`

### P4 host: `peer_data_example`

The example host application that exercises the RPC path with
synthetic peer messages (MEOW / WOOF / HELLO).

```sh
cp -r <esp-hosted-mcu>/examples/peer_data_example /tmp/hosted_p4_build
cd /tmp/hosted_p4_build
idf.py set-target esp32p4
idf.py build
cd build && python -m esptool --chip esp32p4 merge-bin -o merged_flash.bin @flash_args
```

Artefacts:
- `/tmp/hosted_p4_build/build/merged_flash.bin`
- `/tmp/hosted_p4_build/build/peer_data_example.elf`

> The P4 emulator's boot stack assumes rev>=3 layout (`__stack =
> 0x4FFBCFC0`), which matches `CONFIG_ESP32P4_REV_MIN_FULL=301` —
> ESP-IDF's default for P4 v5.5+.

## Run the demo

The slave must be started first so its Unix socket is listening when the
host connects.

### 1. Start the C6 slave

```sh
rm -f /tmp/hosted_demo.sock
RUST_LOG=info ./target/release/esp-emu \
  --chip esp32c6 \
  --firmware /tmp/hosted_c6_build/build/merged_flash.bin \
  --elf /tmp/hosted_c6_build/build/network_adapter.elf \
  --hosted bridge:slave:/tmp/hosted_demo.sock \
  --net user \
  --timeout 30s
```

`--elf` is required for symbol-based interception of the slave-side
Wi-Fi/BLE blob entry points. `--net user` gives the slave NAT'd
networking so it can actually reach the outside world on the host's
behalf.

### 2. Start the P4 host (in a second terminal, ~2 s later)

```sh
RUST_LOG=info ./target/release/esp-emu \
  --chip esp32p4 \
  --firmware /tmp/hosted_p4_build/build/merged_flash.bin \
  --elf /tmp/hosted_p4_build/build/peer_data_example.elf \
  --hosted bridge:host:/tmp/hosted_demo.sock \
  --timeout 25s
```

The host connects to the slave's Unix socket; the SDMMC host driver
enumerates the slave card; transport reaches `TRANSPORT_TX_ACTIVE` and
`peer_data_example` registers its RPC callbacks.

### Expected output (host side)

```
H_SDIO_DRV: SDIO host init starting
H_SDIO_DRV: Card detected
hosted_sdio: SDIO card initialized
transport: ESP-Hosted slave detected
peer_data_example: Response callbacks registered: MEOW, WOOF, HELLO
peer_data_example: Cycle 1 — sending CAT
slave ---> host: CAT/MEOW
peer_data_example: Cycle 2 — sending DOG
slave ---> host: DOG/WOOF
peer_data_example: Cycle 3 — sending HI
slave ---> host: HI/HELLO
```

### Expected output (slave side)

```
co-pro-main: Start Data Path
slave_rpc: event ESPInit
slave: Received CAT, replying MEOW
slave: Received DOG, replying WOOF
slave: Received HI, replying HELLO
```

## CLI reference

The bridge is configured via `--hosted=<spec>`, two forms:

| Spec | Side | Behaviour |
|------|------|-----------|
| `bridge:host:<path>` | P4 host | Connects to an existing slave socket. Required `--chip esp32p4`. |
| `bridge:slave:<path>` | C6 slave | Binds and listens on `<path>`. Required `--chip esp32c6`. |

The transport is a length-prefixed Unix `SOCK_STREAM` so it never drops
bytes — even at high RPC throughput the queue grows on either side
without packet loss.

## Troubleshooting

### Slave already running on this socket

```
Failed to bind slave socket /tmp/hosted_demo.sock: Address already in use
```

Remove the stale socket file (`rm -f /tmp/hosted_demo.sock`) before
starting the slave. The previous run may have crashed before
unlinking.

### Host can't connect

```
Failed to connect to slave socket /tmp/hosted_demo.sock: ...
(Did you start the slave instance first?)
```

The slave must already be listening. Watch for `H_SDIO_DRV: Card
detected` on the host side once both processes are up.

### Host hangs at "Starting SDIO process rx task"

The slave's SLCINTVEC_TOHOST writes aren't reaching the host. Verify:
- both sides are running the same `esp-hosted-mcu` version,
- you used `network_adapter` for the slave (not a custom firmware that
  skips `sdio_init()`).

### Demo flakiness

`peer_data_example` has a known firmware-side producer-consumer race
in `process_rx_task` that can cause "task still writing Rx data to
queue!" warnings and occasionally drop one of the three RPC echoes per
run. This is not an emulator bug — running again usually clears it.

## Other verified host firmware

The same C6 slave (`network_adapter`) supports any ESP-IDF firmware that
needs the C6 to act as the radio. Confirmed working on the P4 host side
through the same SDIO bridge:

| P4 host firmware | What it exercises |
|---|---|
| [`esp-hosted-mcu/examples/host_peer_data_transfer`](https://github.com/espressif/esp-hosted-mcu/tree/main/examples/host_peer_data_transfer) | RPC custom-data echo (CAT/DOG/HUMAN ↔ MEOW/WOOF/HELLO) at 1 B – 8166 B payloads |
| `$IDF_PATH/examples/wifi/getting_started/station` | STA connect + DHCP + IPv6 SLAAC |
| `$IDF_PATH/examples/wifi/scan` | Active scan + AP list |
| `$IDF_PATH/examples/wifi/iperf` | Console-driven STA + DHCP (connect phase) |
| `$IDF_PATH/examples/protocols/http_request` | HTTP GET to example.com (DNS + TCP) |
| `$IDF_PATH/examples/protocols/https_request` | TLS 1.3 handshake + HTTPS GET |

The IDF `wifi/*` and `protocols/*` examples auto-pull the
`espressif/esp_hosted` managed component when their target is
`esp32p4`, so you don't have to wire it up manually — just
`idf.py set-target esp32p4 && idf.py build`. For `protocols/*`
examples, override the default Ethernet path with WiFi by adding
`espressif/esp_hosted` to the project's `main/idf_component.yml` (rules
gated on target) and setting `CONFIG_EXAMPLE_CONNECT_WIFI=y`,
`CONFIG_EXAMPLE_WIFI_SSID="myssid"`,
`CONFIG_EXAMPLE_WIFI_PASSWORD="mypassword"` in `sdkconfig.defaults`.

## How it works (under the hood)

For implementation details — sticky host→slave INTs, the dummy descriptor
filter on `send_isr_invoker_enable`, streaming-mode CMD53 multi-packet
packing, DAT1 edge sampling, IDMAC chain walking — refer to the source:

- `src/periph/sdio_bridge.rs` — wire protocol + Unix socket transport
- `src/periph/esp32p4/sdmmc_host.rs` — Synopsys MSHC + IDMAC model
- `src/periph/esp32c6/sdio_slave.rs` — SLC + SLCHOST model
- `src/mem/bus.rs` — `execute_pending_sdmmc_cmd53` + slave RX/TX walkers

## Debugging

A handful of env-gated debug knobs help trace memory corruption, task
starvation, and bus writes inside the bridged demo:

- `ESP_EMU_DEBUG_PC_SAMPLE=1` — periodic per-hart PC sampler
- `ESP_EMU_DEBUG_PC_TRIGGER=0xADDR` — load-watch / fault dump on a PC
- `ESP_EMU_DEBUG_LOAD_FAULTS=1` — log every load that traps
- `ESP_EMU_DEBUG_WATCH_LO/HI` — bus-write watcher window
- `ESP_EMU_DEBUG_TASK_SAMPLE` — periodic task-running histogram

These are gated on `#[cfg(debug_assertions)]` and only fire in debug
builds.
