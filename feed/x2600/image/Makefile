include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/image.mk

# Slot sizes from the Creator 5 Pro GPT: kernel/kernel2 8 MiB,
# rootfs/rootfs2 100 MiB. The SPL loads a legacy uImage to load-64 and jumps
# to the entry point; the zImage self-extracts from 0x80f00000.
define Device/Default
  PROFILES := Default
  KERNEL_NAME := zImage
  KERNEL_LOADADDR := 0x80f00000
  KERNEL_ENTRY := 0x80f00000
  KERNEL := kernel-bin | uImage none | check-size $$$$(KERNEL_SIZE)
  KERNEL_SIZE := 8192k
  IMAGE_SIZE := 102400k
  IMAGES := kernel.uimage root.squashfs sysupgrade.tar
  IMAGE/kernel.uimage := append-kernel
  IMAGE/root.squashfs := append-rootfs | pad-to 64k | check-size
  IMAGE/sysupgrade.tar := sysupgrade-tar | append-metadata
endef

define Device/flashforge_creator5pro
  DEVICE_VENDOR := FlashForge
  DEVICE_MODEL := Creator 5 Pro
endef
TARGET_DEVICES += flashforge_creator5pro

$(eval $(call BuildImage))
