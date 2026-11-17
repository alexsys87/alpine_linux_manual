#!/bin/sh
# Assemble a full SD-card image for the Antminer S9 from ready-made artifacts:
#   partition 1: FAT32  BOOT.BIN, u-boot.img, zImage, devicetree.dtb, uInitrd, boot.scr
#   partition 2: SquashFS (read-only Alpine rootfs + kernel modules)
#   partition 3: ext4 overlay upper layer (only MODE=persistent)
# The initramfs mounts the SquashFS and puts an OverlayFS on top of it.
# See wiki/SquashFS-OverlayFS.md.
#
# Inputs (artifacts of the other build scripts/workflows):
#   ROOTFS_TAR  alpine-zynq-rootfs.tar.gz     (build-alpine-zynq-rootfs.sh)
#   KERNEL_DIR  dir with zImage, devicetree.dtb, modules.tar.gz (or modules/)
#   UBOOT_DIR   dir with BOOT.BIN and u-boot.img
# Options (environment):
#   MODE=tmpfs|persistent   upper layer in RAM (default) or on partition 3
#   BOOT_SIZE_MIB=64  DATA_SIZE_MIB=128  OUT=./image-out
#   ROOT_PASSWORD_HASH=...  optional crypt(3) hash for root (e.g. openssl passwd -6)
#   CONSOLE=ttyPS0,115200
# Run as root (ownership of the rootfs files must be preserved):
#   sudo apt-get install squashfs-tools cpio gzip u-boot-tools mtools dosfstools e2fsprogs fdisk
#   sudo ROOTFS_TAR=... KERNEL_DIR=... UBOOT_DIR=... sh build-image-antminer-s9.sh
set -eu

MODE=${MODE:-tmpfs}
BOOT_SIZE_MIB=${BOOT_SIZE_MIB:-64}
DATA_SIZE_MIB=${DATA_SIZE_MIB:-128}
CONSOLE=${CONSOLE:-ttyPS0,115200}
OUT=${OUT:-"$(pwd)/image-out"}
: "${ROOTFS_TAR:?set ROOTFS_TAR}" "${KERNEL_DIR:?set KERNEL_DIR}" "${UBOOT_DIR:?set UBOOT_DIR}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
case "$MODE" in tmpfs|persistent) ;; *) echo "MODE must be tmpfs or persistent" >&2; exit 1 ;; esac
for cmd in tar mksquashfs cpio gzip mkimage mkfs.vfat mcopy mke2fs sfdisk dd truncate; do
    command -v "$cmd" >/dev/null || { echo "Missing: $cmd" >&2; exit 1; }
done
for f in "$ROOTFS_TAR" "$KERNEL_DIR/zImage" "$KERNEL_DIR/devicetree.dtb" \
         "$UBOOT_DIR/BOOT.BIN" "$UBOOT_DIR/u-boot.img"; do
    [ -f "$f" ] || { echo "Missing input: $f" >&2; exit 1; }
done
[ -f "$KERNEL_DIR/modules.tar.gz" ] || [ -d "$KERNEL_DIR/modules" ] || \
    { echo "Missing $KERNEL_DIR/modules.tar.gz or modules/" >&2; exit 1; }

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd -P)
WORK=$(mktemp -d "$OUT/work.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
ROOTFS="$WORK/rootfs"
mkdir -p "$ROOTFS"

echo ">>> 1/6 Unpack rootfs and add kernel modules"
tar --numeric-owner -xzf "$ROOTFS_TAR" -C "$ROOTFS"
if [ -f "$KERNEL_DIR/modules.tar.gz" ]; then
    tar --numeric-owner -xzf "$KERNEL_DIR/modules.tar.gz" -C "$ROOTFS"
else
    cp -a "$KERNEL_DIR/modules/." "$ROOTFS/"
fi
# modules_install leaves symlinks into the kernel build tree
find "$ROOTFS/lib/modules" -maxdepth 2 \( -name build -o -name source \) -type l -delete 2>/dev/null || true

# Nothing build-specific may end up in the image.
rm -f "$ROOTFS/usr/bin/qemu-arm-static"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"
cat > "$ROOTFS/etc/fstab" <<'FSTAB'
# / is an overlay assembled by the initramfs; no root entry here.
/dev/mmcblk0p1 /boot vfat ro,noauto 0 0
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
devpts /dev/pts devpts defaults 0 0
tmpfs /tmp tmpfs defaults,nosuid,size=64m 0 0
FSTAB
if [ -n "${ROOT_PASSWORD_HASH:-}" ]; then
    # '|' is not part of a crypt(3) hash, so it is a safe sed delimiter.
    sed -i "s|^root:[^:]*:|root:${ROOT_PASSWORD_HASH}:|" "$ROOTFS/etc/shadow"
fi
[ -x "$ROOTFS/sbin/init" ] || [ -L "$ROOTFS/sbin/init" ] || { echo "rootfs has no /sbin/init" >&2; exit 1; }
BUSYBOX="$ROOTFS/bin/busybox.static"
[ -x "$BUSYBOX" ] || { echo "rootfs has no bin/busybox.static (apk add busybox-static)" >&2; exit 1; }

echo ">>> 2/6 SquashFS"
mksquashfs "$ROOTFS" "$WORK/rootfs.squashfs" -comp zstd -b 256K -noappend -quiet
SQ_BYTES=$(stat -c %s "$WORK/rootfs.squashfs")
# 20% headroom (not resizable later), rounded up to whole MiB.
ROOT_SIZE_MIB=$(( (SQ_BYTES * 12 / 10 + 1048575) / 1048576 ))

echo ">>> 3/6 initramfs (MODE=$MODE)"
INITRD="$WORK/initramfs"
mkdir -p "$INITRD/bin" "$INITRD/proc" "$INITRD/sys" "$INITRD/dev" "$INITRD/mnt" "$INITRD/newroot"
cp "$BUSYBOX" "$INITRD/bin/busybox"
chmod +x "$INITRD/bin/busybox"
if [ "$MODE" = persistent ]; then
    UPPER='wait_device /dev/mmcblk0p3
mount -t ext4 /dev/mmcblk0p3 /mnt/upper'
else
    UPPER='mount -t tmpfs tmpfs /mnt/upper'
fi
cat > "$INITRD/init" <<INIT
#!/bin/busybox sh
set -eu
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
rescue() {
    echo 'initramfs: boot failed; emergency shell (exit does not continue boot)' >&2
    exec /bin/busybox sh
}
trap rescue EXIT

wait_device() {
    n=0
    while [ ! -b "\$1" ]; do
        n=\$((n + 1))
        [ "\$n" -lt 30 ] || return 1
        sleep 1
    done
}

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

wait_device /dev/mmcblk0p2
mount -t tmpfs -o size=1M tmpfs /mnt
mkdir -p /mnt/lower /mnt/upper
mount -t squashfs -o ro /dev/mmcblk0p2 /mnt/lower

$UPPER

mkdir -p /mnt/upper/data /mnt/upper/work
mount -t overlay overlay \\
    -o lowerdir=/mnt/lower,upperdir=/mnt/upper/data,workdir=/mnt/upper/work \\
    /newroot

test -x /newroot/sbin/init
mkdir -p /newroot/mnt /newroot/dev /newroot/proc /newroot/sys
mount --move /mnt /newroot/mnt
mount --move /dev /newroot/dev
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys
exec switch_root /newroot /sbin/init
INIT
chmod +x "$INITRD/init"
( cd "$INITRD" && find . -print0 | cpio --null -o -H newc --owner=0:0 --quiet | gzip -9 ) > "$WORK/initramfs.cpio.gz"
mkimage -A arm -O linux -T ramdisk -C gzip -d "$WORK/initramfs.cpio.gz" "$WORK/uInitrd" >/dev/null

echo ">>> 4/6 boot.scr"
# Addresses come from the S9 U-Boot environment (distro boot: scriptaddr,
# kernel_addr_r, fdt_addr_r, ramdisk_addr_r); devtype/devnum/distro_bootpart
# are set by the distro boot scan.
cat > "$WORK/boot.cmd" <<CMD
echo Booting Alpine (SquashFS + OverlayFS, $MODE)
load \${devtype} \${devnum}:\${distro_bootpart} \${kernel_addr_r} zImage
load \${devtype} \${devnum}:\${distro_bootpart} \${fdt_addr_r} devicetree.dtb
load \${devtype} \${devnum}:\${distro_bootpart} \${ramdisk_addr_r} uInitrd
setenv bootargs console=$CONSOLE earlycon
bootz \${kernel_addr_r} \${ramdisk_addr_r} \${fdt_addr_r}
CMD
mkimage -A arm -O linux -T script -C none -n "boot" -d "$WORK/boot.cmd" "$WORK/boot.scr" >/dev/null

echo ">>> 5/6 Partitions"
truncate -s "${BOOT_SIZE_MIB}M" "$WORK/boot.fat"
mkfs.vfat -F 32 -n BOOT "$WORK/boot.fat" >/dev/null
for f in "$UBOOT_DIR/BOOT.BIN" "$UBOOT_DIR/u-boot.img" "$KERNEL_DIR/zImage" \
         "$WORK/uInitrd" "$WORK/boot.scr"; do
    mcopy -i "$WORK/boot.fat" "$f" ::
done
mcopy -i "$WORK/boot.fat" "$KERNEL_DIR/devicetree.dtb" ::devicetree.dtb

IMG="$OUT/alpine-zynq-s9-$MODE.img"
rm -f "$IMG"
# Layout in MiB: 4 | boot | root (squashfs) | [data]
if [ "$MODE" = persistent ]; then
    TOTAL_MIB=$((4 + BOOT_SIZE_MIB + ROOT_SIZE_MIB + DATA_SIZE_MIB + 1))
else
    TOTAL_MIB=$((4 + BOOT_SIZE_MIB + ROOT_SIZE_MIB + 1))
fi
truncate -s "${TOTAL_MIB}M" "$IMG"
{
    echo "label: dos"
    echo "unit: sectors"
    echo "start=$((4*2048)), size=$((BOOT_SIZE_MIB*2048)), type=c, bootable"
    echo "start=$(((4+BOOT_SIZE_MIB)*2048)), size=$((ROOT_SIZE_MIB*2048)), type=83"
    if [ "$MODE" = persistent ]; then
        echo "start=$(((4+BOOT_SIZE_MIB+ROOT_SIZE_MIB)*2048)), size=$((DATA_SIZE_MIB*2048)), type=83"
    fi
} | sfdisk --quiet "$IMG"
dd if="$WORK/boot.fat" of="$IMG" bs=1M seek=4 conv=notrunc status=none
dd if="$WORK/rootfs.squashfs" of="$IMG" bs=1M seek=$((4 + BOOT_SIZE_MIB)) conv=notrunc status=none
if [ "$MODE" = persistent ]; then
    truncate -s "${DATA_SIZE_MIB}M" "$WORK/data.ext4"
    mke2fs -q -t ext4 -L overlay "$WORK/data.ext4"
    dd if="$WORK/data.ext4" of="$IMG" bs=1M seek=$((4 + BOOT_SIZE_MIB + ROOT_SIZE_MIB)) conv=notrunc status=none
fi

echo ">>> 6/6 Outputs"
cp "$WORK/initramfs.cpio.gz" "$OUT/initramfs.cpio.gz"   # raw cpio, used by the QEMU test
echo ">>> Done: $IMG ($(du -h "$IMG" | cut -f1) on disk, ${TOTAL_MIB} MiB)"
sfdisk -l "$IMG" | sed -n '/Device/,$p'
