#!/bin/sh
# Run an Antminer S9 SD-card image (from build-image-antminer-s9.sh) in QEMU
# without the board. QEMU emulates a generic Zynq-7000 (xilinx-zynq-a9); it does
# not run U-Boot or the S9 hardware: the kernel, DTB and initramfs are taken from
# the image's FAT partition and passed to QEMU directly; the image is the SD card.
#
# Usage:   sh run-image-qemu.sh alpine-zynq-s9-tmpfs.img[.gz]
# Options (environment):
#   SNAPSHOT=1   (default) discard all writes on exit; the image is never modified
#   SNAPSHOT=0   keep writes in a copy "<image>.qemu.img" next to the image, so
#                a persistent-mode image keeps its data between runs
#   MEM_MIB=1024 RAM size      NET=1  add a user-mode NIC (GEM, NAT)
# Needs: qemu-system-arm mtools (apt-get install qemu-system-arm mtools)
# Exit the emulator with Ctrl+A, then X.
set -eu

IMG=${1:?usage: run-image-qemu.sh IMAGE[.gz]}
SNAPSHOT=${SNAPSHOT:-1}
MEM_MIB=${MEM_MIB:-1024}
NET=${NET:-0}
BOOT_OFFSET_MIB=4   # the FAT partition starts at 4 MiB (see build-image-antminer-s9.sh)

for cmd in qemu-system-arm mcopy truncate; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done
[ -f "$IMG" ] || { echo "No such file: $IMG" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

case "$IMG" in
    *.gz)
        RAW="$TMP/image.img"
        gzip -dc "$IMG" > "$RAW"
        [ "$SNAPSHOT" = 1 ] || { echo "SNAPSHOT=0 needs an unpacked .img" >&2; exit 1; }
        ;;
    *) RAW=$IMG ;;
esac

# Kernel, DTB and initramfs come from the image itself.
OFFSET=$((BOOT_OFFSET_MIB * 1048576))
for f in zImage devicetree.dtb uInitrd; do
    mcopy -i "$RAW@@$OFFSET" "::$f" "$TMP/$f" || { echo "Cannot read $f from the image" >&2; exit 1; }
done
tail -c +65 "$TMP/uInitrd" > "$TMP/initramfs.cpio.gz"   # strip the 64-byte U-Boot header

# QEMU's SD card model needs a power-of-two size, so the card is a padded copy.
if [ "$SNAPSHOT" = 1 ]; then
    CARD="$TMP/card.img"
else
    CARD="$RAW.qemu.img"
fi
if [ ! -f "$CARD" ]; then
    cp --sparse=always "$RAW" "$CARD"
    SIZE=$(stat -c %s "$CARD")
    PAD=1
    while [ "$PAD" -lt "$SIZE" ]; do PAD=$((PAD * 2)); done
    truncate -s "$PAD" "$CARD"
fi

NETARGS=
[ "$NET" = 1 ] && NETARGS="-nic user"

echo ">>> Starting QEMU (Ctrl+A, X to exit). Card: $CARD (snapshot=$SNAPSHOT)" >&2
# shellcheck disable=SC2086
exec qemu-system-arm -M xilinx-zynq-a9 -m "$MEM_MIB" \
    -kernel "$TMP/zImage" -dtb "$TMP/devicetree.dtb" -initrd "$TMP/initramfs.cpio.gz" \
    -append "console=ttyPS0,115200 earlycon" \
    -drive "if=sd,format=raw,file=$CARD,snapshot=$([ "$SNAPSHOT" = 1 ] && echo on || echo off)" \
    $NETARGS \
    -display none -monitor none -serial null -serial mon:stdio
