# Автоматизация: единый скрипт сборки rootfs

Скрипт автоматизирует bootstrap и настройку [rootfs](Rootfs-Build.md). Он **не** собирает FSBL, U-Boot, ядро или Device Tree — они зависят от платы и описаны в [«Загрузочной цепочке»](Boot-Chain.md).

Запускайте на подготовленном Debian/Ubuntu-хосте от root. Требуются `wget`, `tar`, `mount`, `mountpoint`, `chroot`, статический `qemu-arm-static` и включённый binfmt для ARM. Скрипт сначала проверяет исполнение ARM, затем монтирует псевдо-ФС. Очистка выполняется и при ошибке/прерывании. Не запускайте параллельно два экземпляра для одной rootfs.

Первый bootstrap использует `--allow-untrusted`: подписи индекса **и пакетов** на этом шаге не проверяются. URL скачиваются по HTTPS; это не замена независимой проверке происхождения. После установки `alpine-keys` обновления идут с проверкой подписей. Для особо строгой сборки заранее установите доверенные публичные ключи Alpine и уберите `--allow-untrusted`.

Сохраните блок в `build-alpine-zynq-rootfs.sh` и запустите `sudo sh build-alpine-zynq-rootfs.sh` из отдельного рабочего каталога:

```sh
#!/bin/sh
set -eu

ALPINE_BRANCH=${ALPINE_BRANCH:-v3.20}
ARCH=${ARCH:-armv7}
WORKDIR=${WORKDIR:-"$(pwd)/alpine-zynq-build"}
MIRROR=${MIRROR:-https://dl-cdn.alpinelinux.org/alpine}
APK_STATIC_URL=${APK_STATIC_URL:-https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.6/x86_64/apk.static}

[ "$(id -u)" -eq 0 ] || { echo "Запустите скрипт от root" >&2; exit 1; }
case "$ARCH" in armv7|armhf) ;; *) echo "Поддерживаются armv7/armhf" >&2; exit 1 ;; esac
for cmd in wget mount umount mountpoint chroot; do
    command -v "$cmd" >/dev/null || { echo "Нет $cmd" >&2; exit 1; }
done
QEMU_BIN=$(command -v qemu-arm-static || true)
[ -n "$QEMU_BIN" ] || { echo "Установите qemu-user-static" >&2; exit 1; }
mkdir -p "$WORKDIR"
cd "$WORKDIR"
WORKDIR=$(pwd -P)
ROOTFS="$WORKDIR/rootfs"
[ ! -L "$ROOTFS" ] || { echo "rootfs не должна быть симлинком" >&2; exit 1; }
mkdir -p "$ROOTFS"
for dir in proc sys dev dev/pts; do
    mountpoint -q "$ROOTFS/$dir" && { echo "Сначала размонтируйте $ROOTFS/$dir" >&2; exit 1; }
done

mounted_proc=0
mounted_sys=0
mounted_dev=0
mounted_pts=0
cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    # Только собственные точки монтирования; обратный порядок обязателен.
    if [ "$mounted_pts" = 1 ]; then umount "$ROOTFS/dev/pts" || status=1; fi
    if [ "$mounted_dev" = 1 ]; then umount "$ROOTFS/dev" || status=1; fi
    if [ "$mounted_sys" = 1 ]; then umount "$ROOTFS/sys" || status=1; fi
    if [ "$mounted_proc" = 1 ]; then umount "$ROOTFS/proc" || status=1; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

if [ ! -s apk.static ]; then
    wget -O apk.static.part "$APK_STATIC_URL"
    mv apk.static.part apk.static
fi
chmod +x apk.static
./apk.static --arch "$ARCH" \
    -X "$MIRROR/$ALPINE_BRANCH/main" \
    -X "$MIRROR/$ALPINE_BRANCH/community" \
    -U --allow-untrusted --root "$ROOTFS" --initdb add alpine-base

cp "$QEMU_BIN" "$ROOTFS/usr/bin/"
cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
cat > "$ROOTFS/etc/apk/repositories" <<EOF
$MIRROR/$ALPINE_BRANCH/main
$MIRROR/$ALPINE_BRANCH/community
EOF
chroot "$ROOTFS" /bin/sh -c 'apk --print-arch' || {
    echo "Не работает ARM binfmt/QEMU; см. Подготовка хоста" >&2
    exit 1
}

mkdir -p "$ROOTFS/proc" "$ROOTFS/sys" "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"; mounted_proc=1
mount -t sysfs sysfs "$ROOTFS/sys"; mounted_sys=1
mount --bind /dev "$ROOTFS/dev"; mounted_dev=1
mount --make-private "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"; mounted_pts=1

chroot "$ROOTFS" /bin/sh -ec '
    apk update
    apk upgrade
    apk add e2fsprogs e2fsprogs-extra dosfstools parted util-linux kmod \
        openssh chrony tzdata nano less iproute2 iptables
    for svc in devfs dmesg mdev hwdrivers; do rc-update add "$svc" sysinit; done
    for svc in fsck root localmount hostname bootmisc hwclock modules sysctl syslog; do
        rc-update add "$svc" boot
    done
    for svc in networking sshd chronyd local; do rc-update add "$svc" default; done
    for svc in killprocs mount-ro savecache; do rc-update add "$svc" shutdown; done
    echo zynq7010 > /etc/hostname
    ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
    echo Europe/Moscow > /etc/timezone
    mkdir -p /boot
'

cat > "$ROOTFS/etc/fstab" <<'EOF'
/dev/mmcblk0p1 /boot vfat defaults 0 2
/dev/mmcblk0p2 / ext4 defaults,noatime 0 1
proc /proc proc defaults 0 0
sysfs /sys sysfs defaults 0 0
devpts /dev/pts devpts defaults 0 0
tmpfs /tmp tmpfs defaults,nosuid,size=64m 0 0
EOF
sed -i '/^tty[2-6]::/d' "$ROOTFS/etc/inittab"
grep -q '^ttyPS0::' "$ROOTFS/etc/inittab" || \
    echo 'ttyPS0::respawn:/sbin/getty -L 115200 ttyPS0 vt100' >> "$ROOTFS/etc/inittab"
grep -qxF ttyPS0 "$ROOTFS/etc/securetty" || echo ttyPS0 >> "$ROOTFS/etc/securetty"
mkdir -p "$ROOTFS/etc/network"
cat > "$ROOTFS/etc/network/interfaces" <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF

echo ">>> rootfs готова: $ROOTFS"
echo ">>> Перед переносом задайте пароль: chroot \"$ROOTFS\" passwd root"
echo ">>> Далее: Загрузочная цепочка и Развёртывание и первая загрузка"
```

`WORKDIR` должен быть отдельным каталогом сборки. Для другой архитектуры задайте `ARCH=armhf`; меняйте ветку Alpine только после проверки совместимости. Если на плате нет RTC, замените `hwclock` на `swclock`. Не запускайте службы платы внутри chroot. Скрипт не задаёт пароль и не настраивает разрешение входа root по SSH: это отдельный осознанный выбор пользователя.

---

← [SquashFS + OverlayFS](SquashFS-OverlayFS.md) · [Главная](Home.md) · [Диагностика](Troubleshooting.md) →
