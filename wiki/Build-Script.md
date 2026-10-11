# Автоматизация: единый скрипт сборки rootfs

Скрипт ниже автоматизирует [разделы 3–4 страницы «Сборка rootfs»](Rootfs-Build.md#3-способ-b-сборка-rootfs-с-нуля-через-apk-tools-static) (саму rootfs). Сборку FSBL/U-Boot/ядра ([страница «Загрузочная цепочка»](Boot-Chain.md)) в единый скрипт сознательно не включаю — она завязана на конкретную плату/`.xsa` и обычно живёт отдельным repeatable-пайплайном.

```bash
#!/bin/sh
# build-alpine-zynq-rootfs.sh
# Сборка rootfs Alpine Linux 3.20 (armv7) для Zynq-7010.
# Запуск от root на x86_64 хосте с установленными qemu-user-static, binfmt-support, wget.
set -eu

ALPINE_BRANCH=v3.20
ARCH=armv7
WORKDIR="$(pwd)/alpine-zynq-build"
ROOTFS="$WORKDIR/rootfs"
APK_STATIC_URL="https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.6/x86_64/apk.static"
MIRROR="https://dl-cdn.alpinelinux.org/alpine"

mkdir -p "$ROOTFS"
cd "$WORKDIR"

# 1. Статический apk
[ -f apk.static ] || wget -O apk.static "$APK_STATIC_URL"
chmod +x apk.static

# 2. Bootstrap базовой системы под armv7
./apk.static \
    --arch "$ARCH" \
    -X "$MIRROR/$ALPINE_BRANCH/main" \
    -X "$MIRROR/$ALPINE_BRANCH/community" \
    -U --allow-untrusted \
    --root "$ROOTFS" \
    --initdb add alpine-base openrc

# 3. qemu-user-static для chroot
QEMU_BIN="$(command -v qemu-arm-static || true)"
[ -n "$QEMU_BIN" ] || { echo "Установите qemu-user-static (см. раздел 8)"; exit 1; }
cp "$QEMU_BIN" "$ROOTFS/usr/bin/"

# 4. Репозитории внутри rootfs
cat > "$ROOTFS/etc/apk/repositories" <<EOF
$MIRROR/$ALPINE_BRANCH/main
$MIRROR/$ALPINE_BRANCH/community
EOF

# 5. Псевдо-ФС и chroot-настройка
mount -t proc none "$ROOTFS/proc"
mount -t sysfs none "$ROOTFS/sys"
mount -o bind /dev "$ROOTFS/dev"
mount -o bind /dev/pts "$ROOTFS/dev/pts"

cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
chroot "$ROOTFS" /bin/sh -c '
    set -e
    apk update && apk upgrade
    apk add e2fsprogs dosfstools parted util-linux kmod \
            openssh chrony tzdata nano
    rc-update add hostname boot
    rc-update add bootmisc boot
    rc-update add hwclock boot
    rc-update add modules boot
    rc-update add sysctl boot
    rc-update add syslog boot
    rc-update add networking default
    rc-update add sshd default
    rc-update add chronyd default
    rc-update add local default
    rc-update add killprocs shutdown
    rc-update add mount-ro shutdown
    rc-update add savecache shutdown
    echo zynq7010 > /etc/hostname
    ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
'

# 6. fstab
cat > "$ROOTFS/etc/fstab" <<'EOF'
/dev/mmcblk0p1  /boot   vfat    defaults          0  2
/dev/mmcblk0p2  /       ext4    defaults,noatime  0  1
proc            /proc   proc    defaults          0  0
sysfs           /sys    sysfs   defaults          0  0
devpts          /dev/pts devpts defaults          0  0
tmpfs           /tmp    tmpfs   defaults,nosuid   0  0
EOF

# 7. Консоль на ttyPS0
sed -i '/^tty[2-6]::/d' "$ROOTFS/etc/inittab"
grep -q '^ttyPS0::' "$ROOTFS/etc/inittab" || \
    echo 'ttyPS0::respawn:/sbin/getty -L 115200 ttyPS0 vt100' >> "$ROOTFS/etc/inittab"

# 8. Сеть
mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

umount "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc"

echo ">>> rootfs готова: $ROOTFS"
echo ">>> Задайте пароль root перед деплоем:  sudo chroot \"$ROOTFS\" passwd root"
echo ">>> Дальше — разделы 10-12 README (ядро/U-Boot/FSBL) и раздел 11 (перенос на SD)."
```

> Номера разделов в сообщениях скрипта относятся к исходному `README.md`. В вики им соответствуют: раздел 8 → [«Подготовка хоста», раздел 3](Host-Build-Environment.md#3-chroot-окружение-qemu-user-static--binfmt_misc); разделы 10–12 → [«Загрузочная цепочка»](Boot-Chain.md) (раздел 12 README — [раздел 9 этой страницы](Boot-Chain.md#9-параметры-и-сценарии-загрузки-u-boot)); раздел 11 → [«Развёртывание и первая загрузка», раздел 1](Deployment.md#1-перенос-rootfs-и-загрузочных-файлов-на-sd-карту).

---

← [SquashFS + OverlayFS](SquashFS-OverlayFS.md) · [Главная](Home.md) · [Диагностика](Troubleshooting.md) →
