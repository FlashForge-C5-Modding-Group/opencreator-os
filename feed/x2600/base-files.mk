# No feed for plain opkg: the image is hard-float and nothing hosts hard-float
# packages. Soft-float packages go through opkg-sf. See docs/image.md.
define FeedSourcesAppendOPKG
echo '# no hard-float feed yet; use opkg-sf for soft-float packages' >> $(1)
endef
