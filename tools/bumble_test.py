#!/usr/bin/env python3
"""
Bumble-based BLE integration test for esp-emu.

Starts a virtual BLE controller on TCP port 9544, waits for esp-emu to connect,
then acts as a GATT client: scans, connects, discovers services, reads/writes
characteristics, and subscribes to notifications. Works with both C3 and C6.

Requirements:
  pip3 install bumble

Usage:
  1. Start this script:     python3 tools/bumble_test.py
  2. Start esp-emu:         ./esp-emu --chip esp32c3 \
                              --firmware build/merged_flash.bin \
                              --elf build/bleprph.elf \
                              --ble-hci tcp:localhost:9544 --timeout 45s
"""

import asyncio
import logging
import sys

logging.basicConfig(level=logging.WARNING)

async def main():
    try:
        from bumble.controller import Controller
        from bumble.link import LocalLink
        from bumble.device import Device, Peer
        from bumble.host import Host
        from bumble.transport import open_transport
        from bumble import hci
    except ImportError:
        print("ERROR: bumble not installed. Run: pip3 install bumble")
        sys.exit(1)

    link = LocalLink()

    # Controller for esp-emu (connected via TCP on port 9544)
    print("[*] Starting virtual BLE controller on tcp-server:_:9544")
    emu_transport = await open_transport("tcp-server:_:9544")
    emu_controller = Controller(
        "emu-controller",
        host_source=emu_transport.source,
        host_sink=emu_transport.sink,
        link=link,
        public_address="00:11:22:33:44:55",
    )
    # Bumble's LocalLink ACL routing uses sender_controller.random_address as source.
    # Set it to match the public address so the phone-controller can look up the
    # connection by peer address (which was the emu's public address).
    emu_controller.random_address = hci.Address(
        "00:11:22:33:44:55", hci.Address.PUBLIC_DEVICE_ADDRESS
    )
    print("[*] Waiting for esp-emu to connect on port 9544...")

    # "Phone" device — local controller + host on the same link
    phone_controller = Controller(
        "phone-controller",
        link=link,
        public_address="AA:BB:CC:DD:EE:FF",
    )
    phone_host = Host()
    phone_host.controller = phone_controller
    phone_controller.host = phone_host
    phone = Device(name="Test Phone", host=phone_host)
    await phone.power_on()
    print("[*] Phone powered on, waiting for advertising...")

    # Wait for esp-emu to boot and start advertising
    await asyncio.sleep(15)

    # Scan
    devices_found = []

    def on_advertisement(advertisement):
        addr = str(advertisement.address)
        if addr not in [str(d.address) for d in devices_found]:
            devices_found.append(advertisement)
            raw_name = advertisement.data.get(0x09, b'')
            name = raw_name.decode('utf-8', errors='replace') if isinstance(raw_name, bytes) else str(raw_name)
            print(f"[+] Found: {advertisement.address} name='{name}'")

    phone.on('advertisement', on_advertisement)
    await phone.start_scanning()
    print("[*] Scanning for 10 seconds...")
    await asyncio.sleep(10)
    await phone.stop_scanning()

    if not devices_found:
        print("[-] No devices found")
        return

    target = devices_found[0]
    print(f"[*] Connecting to {target.address}...")
    try:
        connection = await phone.connect(target.address, timeout=10)
        print(f"[+] Connected!")
        peer = Peer(connection)
        print("[*] Discovering services...")
        await peer.discover_services()
        for service in peer.services:
            print(f"  Service: {service.uuid}")
            await service.discover_characteristics()
            for char in service.characteristics:
                props = []
                if char.properties & 0x02: props.append("READ")
                if char.properties & 0x08: props.append("WRITE")
                if char.properties & 0x10: props.append("NOTIFY")
                print(f"    Char: {char.uuid} [{', '.join(props)}]")
                if char.properties & 0x02:
                    try:
                        value = await char.read_value()
                        print(f"      Value: {value.hex()}")
                    except Exception as e:
                        print(f"      Read error: {e}")
        print("[+] GATT discovery complete!")

        # Phase 2: Write to writable characteristics and subscribe to notifications
        for service in peer.services:
            for char in service.characteristics:
                # Write test
                if char.properties & 0x08:  # WRITE
                    try:
                        await char.write_value(b'\x01\x02\x03')
                        print(f"    [{char.uuid}] Write OK")
                    except Exception as e:
                        print(f"    [{char.uuid}] Write error: {e}")
                # Subscribe to notifications
                if char.properties & 0x10:  # NOTIFY
                    try:
                        await char.discover_descriptors()
                        await char.subscribe()
                        print(f"    [{char.uuid}] Subscribe OK")
                    except Exception as e:
                        print(f"    [{char.uuid}] Subscribe error: {e}")
                # Read after write to verify
                if (char.properties & 0x0A) == 0x0A:  # READ + WRITE
                    try:
                        value = await char.read_value()
                        print(f"    [{char.uuid}] Read-back: {value.hex()}")
                    except Exception as e:
                        print(f"    [{char.uuid}] Read-back error: {e}")

        print("[+] Extended test complete!")
        await asyncio.sleep(1)
        await connection.disconnect()
        print("[*] Disconnected")
    except Exception as e:
        print(f"[-] Error: {e}")
        import traceback
        traceback.print_exc()

    print("[*] Test complete")

if __name__ == "__main__":
    asyncio.run(main())
