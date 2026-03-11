#!/bin/bash
source ./venv/bin/activate
set -euo pipefail

TIME=60

DEV=server-link
NS=router
# Delay the ping test until elefant flow ramps up
DELAY=5
PING_TIME=$((TIME - DELAY - 1))

run_test() {
  output=$1
  echo -e "\n=== $output === (runs for $TIME sec)"
  # start ping process in background
  (sleep $DELAY && echo "ping: started in background (runs for $PING_TIME sec)" && \
   ip netns exec client ping -w $PING_TIME -q -i 0.1 192.168.20.2)&
  graph=$(ip netns exec client bbperf -t $TIME -u -c 192.168.20.2 -B 192.168.20.1 -g -J $output.json | grep "created graph" | awk '{print $3}')
  mv $graph ./bbperf-graph-$output.png
  # wait for background ping to complete
  wait
  # Qdisc output: Look for requeues
  ip netns exec ${NS} tc -s qdisc ls dev ${DEV}
  # Interface stats: Look for TX dropped
  ip -netns ${NS} -s link ls dev ${DEV}
}

ip netns exec ${NS} tc qdisc replace dev ${DEV} root fq_codel interval 20ms target 2ms
run_test "fq_codel"
