#!/bin/sh
# Build U-Boot (SPL + u-boot.img) for the Bitmain Antminer S9 control board
# using the board support that is part of mainline U-Boot
# (configs/bitmain_antminer_s9_defconfig, available since v2026.07).
# Run on a Debian/Ubuntu host; root is needed only to install packages:
#   sudo apt-get install build-essential bison flex libssl-dev libgnutls28-dev \
#       python3 python3-dev python3-setuptools swig device-tree-compiler \
#       gcc-arm-linux-gnueabihf bc
set -eu

UBOOT_TAG=${UBOOT_TAG:-v2026.10}
UBOOT_URL=${UBOOT_URL:-https://github.com/u-boot/u-boot.git}
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

[ -f configs/bitmain_antminer_s9_defconfig ] || {
    echo "$UBOOT_TAG has no bitmain_antminer_s9_defconfig (need >= v2026.07)" >&2
    exit 1
}

export ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
make bitmain_antminer_s9_defconfig
make -j"$(nproc)"

# SPL path: spl/boot.bin becomes BOOT.BIN, u-boot.img goes next to it.
cp spl/boot.bin "$OUT/BOOT.BIN"
cp u-boot.img "$OUT/u-boot.img"
echo ">>> Done: $OUT/BOOT.BIN and $OUT/u-boot.img (put both on the FAT partition)"
