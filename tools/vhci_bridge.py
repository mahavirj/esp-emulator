#!/usr/bin/env python3
"""
VHCI Bridge: connects chip-tool (via BlueZ) to esp-emu (via TCP).

Creates two Bumble virtual BLE controllers on a shared LocalLink:
  - emu-controller:   TCP server on port 9544, esp-emu connects here
  - bluez-controller: VHCI transport, BlueZ sees this as a real hciX adapter

This lets chip-tool commission Matter devices running in esp-emu without
any modifications to either tool.

Requirements:
  pip3 install bumble

Usage:
  # Terminal 1: start bridge (needs root for /dev/vhci)
  sudo python3 tools/vhci_bridge.py

  # Terminal 2: start esp-emu
  ./esp-emu --chip esp32c3 \\
    --firmware build/merged_flash.bin \\
    --elf build/matter_app.elf \\
    --ble-hci tcp:localhost:9544 --timeout 120s

  # Terminal 3: use chip-tool (use --ble-controller N if multiple adapters)
  chip-tool pairing ble-wifi <node-id> <discriminator> <setup-pin> <ssid> <password>
"""

import argparse
import asyncio
import logging
import re
import subprocess
import sys

logging.basicConfig(level=logging.WARNING)
logger = logging.getLogger(__name__)


async def main():
    parser = argparse.ArgumentParser(description="VHCI bridge: BlueZ <-> esp-emu")
    parser.add_argument(
        "--port", type=int, default=9544, help="TCP port for esp-emu (default: 9544)"
    )
    parser.add_argument(
        "--emu-address",
        default="00:11:22:33:44:55",
        help="BT address for emu-side controller (default: 00:11:22:33:44:55)",
    )
    parser.add_argument(
        "--bluez-address",
        default="AA:BB:CC:DD:EE:FF",
        help="BT address for BlueZ-side controller (default: AA:BB:CC:DD:EE:FF)",
    )
    parser.add_argument(
        "-v", "--verbose", action="store_true", help="Enable debug logging"
    )
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    try:
        from bumble.controller import Controller, LegacyAdvertiser
        from bumble.link import LocalLink
        from bumble.transport import open_transport
        from bumble import hci, ll
    except ImportError:
        print("ERROR: bumble not installed. Run: pip3 install bumble")
        sys.exit(1)

    # Bumble's LocalLink doesn't implement SCAN_REQ/SCAN_RSP exchange, so the
    # device name (typically in scan response data) is never visible to the
    # scanning controller.  Fix: attach scan_response_data to the AdvInd PDU
    # as metadata, then use it in the synthetic SCAN_RSP event on the receiver.
    _orig_send_advertising = LegacyAdvertiser.send_advertising_data

    def _patched_send_advertising(self):
        if not self.enabled:
            return
        adv_type = hci.HCI_LE_Set_Advertising_Parameters_Command.AdvertisingType
        if self.advertising_type == adv_type.ADV_IND:
            pdu = ll.AdvInd(
                advertiser_address=self.address, data=self.advertising_data
            )
            pdu._scan_response_data = self.scan_response_data
            self.controller.send_advertising_pdu(pdu)

    LegacyAdvertiser.send_advertising_data = _patched_send_advertising

    _orig_on_advertising_pdu = Controller.on_advertising_pdu

    def _patched_on_advertising_pdu(self, pdu):
        # Inject scan_response_data into SCAN_RSP events if available.
        scan_rsp_data = getattr(pdu, "_scan_response_data", b"")
        if not scan_rsp_data:
            return _orig_on_advertising_pdu(self, pdu)

        if isinstance(pdu, ll.AdvExtInd):
            direct_address = pdu.target_address
        else:
            direct_address = None

        if self.le_scan_enable:
            if self.le_features & hci.LeFeatureMask.LE_EXTENDED_ADVERTISING:
                # Extended advertising: ADV_IND report
                ext_report = hci.HCI_LE_Extended_Advertising_Report_Event.Report(
                    event_type=hci.HCI_LE_Extended_Advertising_Report_Event.EventType.CONNECTABLE_ADVERTISING,
                    address_type=pdu.advertiser_address.address_type,
                    address=pdu.advertiser_address,
                    primary_phy=hci.Phy.LE_1M,
                    secondary_phy=hci.Phy.LE_1M,
                    advertising_sid=0, tx_power=0, rssi=-50,
                    periodic_advertising_interval=0,
                    direct_address_type=direct_address.address_type if direct_address else 0,
                    direct_address=direct_address or hci.Address.ANY,
                    data=pdu.data,
                )
                self.send_hci_packet(hci.HCI_LE_Extended_Advertising_Report_Event([ext_report]))
                # SCAN_RSP with actual scan response data
                ext_report = hci.HCI_LE_Extended_Advertising_Report_Event.Report(
                    event_type=hci.HCI_LE_Extended_Advertising_Report_Event.EventType.SCAN_RESPONSE,
                    address_type=pdu.advertiser_address.address_type,
                    address=pdu.advertiser_address,
                    primary_phy=hci.Phy.LE_1M,
                    secondary_phy=hci.Phy.LE_1M,
                    advertising_sid=0, tx_power=0, rssi=-50,
                    periodic_advertising_interval=0,
                    direct_address_type=direct_address.address_type if direct_address else 0,
                    direct_address=direct_address or hci.Address.ANY,
                    data=scan_rsp_data,
                )
                self.send_hci_packet(hci.HCI_LE_Extended_Advertising_Report_Event([ext_report]))
            else:
                # Legacy advertising: ADV_IND report
                report = hci.HCI_LE_Advertising_Report_Event.Report(
                    event_type=hci.HCI_LE_Advertising_Report_Event.EventType.ADV_IND,
                    address_type=pdu.advertiser_address.address_type,
                    address=pdu.advertiser_address,
                    data=pdu.data, rssi=-50,
                )
                self.send_hci_packet(hci.HCI_LE_Advertising_Report_Event([report]))
                # SCAN_RSP with actual scan response data
                report = hci.HCI_LE_Advertising_Report_Event.Report(
                    event_type=hci.HCI_LE_Advertising_Report_Event.EventType.SCAN_RSP,
                    address_type=pdu.advertiser_address.address_type,
                    address=pdu.advertiser_address,
                    data=scan_rsp_data, rssi=-50,
                )
                self.send_hci_packet(hci.HCI_LE_Advertising_Report_Event([report]))

        # Connection creation
        if (
            pending := self.pending_le_connection
        ) and pending.peer_address == pdu.advertiser_address:
            self.create_le_connection(pdu.advertiser_address)

    Controller.on_advertising_pdu = _patched_on_advertising_pdu

    # Bumble's LocalLink routes ACL data using sender_controller.random_address
    # as the source identifier. BlueZ sets its own random address via HCI command,
    # which breaks the address mapping. We subclass to keep random_address pinned
    # to the public address so ACL routing works correctly.
    class PinnedAddressController(Controller):
        def on_hci_le_set_random_address_command(self, command):
            # Accept the command (BlueZ expects success) but don't update
            # random_address — keep it matching public_address for LocalLink routing.
            return hci.HCI_StatusReturnParameters(hci.HCI_ErrorCode.SUCCESS)

    link = LocalLink()

    # Controller for BlueZ (VHCI) — open first so we can verify the adapter
    print("[*] Opening /dev/vhci...")
    vhci_transport = await open_transport("vhci:")

    # Find the HCI adapter index assigned to the VHCI device
    hci_index = None
    try:
        result = subprocess.run(
            ["hciconfig"], capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.splitlines():
            if "Bus: Virtual" in line:
                m = re.match(r"hci(\d+):", line)
                if m:
                    hci_index = int(m.group(1))
    except Exception as e:
        logger.debug("hciconfig lookup failed: %s", e)

    # Pin random_address to public so Bumble's LocalLink ACL routing
    # uses a stable address (BlueZ would otherwise overwrite it via HCI).
    bluez_controller = PinnedAddressController(
        "bluez-controller",
        host_source=vhci_transport.source,
        host_sink=vhci_transport.sink,
        link=link,
        public_address=args.bluez_address,
    )
    bluez_controller.random_address = hci.Address(
        args.bluez_address, hci.Address.PUBLIC_DEVICE_ADDRESS
    )
    if hci_index is not None:
        print(f"[+] VHCI adapter registered as hci{hci_index}")
        print(f"    Use: chip-tool pairing ble-wifi ... --ble-controller {hci_index}")
    else:
        print("[+] VHCI adapter registered — run 'hciconfig' to find the adapter index")

    # Controller for esp-emu (connected via TCP)
    print(f"[*] Starting TCP server on port {args.port}, waiting for esp-emu...")
    emu_transport = await open_transport(f"tcp-server:_:{args.port}")
    emu_controller = Controller(  # noqa: F841 — must stay alive
        "emu-controller",
        host_source=emu_transport.source,
        host_sink=emu_transport.sink,
        link=link,
        public_address=args.emu_address,
    )
    emu_controller.random_address = hci.Address(
        args.emu_address, hci.Address.PUBLIC_DEVICE_ADDRESS
    )
    print("[+] esp-emu connected")
    print("[*] Bridge running. Press Ctrl+C to stop.")

    try:
        await asyncio.get_running_loop().create_future()
    except asyncio.CancelledError:
        pass


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("\n[*] Bridge stopped")
