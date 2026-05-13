#!/usr/bin/env bash
#
# Set up a TAP interface for esp-emu WiFi emulation with NAT.
#
# Creates a TAP device, assigns it a subnet, and configures iptables
# rules so the emulated ESP32 can reach the internet via the host.
#
# Usage:
#   sudo ./tools/setup-tap.sh [options]
#   sudo ./tools/setup-tap.sh --teardown
#
# Options:
#   -t, --tap NAME        TAP interface name          (default: tap0)
#   -i, --iface NAME      Outbound network interface  (default: auto-detected)
#   -s, --subnet CIDR     TAP subnet                  (default: 192.168.4.0/24)
#   -g, --gateway IP      Gateway IP on TAP           (default: 192.168.4.1)
#   -u, --user USER       Owner of the TAP device     (default: $SUDO_USER)
#   --ipv6                Enable IPv6 with global prefix from outbound interface
#   --teardown            Remove TAP interface and iptables rules
#   -h, --help            Show this help message

set -euo pipefail

# Defaults
TAP_NAME="tap0"
OUTBOUND_IFACE=""
SUBNET="192.168.4.0/24"
GATEWAY_IP="192.168.4.1"
TAP_USER="${SUDO_USER:-$(whoami)}"
TEARDOWN=false
ENABLE_IPV6=false

# Default STA MAC from eFuse (Espressif OUI 24:0A:C4)
STA_MAC="24:0a:c4:00:00:01"

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \?//'
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--tap)       TAP_NAME="$2"; shift 2 ;;
        -i|--iface)     OUTBOUND_IFACE="$2"; shift 2 ;;
        -s|--subnet)    SUBNET="$2"; shift 2 ;;
        -g|--gateway)   GATEWAY_IP="$2"; shift 2 ;;
        -u|--user)      TAP_USER="$2"; shift 2 ;;
        --ipv6)         ENABLE_IPV6=true; shift ;;
        --teardown)     TEARDOWN=true; shift ;;
        -h|--help)      usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Auto-detect outbound interface if not specified
if [[ -z "$OUTBOUND_IFACE" ]]; then
    OUTBOUND_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')
    if [[ -z "$OUTBOUND_IFACE" ]]; then
        echo "Error: could not auto-detect outbound interface. Use --iface." >&2
        exit 1
    fi
fi

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (sudo)." >&2
    exit 1
fi

# Compute device's SLAAC address from STA MAC via EUI-64.
# MAC aa:bb:cc:dd:ee:ff → EUI-64 aa^02:bbff:fedd:eeff → aabb:ccff:fedd:eeff
compute_eui64_suffix() {
    local mac="$1"
    IFS=: read -r b0 b1 b2 b3 b4 b5 <<< "$mac"
    # Flip bit 6 (universal/local) of first byte
    local b0_flipped=$(printf "%02x" $(( 0x$b0 ^ 0x02 )))
    echo "${b0_flipped}${b1}:${b2}ff:fe${b3}:${b4}${b5}"
}

teardown() {
    echo "Tearing down TAP interface '$TAP_NAME'..."

    # Remove iptables rules (ignore errors if they don't exist)
    iptables -D FORWARD -i "$TAP_NAME" -o "$OUTBOUND_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$OUTBOUND_IFACE" -o "$TAP_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$OUTBOUND_IFACE" -j MASQUERADE 2>/dev/null || true

    # Remove IPv6 rules
    ip6tables -D FORWARD -i "$TAP_NAME" -o "$OUTBOUND_IFACE" -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -i "$OUTBOUND_IFACE" -o "$TAP_NAME" -j ACCEPT 2>/dev/null || true

    # Stop esp-emu radvd instance
    pkill -f "radvd -C /tmp/esp-emu-radvd.conf" 2>/dev/null || true
    rm -f /tmp/esp-emu-radvd.conf /tmp/esp-emu-radvd.pid

    # Delete TAP interface
    if ip link show "$TAP_NAME" &>/dev/null; then
        ip link set "$TAP_NAME" down
        ip tuntap del dev "$TAP_NAME" mode tap
        echo "TAP interface '$TAP_NAME' removed."
    else
        echo "TAP interface '$TAP_NAME' does not exist."
    fi

    echo "Done."
}

setup() {
    echo "Setting up TAP interface '$TAP_NAME'..."
    echo "  Outbound interface: $OUTBOUND_IFACE"
    echo "  Subnet:             $SUBNET"
    echo "  Gateway IP:         $GATEWAY_IP"
    echo "  TAP owner:          $TAP_USER"

    # Create TAP interface
    if ip link show "$TAP_NAME" &>/dev/null; then
        echo "  TAP interface '$TAP_NAME' already exists, reconfiguring..."
        ip link set "$TAP_NAME" down
    else
        ip tuntap add dev "$TAP_NAME" mode tap user "$TAP_USER"
        echo "  Created TAP interface."
    fi

    # Configure TAP interface
    ip addr flush dev "$TAP_NAME"
    ip addr add "$GATEWAY_IP/24" dev "$TAP_NAME"
    ip link set "$TAP_NAME" up
    echo "  TAP interface up with IP $GATEWAY_IP."

    # Enable IP forwarding
    sysctl -q net.ipv4.ip_forward=1
    echo "  IP forwarding enabled."

    # Add iptables rules (remove first to avoid duplicates)
    iptables -D FORWARD -i "$TAP_NAME" -o "$OUTBOUND_IFACE" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -i "$OUTBOUND_IFACE" -o "$TAP_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$SUBNET" -o "$OUTBOUND_IFACE" -j MASQUERADE 2>/dev/null || true

    iptables -A FORWARD -i "$TAP_NAME" -o "$OUTBOUND_IFACE" -j ACCEPT
    iptables -A FORWARD -i "$OUTBOUND_IFACE" -o "$TAP_NAME" -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -A POSTROUTING -s "$SUBNET" -o "$OUTBOUND_IFACE" -j MASQUERADE
    echo "  iptables NAT/forwarding rules added."

    # IPv6 setup
    if $ENABLE_IPV6; then
        setup_ipv6
    fi

    echo ""
    echo "Ready. Run esp-emu — TAP is auto-detected if '$TAP_NAME' is up."
}

setup_ipv6() {
    echo ""
    echo "  Configuring IPv6..."

    # Detect host's global /64 prefix from outbound interface
    local host_addr
    host_addr=$(ip -6 addr show "$OUTBOUND_IFACE" scope global -dynamic | grep -oP '[\da-f:]+(?=/64)' | head -1)
    if [[ -z "$host_addr" ]]; then
        echo "  Warning: no global IPv6 /64 found on $OUTBOUND_IFACE, skipping IPv6." >&2
        return
    fi
    # Extract /64 prefix (strip last 16-bit group)
    local prefix64
    prefix64=$(echo "$host_addr" | sed 's/:[^:]*$//')

    # Compute device's SLAAC address: prefix + EUI-64 from STA MAC
    local eui64_suffix
    eui64_suffix=$(compute_eui64_suffix "$STA_MAC")
    local dev_addr="${prefix64}:${eui64_suffix}"

    echo "  Host prefix:        ${prefix64}::/64"
    echo "  Device SLAAC addr:  $dev_addr"
    echo "  STA MAC:            $STA_MAC"

    # Gateway address on tap0 (for source address in kernel)
    local gw6="${prefix64}::1"
    ip -6 addr add "${gw6}/128" dev "$TAP_NAME" noprefixroute 2>/dev/null || true
    echo "  TAP gateway IPv6:   $gw6"

    # Route to device via tap0
    ip -6 route replace "${dev_addr}/128" dev "$TAP_NAME"

    # Static neighbor entry (STA MAC) so kernel can send without NDP
    ip -6 neigh replace "$dev_addr" lladdr "$STA_MAC" dev "$TAP_NAME" nud permanent

    # Ignore linkdown on tap0 routes (tap0 is down when emulator isn't running)
    sysctl -q net.ipv6.conf."$TAP_NAME".ignore_routes_with_linkdown=0

    # NDP proxy on outbound interface so external devices can reach the device
    sysctl -q net.ipv6.conf.all.forwarding=1
    sysctl -q net.ipv6.conf."$OUTBOUND_IFACE".accept_ra=2
    sysctl -q net.ipv6.conf."$OUTBOUND_IFACE".proxy_ndp=1
    ip -6 neigh replace proxy "$dev_addr" dev "$OUTBOUND_IFACE"

    # ip6tables forwarding (remove first to avoid duplicates)
    ip6tables -D FORWARD -i "$TAP_NAME" -o "$OUTBOUND_IFACE" -j ACCEPT 2>/dev/null || true
    ip6tables -D FORWARD -i "$OUTBOUND_IFACE" -o "$TAP_NAME" -j ACCEPT 2>/dev/null || true
    ip6tables -A FORWARD -i "$TAP_NAME" -o "$OUTBOUND_IFACE" -j ACCEPT
    ip6tables -A FORWARD -i "$OUTBOUND_IFACE" -o "$TAP_NAME" -j ACCEPT
    echo "  IPv6 forwarding + NDP proxy configured."

    # Start radvd to advertise the prefix into tap0
    local radvd_conf="/tmp/esp-emu-radvd.conf"
    if command -v radvd &>/dev/null; then
        cat > "$radvd_conf" <<RADVD
interface $TAP_NAME {
    AdvSendAdvert on;
    prefix ${prefix64}::/64 {
        AdvOnLink on;
        AdvAutonomous on;
        AdvValidLifetime 3600;
        AdvPreferredLifetime 1800;
    };
};
RADVD
        # Stop any previous esp-emu radvd instance
        pkill -f "radvd -C $radvd_conf" 2>/dev/null || true
        radvd -C "$radvd_conf" -p /tmp/esp-emu-radvd.pid -n &
        echo "  radvd started with prefix ${prefix64}::/64"
    else
        echo "  Warning: radvd not installed. Device won't get global IPv6 via SLAAC."
        echo "  Install with: sudo apt install radvd"
    fi
}

if $TEARDOWN; then
    teardown
else
    setup
fi
