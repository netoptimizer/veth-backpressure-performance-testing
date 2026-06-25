// SPDX-License-Identifier: GPL-2.0
//
// XDP attack helper for the veth BQL adversarial test (see XDP_DROP_TASK.md).
//
// Drops the attacker's "cheap" UDP packets (dport CHEAP_PORT) BEFORE GRO, and
// passes everything else (the expensive victim flow + ping).  XDP_DROP frees the
// frame for ~200ns with no GRO-append, so ~4x more cheap packets fit in a BQL
// coalescing window than the iptables early-ACCEPT path (~770ns/pkt) -- enough to
// pump DQL past the 256-entry ptr_ring ceiling at the DEFAULT tx-usecs=100.
//
// Attach on the CONSUMER side (VETH_B, inside the netns): BQL is charged on
// VETH_A's txq at produce and completed when VETH_B's NAPI pulls the frame, so an
// XDP_DROP frame STILL completes the BQL charge -- which is exactly why dropping
// inflates the limit.
//
// CHEAP_PORT is compiled in; it must match CHEAP_PORT in veth_bql_adversarial.sh.

#include <linux/bpf.h>
#include <linux/in.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/udp.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define CHEAP_PORT 9998

/* Per-CPU drop counter, so you can confirm it's actually dropping:
 *   bpftool map dump name drop_count        */
struct {
	__uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
	__uint(max_entries, 1);
	__type(key, __u32);
	__type(value, __u64);
} drop_count SEC(".maps");

SEC("xdp")
int xdp_drop_cheap(struct xdp_md *ctx)
{
	void *data     = (void *)(long)ctx->data;
	void *data_end = (void *)(long)ctx->data_end;

	struct ethhdr *eth = data;
	if ((void *)(eth + 1) > data_end)
		return XDP_PASS;
	if (eth->h_proto != bpf_htons(ETH_P_IP))
		return XDP_PASS;

	struct iphdr *iph = (void *)(eth + 1);
	if ((void *)(iph + 1) > data_end)
		return XDP_PASS;
	if (iph->protocol != IPPROTO_UDP)
		return XDP_PASS;

	struct udphdr *udp = (void *)iph + iph->ihl * 4;
	if ((void *)(udp + 1) > data_end)
		return XDP_PASS;

	if (udp->dest == bpf_htons(CHEAP_PORT)) {
		__u32 k = 0;
		__u64 *c = bpf_map_lookup_elem(&drop_count, &k);
		if (c)
			(*c)++;
		return XDP_DROP;
	}
	return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
