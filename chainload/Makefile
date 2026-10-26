# SPDX-License-Identifier: GPL-2.0
# chainload.ko: out-of-tree module for the stock Creator 5 Pro 5.10.186+
# kernel. Normally built by build.sh; by hand:
#   make KDIR=<kernel-5.10 source> O=<prepared build dir> \
#        CROSS_COMPILE=<toolchain>/bin/mips-xburst2-linux-gnu-

obj-m := chainload.o
chainload-y := chainload_main.o tramp.o

ifeq ($(KERNELRELEASE),)
KDIR ?= $(HOME)/ing/kernel-5.10
O ?= $(HOME)/ing/out
CROSS_COMPILE ?= $(HOME)/ing/mips-xburst2-linux-toolchain-r6.0.0/bin/mips-xburst2-linux-gnu-

modules clean:
	$(MAKE) -C $(KDIR) O=$(O) ARCH=mips CROSS_COMPILE=$(CROSS_COMPILE) M=$(CURDIR) $@

.PHONY: modules clean
endif
