#!/bin/sh
# Build U-Boot proper (u-boot.elf) for the Antminer S9 control board.
# Run on a Debian/Ubuntu host; no root needed except for installing packages:
#   sudo apt-get install build-essential bison flex libssl-dev libgnutls28-dev \
#       python3 python3-dev python3-setuptools swig device-tree-compiler \
#       gcc-arm-linux-gnueabihf bc
set -eu

UBOOT_TAG=${UBOOT_TAG:-v2026.04}
UBOOT_URL=${UBOOT_URL:-https://github.com/u-boot/u-boot.git}
BOARD_DIR=$(cd "$(dirname "$0")/../uboot/antminer-s9" && pwd -P)
WORKDIR=${WORKDIR:-"$(pwd)/uboot-build"}
OUT=${OUT:-"$WORKDIR/out"}

for cmd in git make arm-linux-gnueabihf-gcc dtc bison flex swig; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done

mkdir -p "$WORKDIR" "$OUT"
if [ ! -d "$WORKDIR/u-boot/.git" ]; then
    git clone --depth 1 --branch "$UBOOT_TAG" "$UBOOT_URL" "$WORKDIR/u-boot"
fi
cd "$WORKDIR/u-boot"

export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
cp "$BOARD_DIR/zynq-antminer-s9.dts" arch/arm/dts/
make xilinx_zynq_virt_defconfig
scripts/kconfig/merge_config.sh -m .config "$BOARD_DIR/antminer_s9.config"
make olddefconfig
make DEVICE_TREE=zynq-antminer-s9 -j"$(nproc)"

cp u-boot.elf u-boot.bin "$OUT/"
echo ">>> Done: $OUT/u-boot.elf (use it in boot.bif after fsbl.elf)"
