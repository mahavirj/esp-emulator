# Thread / 802.15.4 Emulation

Run ESP32-C6 Thread firmware (OpenThread-based `ot_cli` and `ot_br`) in
ESP-EMU. Single-node operation works out of the box; multi-node Thread
networks use the `--thread-sim` UDP bridge to connect two emulator
instances into one mesh.

## Overview

ESP32-C6 has both Wi-Fi and an IEEE 802.15.4 radio on the same die. The
emulator intercepts the open-source `esp_ieee802154_*` driver API at the
symbol level (EBREAK-patched via the application ELF), captures TX frames,
and injects RX frames back as `esp_ieee802154_receive_done()` upcalls via a
WFI-time trampoline — the same pattern used for BLE HCI. No MMIO model
for the IEEE 802.15.4 peripheral is needed because the hardware-touching
driver functions are stubbed wholesale.

```
  emulator A (ot_cli)         emulator B (ot_cli or ot_br)
  ┌─────────────────┐         ┌─────────────────┐
  │ OpenThread      │         │ OpenThread      │
  │   ↕             │         │   ↕             │
  │ esp_ieee802154_*│ ← stub  │ esp_ieee802154_*│ ← stub
  │   ↓ frame       │         │   ↑ frame       │
  │ thread_radio.rs │         │ thread_radio.rs │
  └────── UDP ──────┴─────────┴──── UDP ────────┘
```

Overhead: a tiny, localhost-bound UDP socket per emulator instance.

## Prerequisites

- ESP-IDF environment sourced (`source /path/to/esp-idf/export.sh`)
- Target chip: `esp32c6` (the only chip with both Wi-Fi and 802.15.4
  currently supported by the emulator)
- `esp-emu` installed and on your `PATH`

## Single-node `ot_cli`

This is the minimum setup — one emulator, no bridge. The node forms its
own Thread partition (no peer to attach to) and becomes Leader.

### Build the firmware

```sh
cp -r $IDF_PATH/examples/openthread/ot_cli /tmp/ot_cli_c6
cd /tmp/ot_cli_c6
idf.py set-target esp32c6
idf.py build
cd build && python -m esptool --chip esp32c6 merge-bin -o merged_flash.bin @flash_args
```

Artefacts: `/tmp/ot_cli_c6/build/merged_flash.bin` and
`/tmp/ot_cli_c6/build/esp_ot_cli.elf`.

### Run

```sh
./esp-emu \
  --chip esp32c6 \
  --firmware /tmp/ot_cli_c6/build/merged_flash.bin \
  --elf /tmp/ot_cli_c6/build/esp_ot_cli.elf \
  --timeout 40s
```

`--elf` is required — the emulator reads IEEE 802.15.4 driver symbols
from it to install interception stubs.

### Drive the CLI

Because the CLI prompt is only ready after OpenThread finishes booting,
trigger the first command on the `"OpenThread enter mainloop"` marker, not
on the early `esp32c6>` prompt:

```sh
./esp-emu ... \
  --inject-on "OpenThread enter mainloop" --inject "ot ifconfig up\r\n" \
  --inject-on "OT_STATE: netif up"         --inject "ot thread start\r\n" \
  --inject-on "Role detached -> leader"    --inject "ot state\r\n"
```

Expected flow (~8 s):

```
Role disabled -> detached
Attach attempt 1, AnyPartition
Allocate router id N
RLOC16 fffe -> ....
Role detached -> leader
Partition ID 0x........
```

A lone node with no peers always ends up Leader after MLE attach times
out.

## Two-node network with the UDP bridge

`--thread-sim bind:<PORT>,peer:<HOST>:<PORT>` forwards 802.15.4 frames
between two emulator instances over localhost UDP. Frames carry the raw
PHY payload `[length_byte][PSDU incl FCS]` — no proprietary framing.

For two nodes to form **one** Thread partition (rather than each becoming
its own Leader) they must share an Active Dataset. The easiest way is to
build both firmware images with `OPENTHREAD_NETWORK_AUTO_START=y` — the
dataset is then loaded from compile-time Kconfig values (`network name`,
`channel`, `panid`, `extpanid`, `master key`, `PSKc`), which default to
identical values across examples.

### Rebuild with auto-start on both sides

```sh
cp -r $IDF_PATH/examples/openthread/ot_cli /tmp/ot_cli_c6
echo 'CONFIG_OPENTHREAD_NETWORK_AUTO_START=y' > /tmp/ot_cli_c6/sdkconfig.emu
cd /tmp/ot_cli_c6
SDKCONFIG_DEFAULTS='sdkconfig.defaults;sdkconfig.emu' idf.py set-target esp32c6
SDKCONFIG_DEFAULTS='sdkconfig.defaults;sdkconfig.emu' idf.py build
cd build && python -m esptool --chip esp32c6 merge-bin -o merged_flash.bin @flash_args
```

### Run both nodes

Two shells. Node A binds `:9001`, sends to `:9002`; node B binds `:9002`,
sends to `:9001`:

```sh
# shell A
./esp-emu --chip esp32c6 \
  --firmware /tmp/ot_cli_c6/build/merged_flash.bin \
  --elf /tmp/ot_cli_c6/build/esp_ot_cli.elf \
  --thread-sim "bind:9001,peer:127.0.0.1:9002" \
  --timeout 40s

# shell B
./esp-emu --chip esp32c6 \
  --firmware /tmp/ot_cli_c6/build/merged_flash.bin \
  --elf /tmp/ot_cli_c6/build/esp_ot_cli.elf \
  --thread-sim "bind:9002,peer:127.0.0.1:9001" \
  --timeout 40s
```

Whichever node starts first becomes Leader; the second node detects the
Leader's MLE Advertisement, transitions `leader → detached → child`, and
joins the same partition. Verify with `ot state`, `ot rloc16`, and
`ot partitionid` on both nodes — the partition IDs must match.

## Border Router + end device

`ot_br` runs the OpenThread Border Router stack on C6 in native-radio
mode (no external RCP). The device side is the same `ot_cli` build from
above.

### Build `ot_br` for C6 native radio

The stock `ot_br` example defaults to a two-chip setup (Wi-Fi host +
external H2 RCP over UART) and ships with the CLI disabled. Enable
native radio, the CLI, and point Wi-Fi STA at the emulator's built-in
SoftAP:

```sh
cp -r $IDF_PATH/examples/openthread/ot_br /tmp/ot_br_c6
cat > /tmp/ot_br_c6/sdkconfig.emu <<'EOF'
CONFIG_OPENTHREAD_RADIO_NATIVE=y
CONFIG_OPENTHREAD_RADIO_SPINEL_UART=n
CONFIG_ESP_COEX_SW_COEXIST_ENABLE=y
CONFIG_OPENTHREAD_NETWORK_AUTO_START=y
CONFIG_OPENTHREAD_BR_AUTO_START=y
CONFIG_EXAMPLE_WIFI_SSID="myssid"
CONFIG_EXAMPLE_WIFI_PASSWORD="mypassword"
CONFIG_EXAMPLE_CONNECT_WIFI=y
CONFIG_EXAMPLE_CONNECT_ETHERNET=n
CONFIG_OPENTHREAD_CLI=y
CONFIG_OPENTHREAD_CONSOLE_ENABLE=y
EOF
cd /tmp/ot_br_c6
SDKCONFIG_DEFAULTS='sdkconfig.defaults;sdkconfig.emu' idf.py set-target esp32c6
SDKCONFIG_DEFAULTS='sdkconfig.defaults;sdkconfig.emu' idf.py build
cd build && python -m esptool --chip esp32c6 merge-bin -o merged_flash.bin @flash_args
```

### Run the topology

```sh
# BR first (port 9001)
./esp-emu --chip esp32c6 \
  --firmware /tmp/ot_br_c6/build/merged_flash.bin \
  --elf /tmp/ot_br_c6/build/esp_ot_br.elf \
  --thread-sim "bind:9001,peer:127.0.0.1:9002" \
  --timeout 55s &
sleep 2

# Device (port 9002)
./esp-emu --chip esp32c6 \
  --firmware /tmp/ot_cli_c6/build/merged_flash.bin \
  --elf /tmp/ot_cli_c6/build/esp_ot_cli.elf \
  --thread-sim "bind:9002,peer:127.0.0.1:9001" \
  --timeout 53s &
wait
```

Expected topology:

| | BR | Device |
|---|---|---|
| `ot state` | `leader` | `child` |
| `ot rloc16` | `0xNN00` | `0xNN01` |
| `ot partitionid` | `0x........` | identical to BR |
| `ot parent` (device) | — | `Rloc: 0xNN00`, BR's ext addr |

The device's RLOC16 is `BR_RLOC16 + 1`, confirming the BR is the parent.

### Known limitation — Wi-Fi backbone

`ot_br` calls `example_connect()` before bringing up the border-router
component, which expects a Wi-Fi STA association with an upstream AP.
Inside one emulator instance, the BR's STA loops to the same process's
built-in SoftAP, which is fragile; Thread formation and device
attachment work regardless because they don't depend on the Wi-Fi path,
but BR-specific backbone features (NAT64, SRP server, DNS-SD
advertisement onto Wi-Fi) remain unverified. For a real backbone, run
the BR with `--net "tap,ifname=tap0"` pointed at a host bridge and keep
the device on `--net user`.

## How the bridge works

- **CLI flag**: `--thread-sim bind:<port>,peer:<host>:<port>` (either
  side is optional — bind-only emulator can only receive, peer-only can
  only send). Localhost bind only.
- **Wire format**: raw UDP datagram, one 802.15.4 PHY frame per
  datagram. Byte 0 is the length (including FCS), bytes 1..=length hold
  PSDU + FCS.
- **TX path**: firmware's `esp_ieee802154_transmit()` is EBREAK-patched.
  The stub reads the frame from guest RAM, sends it as UDP, and queues a
  `esp_ieee802154_transmit_done()` upcall for the next WFI tick.
- **RX path**: incoming UDP frames are copied into emulator-private LP
  RAM scratch (`0x50004200+` on C6). When the firmware next issues a WFI
  and has called `esp_ieee802154_enable()`, a trampoline injects
  `esp_ieee802154_receive_done(frame, frame_info)` on its behalf.
- **Event gating**: upcalls fire only after `esp_ieee802154_enable()`
  succeeds. This avoids a race where `receive_done` runs before
  `esp_openthread_radio_init()` has created the radio `eventfd`, which
  would trip an assertion in `set_event()` inside
  `esp_openthread_radio.c`.

## Troubleshooting

**`ot` commands return `Unrecognized command`**

OpenThread registers its CLI after `esp_openthread_init()` completes.
Don't trigger on the first `esp32c6>` prompt — use
`--inject-on "OpenThread enter mainloop"` (appears ~1.1 s after boot).

**Both nodes end up `leader` of different partitions**

They have different Active Datasets. Either:
- Rebuild both firmwares with `OPENTHREAD_NETWORK_AUTO_START=y` so both
  auto-load the identical compile-time dataset (recommended).
- Or run `ot dataset active -x` on one node to print the TLV hex, then
  inject `ot dataset set active <hex>` on the other. This works thanks
  to the level-triggered UART RX fix (see `src/periph/uart.rs`) — long
  inject payloads (>31 bytes) now process correctly.

**`assert(ret == sizeof(event_write))` on Node B after the first RX frame**

Symptom: Node B panics soon after startup when Node A starts
transmitting. Cause: a pre-2026-04 build of the emulator fired
`receive_done` before `esp_openthread_radio_init()` was done. Fixed by
gating event delivery on the `enabled` flag set by the `thr_enable` stub.
Rebuild the emulator from current source.

**Device stays `detached` forever (no attachment)**

- Verify the bridge actually transports frames: run with
  `RUST_LOG=esp_emu::periph::thread_radio=debug` and check for
  `Thread: TX` and `Thread: RX` log lines on both sides.
- Confirm both nodes have the same channel (`ot channel`) and panid
  (`ot panid`).

## Reference

- Implementation: [`src/periph/thread_radio.rs`](../../src/periph/thread_radio.rs)
- Interception dispatch: [`src/machine/rom_stubs.rs`](../../src/machine/rom_stubs.rs) (search for `thr_*`)
- ESP-IDF sources:
  - `$IDF_PATH/components/openthread/src/port/esp_openthread_radio.c` — otPlatRadio → esp_ieee802154 wrappers and upcall implementations
  - `$IDF_PATH/components/ieee802154/include/esp_ieee802154.h` — public driver API
  - `$IDF_PATH/examples/openthread/ot_cli/`, `$IDF_PATH/examples/openthread/ot_br/`
