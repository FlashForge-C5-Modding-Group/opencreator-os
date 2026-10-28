# OpenWrt target for Ingenic X2600 boards running Ingenic's SDK 6.6 kernel
# (CONFIG_EXTERNAL_KERNEL_TREE, prepared by kernel/prepare.sh).
include $(TOPDIR)/rules.mk

ARCH:=mipsel
BOARD:=x2600
# image.mk names device symbols CONFIG_TARGET_<board>_<subtarget>_DEVICE_*,
# so a target without a subtarget never builds a device image.
SUBTARGETS:=generic
BOARDNAME:=Ingenic X2600 (XBurst2)
CPU_TYPE:=mips32
FEATURES:=squashfs usb fpu
KERNEL_PATCHVER:=6.6
KERNELNAME:=zImage
IMAGES_DIR:=compressed
DEVICE_TYPE:=basic

define Target/Description
	Ingenic X2600 boards on the Ingenic SDK 6.6 kernel (external tree)
endef

include $(INCLUDE_DIR)/target.mk

# Not here: mtd (no MTD on this eMMC-only board; slot.sh and platform.sh use
# dd), urngd (the kernel's CRNG is ready during preinit, seconds before urngd
# would start).
DEFAULT_PACKAGES := $(filter-out mtd urngd,$(DEFAULT_PACKAGES))
# wpa-supplicant-mbedtls: client only (no hostapd process), with WPA3-SAE,
# OWE, Suite-B 192 and 802.11r/w.
DEFAULT_PACKAGES += dropbear block-mount partx-utils e2fsprogs \
	kmod-usb-serial kmod-usb-serial-ch341 kmod-usb-serial-cp210x \
	kmod-usb-serial-ftdi kmod-usb-acm \
	wpa-supplicant-mbedtls kmod-rtw88-8821cu rtl8821ce-firmware iwinfo \
	openssh-sftp-server

# The SPL boots with init=/linuxrc.
define Package/base-files/install-target
	ln -sf /sbin/init $(1)/linuxrc
endef

$(eval $(call BuildTarget))
