#!/bin/sh
# Build a Linux kernel (zImage + dtb + modules) for the Bitmain Antminer S9.
# The S9 is not in mainline Linux, so its DTS comes from kernel/antminer-s9/.
# Run on a Debian/Ubuntu host; root is needed only to install packages:
#   sudo apt-get install build-essential bc bison flex libssl-dev libelf-dev \
#       libncurses-dev gcc-arm-linux-gnueabihf device-tree-compiler kmod
set -eu

KERNEL_TAG=${KERNEL_TAG:-v6.6.155}
KERNEL_URL=${KERNEL_URL:-https://github.com/gregkh/linux.git}
BOARD_DIR=$(cd "$(dirname "$0")/../kernel/antminer-s9" && pwd -P)
WORKDIR=${WORKDIR:-"$(pwd)/kernel-build"}
OUT=${OUT:-"$WORKDIR/out"}

for cmd in git make arm-linux-gnueabihf-gcc bc bison flex dtc depmod; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done

mkdir -p "$WORKDIR" "$OUT"
if [ ! -d "$WORKDIR/linux/.git" ]; then
    git clone --depth 1 --branch "$KERNEL_TAG" "$KERNEL_URL" "$WORKDIR/linux"
fi
cd "$WORKDIR/linux"

# DTS directory is arch/arm/boot/dts/xilinx on 6.5+ and arch/arm/boot/dts before.
if [ -d arch/arm/boot/dts/xilinx ]; then DTS_DIR=arch/arm/boot/dts/xilinx; else DTS_DIR=arch/arm/boot/dts; fi
cp "$BOARD_DIR/zynq-antminer-s9.dts" "$DTS_DIR/"
grep -q 'zynq-antminer-s9.dtb' "$DTS_DIR/Makefile" || \
    sed -i '0,/zynq-zc702.dtb/s//zynq-antminer-s9.dtb \\\n\tzynq-zc702.dtb/' "$DTS_DIR/Makefile"
grep -q 'zynq-antminer-s9.dtb' "$DTS_DIR/Makefile" || { echo "Cannot register DTB in $DTS_DIR/Makefile" >&2; exit 1; }

export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
make multi_v7_defconfig
scripts/kconfig/merge_config.sh -m .config "$BOARD_DIR/antminer_s9.config"
make olddefconfig
make -j"$(nproc)" zImage modules dtbs

cp arch/arm/boot/zImage "$OUT/"
cp "$DTS_DIR/zynq-antminer-s9.dtb" "$OUT/devicetree.dtb"
make INSTALL_MOD_PATH="$OUT/modules" modules_install >/dev/null
cp .config "$OUT/config"
echo ">>> Done: $OUT/zImage, devicetree.dtb, modules/, config"
