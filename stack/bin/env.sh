# shellcheck shell=sh disable=SC2034
# Sourced by the stack's launchers: the stack's own Python and libraries
# (root/ holds the OpenWrt packages tools/make-stack.sh unpacked; some, such
# as libatomic, install to /lib). The prefix goes last in PATH so it shadows
# no tool of the image.
P=/data/printer
PY=$P/root/usr/bin/python3
export PYTHONHOME=$P/root/usr
export LD_LIBRARY_PATH=$P/root/lib:$P/root/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export PATH="$PATH:$P/root/usr/bin:$P/root/usr/sbin"
