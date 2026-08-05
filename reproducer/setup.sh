#!/bin/bash
set -euo pipefail

# Repo root is the parent dir of this script's location
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Use sudo for privileged commands when not running as root
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo env PATH=$PATH"

#MQ=yes
MQ=no

# recreate namespaces
$SUDO ip netns del server || true
$SUDO ip netns del client || true
$SUDO ip netns del router || true
$SUDO ip netns add server
$SUDO ip netns add client
$SUDO ip netns add router

# setup routing between netns namespaces
if [[ "${MQ}" == "yes" ]]; then
  $SUDO ip -netns client link add dev to-router type veth peer name client-link netns router numtxqueues 8 numrxqueues 8
  $SUDO ip -netns server link add dev in-router type veth peer name server-link netns router numtxqueues 8 numrxqueues 8
else
  $SUDO ip -netns client link add dev to-router type veth peer name client-link netns router
  $SUDO ip -netns server link add dev in-router type veth peer name server-link netns router
fi

# bring up devices and assign IPs
#
for n in client router server; do
        $SUDO ip -n $n link set lo up
done
#
# client:
$SUDO ip -netns client link set dev to-router up
$SUDO ip -netns client addr add dev to-router 198.18.0.2/24
$SUDO ip -netns client route add default via 198.18.0.1
#
# server:
$SUDO ip -netns server link set dev in-router up
$SUDO ip -netns server addr add dev in-router 192.168.20.2/24
$SUDO ip -netns server route add default via 192.168.20.1
#
# router:
$SUDO ip -netns router link set dev client-link up
$SUDO ip -netns router addr add dev client-link 198.18.0.1/24
$SUDO ip -netns router link set dev server-link up
$SUDO ip -netns router addr add dev server-link 192.168.20.1/24
$SUDO ip netns exec router sysctl -w net.ipv4.ip_forward=1


# force qdisc to requeue gso_skb
$SUDO ip netns exec router ethtool -K server-link tso off

# Enable NAPI
$SUDO ip netns exec server ethtool -K in-router gro on
# enable threaded-NAPI
$SUDO ip netns exec server bash -c "echo 1 > /sys/class/net/in-router/threaded"


# needed for bbperf udp client
# ip netns exec client ip link set dev lo up

# Making NAPI thread slower via many iptables rules
$SUDO ip netns exec server bash -c '
iptables-restore < <(
echo "*filter"
for n in `seq 1 5000`; do
  echo "-I INPUT -d 192.168.20.2"
done
echo "COMMIT"
)
'

# --- Show setup summary by inspecting actual netns state ---
show_device() {
  local ns="$1" dev="$2"
  local info addr_info

  info=$($SUDO ip -netns "$ns" -j -d link show "$dev")
  addr_info=$($SUDO ip -netns "$ns" -j addr show "$dev")

  local state addr
  state=$(echo "$info" | jq -r '.[0].operstate')
  addr=$(echo "$addr_info" | jq -r '.[0].addr_info[]? | select(.family=="inet") | "\(.local)/\(.prefixlen)"')

  # Channel counts: real (active) and max from ethtool -l
  local ch_out real_tx real_rx max_tx max_rx section=""
  ch_out=$($SUDO ip netns exec "$ns" ethtool -l "$dev" 2>/dev/null)
  max_tx=$(echo "$ch_out" | awk '/Pre-set maximums/{s=1;next} /Current/{s=0} s && /TX:/{print $2; exit}')
  max_rx=$(echo "$ch_out" | awk '/Pre-set maximums/{s=1;next} /Current/{s=0} s && /RX:/{print $2; exit}')
  real_tx=$(echo "$ch_out" | awk '/Current hardware/{s=1;next} s && /TX:/{print $2; exit}')
  real_rx=$(echo "$ch_out" | awk '/Current hardware/{s=1;next} s && /RX:/{print $2; exit}')

  # Feature flags (only show non-default/notable ones)
  local features=""
  local tso gro
  tso=$($SUDO ip netns exec "$ns" ethtool -k "$dev" 2>/dev/null | awk '/^tcp-segmentation-offload:/{print $2}')
  gro=$($SUDO ip netns exec "$ns" ethtool -k "$dev" 2>/dev/null | awk '/^generic-receive-offload:/{print $2}')
  [ "$tso" = "off" ] && features="$features tso-off"
  [ "$gro" = "on" ] && features="$features gro"

  # Threaded NAPI
  local threaded_file="/sys/class/net/${dev}/threaded"
  local threaded
  threaded=$($SUDO ip netns exec "$ns" cat "$threaded_file" 2>/dev/null || echo "")
  [ "$threaded" = "1" ] && features="$features threaded-napi"

  printf "  %-12s %-18s state %-4s  txq %s/%s  rxq %s/%s%s\n" \
    "$dev" "${addr:-<no-ip>}" "$state" "$real_tx" "$max_tx" "$real_rx" "$max_rx" "$features"
}

echo ""
echo "=== Setup summary ==="
echo "Namespaces: $($SUDO ip netns list | sort | tr '\n' ' ')"
echo ""

echo "client:"
show_device client to-router

echo "router:"
show_device router client-link
show_device router server-link

echo "server:"
show_device server in-router

# iptables rule count (server netns)
ipt_count=$($SUDO ip netns exec server iptables -S INPUT 2>/dev/null | wc -l)
echo ""
echo "iptables INPUT rules (server): $ipt_count"

# ip_forward (router)
fwd=$($SUDO ip netns exec router sysctl -n net.ipv4.ip_forward 2>/dev/null)
echo "ip_forward (router): $fwd"

# Connectivity check
echo ""
if $SUDO ip netns exec client ping -c 1 -W 2 192.168.20.2 > /dev/null 2>&1; then
  rtt=$($SUDO ip netns exec client ping -c 1 -W 2 192.168.20.2 2>/dev/null | awk -F'/' '/^rtt/{print $5}')
  echo "Connectivity: client -> server OK (${rtt}ms)"
else
  echo "Connectivity: client -> server FAILED"
fi
echo ""

# install bbperf (shared venv at repo root; selftests may use it too)
[ ! -d "${REPO_ROOT}/venv" ] && virtualenv "${REPO_ROOT}/venv"
source "${REPO_ROOT}/venv/bin/activate"
pip3 install --upgrade bbperf
