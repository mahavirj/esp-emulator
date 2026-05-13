# Matter Commissioning

This document describes how to commission and control Matter devices running in ESP-EMU using chip-tool.

## Overview

Matter devices use BLE for commissioning (PASE key exchange + network credential provisioning) and then switch to WiFi/IP for operational control. ESP-EMU supports this full flow using a VHCI bridge that connects chip-tool's BlueZ BLE stack to the emulator's virtual BLE controller via [Google Bumble](https://github.com/google/bumble).

```
chip-tool → BlueZ → /dev/vhci → Bumble Controller ←LocalLink→ Bumble Controller ← TCP ← esp-emu
                                  (bluez-side)                    (emu-side)
```

After commissioning, the device communicates over WiFi/IPv6 through the TAP interface — no bridge needed for operational commands.

## Prerequisites

### Install chip-tool

```bash
sudo snap install chip-tool
sudo snap connect chip-tool:avahi-observe
sudo snap connect chip-tool:bluez
```

### Install Bumble

```bash
pip3 install bumble
```

### VHCI device permissions

The bridge needs access to `/dev/vhci`. Either run with `sudo` or fix permissions:

```bash
sudo chmod 666 /dev/vhci
```

For a persistent rule:

```bash
echo 'KERNEL=="vhci", MODE="0666"' | sudo tee /etc/udev/rules.d/99-vhci.rules
sudo udevadm trigger
```

### Networking (pick one)

**Option A — user-mode networking with mDNS NAT (no host setup, recommended):**

```bash
./esp-emu ... --net "user,mdns-nat=yes" ...
```

`mdns-nat=yes` rewrites the guest's mDNS A/AAAA records to `127.0.0.1` / `::1`
and auto-binds host UDP+TCP listeners on `127.0.0.1:<SRV-port>` that forward
to the guest. chip-tool's Matter resolver sees the device at `127.0.0.1:5540`
and CASE/operational traffic bridges through automatically. End-to-end
commissioning, toggling, and attribute reads all work over user-mode
networking.

**Option B — TAP interface (full L2 bridge to the host network):**

```bash
sudo ip tuntap add dev tap0 mode tap user $USER
sudo ip addr add 192.168.4.1/24 dev tap0
sudo ip link set tap0 up
# then run esp-emu with --net "tap,ifname=tap0"
```

Use TAP when you need the guest reachable on the LAN, want `tcpdump` on the
wire, or are running multiple emulators talking to each other.

### Build ESP-EMU

```bash
cargo build --release
```

## Building Matter firmware

Use ESP-IDF with ESP-Matter to build a Matter application (e.g., the light example):

```bash
cd esp-matter/examples/light
idf.py set-target esp32c3
idf.py build
```

Create a merged flash image:

```bash
cd build
esptool.py --chip esp32c3 merge-bin \
  --flash-mode dio --flash-freq 80m --flash-size 4MB \
  $(cat flash_args) \
  -o merged_flash.bin
```

## Running

### Step 1: Start the VHCI bridge

```bash
python3 tools/vhci_bridge.py
```

The bridge opens `/dev/vhci` (creating a new `hciX` adapter visible to BlueZ), prints the adapter index, and then waits for esp-emu to connect on TCP port 9544:

```
[*] Opening /dev/vhci...
[+] VHCI adapter registered as hci1
    Use: chip-tool pairing ble-wifi ... --ble-controller 1
[*] Starting TCP server on port 9544, waiting for esp-emu...
```

Note the `--ble-controller` number — you'll need it for chip-tool.

### Step 2: Start ESP-EMU

```bash
./esp-emu \
  --chip esp32c3 \
  --firmware build/merged_flash.bin \
  --elf build/light.elf \
  --ble-hci tcp:localhost:9544 \
  --timeout 180s
```

Wait for the firmware to print:

```
CHIPoBLE advertising started
Commissioning window opened
```

### Step 3: Commission with chip-tool

```bash
chip-tool pairing ble-wifi \
  <node-id> <ssid> <password> <setup-pin-code> <discriminator> \
  --ble-controller <N>
```

Example with default Matter test credentials:

```bash
chip-tool pairing ble-wifi 1 myssid mypassword 20202021 3840 --ble-controller 1
```

- **node-id**: Arbitrary ID you assign to the device (e.g., `1`)
- **ssid/password**: Must match `--wifi-ssid`/`--wifi-password` passed to esp-emu (defaults: `myssid`/`mypassword`)
- **setup-pin-code**: The Matter pairing PIN from the firmware (default test PIN: `20202021`)
- **discriminator**: From the firmware's advertisement (default: `3840`)
- **--ble-controller N**: The VHCI adapter index from step 1

A successful commissioning prints:

```
Device commissioning completed with success
```

### Step 4: Control the device

After commissioning, the device is on the WiFi network and responds to Matter commands over IP. The VHCI bridge is no longer needed.

```bash
# Turn on
chip-tool onoff on 1 1 --timeout 25

# Turn off
chip-tool onoff off 1 1 --timeout 25

# Read on/off state
chip-tool onoff read on-off 1 1 --timeout 25

# Toggle
chip-tool onoff toggle 1 1 --timeout 25
```

The first argument after the command is the node-id (from commissioning), the second is the endpoint (typically `1` for the primary device).

Use `--timeout 25` since the emulated network is slower than real hardware — mDNS resolution may take ~13 seconds as chip-tool tries each network interface, and CASE session establishment adds a few more seconds.

## Persisting state across reboots

Use `--save-state` to save flash (NVS, fabric credentials, WiFi config) when esp-emu exits. On the next boot the device skips commissioning and auto-joins WiFi.

### First boot: commission and save

```bash
# Work on a copy so the original firmware stays clean
cp build/merged_flash.bin /tmp/matter-test.bin

# Start bridge + esp-emu with --save-state
python3 tools/vhci_bridge.py &
./esp-emu \
  --chip esp32c3 \
  --firmware /tmp/matter-test.bin \
  --elf build/light.elf \
  --ble-hci tcp:localhost:9544 \
  --save-state \
  --timeout 60s

# Commission while running...
chip-tool pairing ble-wifi 1 myssid mypassword 20202021 3840 --ble-controller 1

# Let esp-emu exit via --timeout (or Ctrl+C) — flash is saved on clean exit
```

**Important**: The flash is saved when esp-emu exits via timeout or Ctrl+C. Killing the process with `kill -9` bypasses the save.

### Second boot: auto-join

```bash
# No bridge needed — device is already commissioned
./esp-emu \
  --chip esp32c3 \
  --firmware /tmp/matter-test.bin \
  --elf build/light.elf \
  --timeout 60s
```

The device boots, prints `Fabric already commissioned. Disabling BLE advertisement`, auto-connects to WiFi, and advertises `_matter._tcp` via mDNS. chip-tool can control it immediately:

```bash
chip-tool onoff toggle 1 1 --timeout 25
```

## How it works

### VHCI bridge (`tools/vhci_bridge.py`)

The bridge creates two Bumble virtual BLE controllers on a shared `LocalLink`:

1. **bluez-controller**: Connected to `/dev/vhci`. BlueZ auto-discovers it as a real Bluetooth adapter. chip-tool's BLE operations (scan, connect, GATT) go through this controller.

2. **emu-controller**: Listens on TCP port 9544. esp-emu connects here and forwards HCI packets from the firmware's NimBLE stack.

Both controllers share a `LocalLink` which acts as a virtual radio — advertising PDUs, connection requests, and ACL data packets are relayed between them.

A `PinnedAddressController` subclass prevents BlueZ from changing the random address used for LocalLink ACL routing, which would otherwise break the address mapping between controllers.

### Commissioning flow

1. **BLE discovery**: chip-tool scans via BlueZ → bluez-controller sees advertising PDUs from emu-controller → reports Matter service UUID `0xFFF6` with discriminator
2. **BLE connection**: BlueZ initiates LE connection → both controllers establish connection handles → ACL data flows bidirectionally
3. **BTP handshake**: chip-tool discovers Matter GATT service, subscribes to TX characteristic, writes capabilities request to RX characteristic → BTP v4 negotiated
4. **PASE (SPAKE2+)**: Secure session established using the setup PIN code (Pake1 → Pake2 → Pake3)
5. **Commissioning stages**: ReadCommissioningInfo → ArmFailSafe → Attestation → CSR → NOC → WiFiNetworkSetup → WiFiNetworkEnable → FindOperational → SendComplete
6. **WiFi handoff**: Device connects to the soft AP via TAP, gets IPv6 address, advertises `_matter._tcp` via mDNS
7. **CASE session**: chip-tool discovers device via mDNS, establishes operational CASE session over WiFi/UDP
8. **CommissioningComplete**: Sent over CASE session, commissioning finishes

### Operational control

Post-commissioning commands use CASE (Certificate Authenticated Session Establishment) over WiFi/IPv6 link-local addresses through the TAP interface. Each chip-tool invocation re-establishes a CASE session, which adds a few seconds of overhead.

## Troubleshooting

### "BLE adapter unavailable"

Wrong `--ble-controller` index. Run `hciconfig` to find the Virtual adapter number.

### Commissioning times out after BLE connect

ACL data isn't flowing. Check the bridge logs (`-v` flag) for `!!! no connection for` warnings. This was fixed by `PinnedAddressController` — make sure you're using the latest `vhci_bridge.py`.

### chip-tool commands time out after commissioning

The emulated network is slower than real hardware. Add `--timeout 25` (or higher) to chip-tool commands. The first command after commissioning is slowest due to CASE session establishment.

### "Unknown HCI Command" in NimBLE logs

```
ogf=0x08, ocf=0x004e, hci_err=0x201 : BLE_ERR_UNKNOWN_HCI_CMD
```

This is NimBLE trying `LE Set Privacy Mode`, which Bumble's controller doesn't support. It's harmless — the firmware handles the error and continues.

### Port 9544 already in use

A previous bridge instance is still running. Kill it with `pkill -f vhci_bridge` or use `--port <other>` on both the bridge and esp-emu.

## OTA Updates

Matter OTA updates can be tested end-to-end using chip-ota-provider-app as the OTA provider and the emulated device as the OTA requestor.

### Prerequisites

- A commissioned Matter device running in esp-emu (see steps above)
- chip-ota-provider-app (from connectedhomeip)
- An OTA image with Matter header (generated via `ota_image_tool.py` or `CONFIG_CHIP_OTA_IMAGE_BUILD`)

The OTA image must have a higher `software-version` than the running firmware.

### Step 1: Start the OTA provider

```bash
chip-ota-provider-app \
  --discriminator 22 \
  --secured-device-port 5565 \
  --KVS /tmp/chip_kvs_provider \
  --filepath <ota-image.bin>
```

### Step 2: Commission the OTA provider

```bash
chip-tool pairing onnetwork-long <provider-node-id> 20202021 22
```

### Step 3: Set ACL on the provider

The provider needs an ACL entry allowing any node to access the OTA Provider cluster (0x0029):

```bash
chip-tool accesscontrol write acl \
  '[{"fabricIndex": 1, "privilege": 5, "authMode": 2, "subjects": [112233], "targets": null},
    {"fabricIndex": 1, "privilege": 3, "authMode": 2, "subjects": null, "targets": [{"cluster": 41, "endpoint": null, "deviceType": null}]}]' \
  <provider-node-id> 0 --timeout 25
```

### Step 4: Trigger OTA

```bash
chip-tool otasoftwareupdaterequestor announce-otaprovider \
  <provider-node-id> 0 0 0 <device-node-id> 0 --timeout 25
```

The device queries the provider, downloads the image via BDX (Bulk Data Transfer), writes it to the OTA flash partition, and reboots into the new firmware.

### Verifying

```bash
chip-tool basicinformation read software-version <device-node-id> 0 --timeout 25
```

**Note**: Use `--save-state` on esp-emu so flash state (including the OTA partition) persists across reboots. Work on a copy of the firmware file since `--save-state` overwrites it.

## Bridge options

```
python3 tools/vhci_bridge.py [options]

  --port PORT           TCP port for esp-emu (default: 9544)
  --emu-address ADDR    BT address for emu-side controller (default: 00:11:22:33:44:55)
  --bluez-address ADDR  BT address for BlueZ-side controller (default: AA:BB:CC:DD:EE:FF)
  -v, --verbose         Enable debug logging (shows all HCI commands and ACL data)
```
