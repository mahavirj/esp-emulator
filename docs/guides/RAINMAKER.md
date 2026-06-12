# ESP RainMaker Provisioning

This document describes how to provision an ESP RainMaker device running in ESP-EMU using `esp-rainmaker-cli` over BLE.

## Overview

RainMaker firmware (e.g. the `switch` example) starts in BLE provisioning mode on first boot — NimBLE advertises as `PROV_xxxxxx`, exposes the standard `wifi_prov_mgr` GATT endpoints plus a RainMaker-specific `cloud_user_assoc` endpoint, and waits for a phone app or `esp-rainmaker-cli` to push Wi-Fi credentials. ESP-EMU runs that firmware unchanged: BLE traffic flows through the [VHCI bridge](./MATTER.md#vhci-bridge-toolsvhci_bridgepy) so BlueZ sees the emulator as a real `hciX` adapter, and the new `--ble_adapter` flag in `esp-rainmaker-cli` selects that adapter.

```
esp-rainmaker-cli → BlueZ → /dev/vhci → Bumble Controller ←LocalLink→ Bumble Controller ← TCP ← esp-emu
                              (--ble_adapter hci1)        (bluez-side)            (emu-side)
```

After the BLE handoff the device joins the emulator's Wi-Fi soft-AP through user-mode networking; outbound traffic to the RainMaker cloud goes through the smoltcp NAT.

## Prerequisites

### Install esp-rainmaker-cli

The `--ble_adapter` flag landed on the `feat/ble-adapter-option` branch. Until it ships in a PyPI release, install in editable mode:

```bash
git clone git@github.com:espressif/esp-rainmaker-cli.git
cd esp-rainmaker-cli
git checkout feat/ble-adapter-option
python3 -m pip install -e .
```

Verify the flag is exposed:

```bash
esp-rainmaker-cli provision --help | grep -A 2 ble_adapter
#  --ble_adapter BLE_ADAPTER
#                        HCI adapter to use for BLE transport (default: hci0).
#                        Useful with vhci_bridge for emulated devices, e.g. --ble_adapter hci1
```

Log in once so the CLI has a RainMaker session:

```bash
esp-rainmaker-cli login
```

### Install Bumble (for the bridge)

```bash
pip3 install bumble
```

### VHCI device permissions

The bridge needs access to `/dev/vhci`. Either run it under `sudo` or relax the permissions once:

```bash
sudo chmod 666 /dev/vhci
```

For a persistent rule:

```bash
echo 'KERNEL=="vhci", MODE="0666"' | sudo tee /etc/udev/rules.d/99-vhci.rules
sudo udevadm trigger
```

### Install ESP-EMU

Make sure `esp-emu` is installed and on your `PATH`.

## Building RainMaker firmware

Use the canonical `switch` example from `esp-rainmaker`. Two sdkconfig tweaks are needed for emulator runs:

- **Self-claim** so the device fetches its own MQTT cert from the claim service post-Wi-Fi (no host-side `rainmaker.py claim` step over UART).
- **Disable challenge-response** because RainMaker rejects the combination at init (`Challenge Response is incompatible with self claiming`).

```bash
cd esp-rainmaker/examples/switch
cat >> sdkconfig.defaults <<'EOF'

# Emulator runs: self-claim + no challenge-response
CONFIG_ESP_RMAKER_SELF_CLAIM=y
CONFIG_ESP_RMAKER_ENABLE_CHALLENGE_RESPONSE=n
EOF

idf.py set-target esp32c3
idf.py build
idf.py merge-bin -o merged_flash.bin
```

The build artefacts you need are `build/merged_flash.bin` (firmware) and `build/switch.elf` (symbols for BLE stub interception and panic backtraces).

> **IDF compatibility note.** RainMaker master still uses legacy `mbedtls/sha256.h`, `mbedtls/ecdsa.h`, etc. — those headers moved under `mbedtls/private/` in mbedtls 4.x (IDF v6.1+). Build against IDF v5.5.x (mbedtls 3.x) until upstream RainMaker catches up.

## Running

### Step 1: Start the VHCI bridge

```bash
python3 tools/vhci_bridge.py
```

The bridge opens `/dev/vhci`, registers a virtual adapter (typically `hci1` on a system that already has `hci0`), and starts listening on TCP port 9544:

```
[+] VHCI adapter registered as hci1
[*] Starting TCP server on port 9544, waiting for esp-emu...
```

Confirm with `hciconfig`:

```
hci1: Type: Primary  Bus: Virtual
      BD Address: AA:BB:CC:DD:EE:FF  ACL MTU: 27:64
      UP RUNNING
```

### Step 2: Start ESP-EMU

```bash
esp-emu \
  --chip esp32c3 \
  --firmware build/merged_flash.bin \
  --elf build/switch.elf \
  --ble-hci tcp:localhost:9544 \
  --timeout 120s
```

Wait for the firmware to print the QR code line — the device name and PoP are randomized per boot:

```
I (606) network_prov_mgr: Provisioning started with service name : PROV_1981df
I (606) QRCODE: {"ver":"v1","name":"PROV_1981df","pop":"6b6c2bb2","transport":"ble"}
I (606) app_main: Provisioning QR : ...
```

Capture the `name` and `pop` — you'll need them in the next step.

### Step 3: Provision via esp-rainmaker-cli

Pass the bridge's adapter index with `--ble_adapter`:

```bash
esp-rainmaker-cli provision \
  --transport ble \
  --device_name PROV_1981df \
  --pop 6b6c2bb2 \
  --ble_adapter hci1 \
  --ssid myssid \
  --passphrase mypassword \
  --no-retry
```

Or pass the QR JSON the firmware just printed and let the CLI parse it:

```bash
esp-rainmaker-cli provision \
  --qrcode '{"ver":"v1","name":"PROV_1981df","pop":"6b6c2bb2","transport":"ble"}' \
  --ble_adapter hci1 \
  --ssid myssid \
  --passphrase mypassword \
  --no-retry
```

A successful run looks like:

```
Looking for BLE device: PROV_1981df
Discovering...
Connecting...
Discovered endpoints via user descriptors: cloud_user_assoc, prov-session,
  proto-ver, prov-config, prov-scan, prov-ctrl
==== Auto-detected Security Scheme: 1 ====
Establishing session - Successful
Sending user information to node - Successful
Sending Wi-Fi credentials to node - Successful
==== WiFi state: Connected ====
Wi-Fi Provisioning Successful.
✅ Node 240AC4000001 provisioned successfully!
```

You can confirm BLE traffic actually went through `hci1` (not the system default `hci0`) via `hciconfig hci1` — the `acl` and `events` counters bump after the run.

## How it works

The bridge is the same one used for [Matter commissioning](./MATTER.md). It creates two Bumble virtual BLE controllers on a shared `LocalLink`:

1. **bluez-controller**: bound to `/dev/vhci`. BlueZ exposes it as `hci1`. `esp-rainmaker-cli` (which uses `bleak` → `dbus` → BlueZ) drives this side via `--ble_adapter hci1`.
2. **emu-controller**: TCP server on port 9544. esp-emu connects and forwards HCI packets from the firmware's NimBLE stack.

The provisioning flow itself is the standard `wifi_prov_mgr` exchange plus RainMaker's `cloud_user_assoc` endpoint:

1. **BLE discovery + connect**: BlueZ finds `PROV_xxxxxx`, establishes the LE link.
2. **GATT discovery**: CLI reads the user-descriptor table, finds `prov-session`, `prov-config`, `prov-scan`, `prov-ctrl`, `cloud_user_assoc`, `proto-ver`.
3. **Capabilities + sec scheme detection**: CLI reads `proto-ver`, picks Security 1 (default), runs the X25519 + AES-CTR PoP handshake.
4. **User-node association**: CLI signs the user/secret payload and writes it to `cloud_user_assoc`.
5. **Wi-Fi credentials**: CLI sends SSID/passphrase via `prov-config`, then commands `apply` via `prov-ctrl`.
6. **Wi-Fi handoff**: firmware leaves provisioning mode, joins the soft AP (`myssid` / `mypassword` are the emulator defaults), CLI polls connection status until `Connected`.
7. **Cloud node mapping**: CLI POSTs the node-id to RainMaker cloud against the logged-in account.

After step 6 the device runs the rest of the RainMaker boot path (NTP, MQTT TLS handshake, parameter publish) over user-mode networking — useful for testing OTA, parameter updates, schedules, etc.

## Troubleshooting

### `Looking for BLE device: PROV_xxxxxx` then timeout

The CLI is scanning the wrong adapter. Verify the bridge's adapter index with `hciconfig` and pass it explicitly via `--ble_adapter hciN`. Without the flag the CLI defaults to `hci0`, which is your real Bluetooth radio.

### `Failure (100015): Nodes do not exist`

The BLE step succeeded but the post-Wi-Fi cloud node-mapping call failed. This usually means self-claim hasn't completed yet — the device hasn't registered itself with the RainMaker cloud, so the CLI's "add node to user account" call has nothing to bind to. Watch the esp-emu serial log for `esp_claim:` messages; the claim service must reach the internet through the user-mode NAT for self-claim to finish.

### `Challenge Response is incompatible with self claiming`

The default RainMaker sdkconfig combines `CONFIG_ESP_RMAKER_LOCAL_CTRL_AUTO_ENABLE=y` (which pulls in `CONFIG_ESP_RMAKER_ENABLE_CHALLENGE_RESPONSE=y`) with self-claim. The core init aborts. Disable challenge-response in `sdkconfig.defaults` (see the build section above).

### `mbedtls/sha256.h: No such file or directory`

You're building RainMaker against IDF v6.1+ where mbedtls 4.x moved those headers under `mbedtls/private/`. Use IDF v5.5.x for now.

### `Unknown HCI Command` in NimBLE logs

```
ogf=0x08, ocf=0x004e, hci_err=0x201 : BLE_ERR_UNKNOWN_HCI_CMD
```

NimBLE attempting `LE Set Privacy Mode`, which Bumble's controller doesn't implement. Harmless — the firmware handles the error and continues advertising.

### Port 9544 already in use

A previous bridge instance is still running. `pkill -f vhci_bridge` or pass `--port <other>` to both the bridge and esp-emu.
