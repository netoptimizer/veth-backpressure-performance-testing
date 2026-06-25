# SPDX-License-Identifier: GPL-2.0
TARGETS := udp_flood udp_sink
CFLAGS  ?= -O2 -Wall
udp_sink: LDLIBS := -lm

CLANG   ?= clang
BPF_OBJ := xdp_drop_cheap.o

.PHONY: all clean xdp
all: $(TARGETS)

# BPF/XDP object for the --xdp-drop attack variant (needs clang + libbpf headers).
# Kept out of 'all' so the default C build still works without clang/llvm.
#   make xdp        # or: make xdp_drop_cheap.o
xdp: $(BPF_OBJ)
$(BPF_OBJ): xdp_drop_cheap.c
	$(CLANG) -O2 -g -target bpf -c $< -o $@

clean:
	rm -f $(TARGETS) $(BPF_OBJ)
