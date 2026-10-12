# Сборка rootfs: разметка SD-карты, bootstrap и настройка системы

Сборка самой корневой файловой системы Alpine Linux 3.20 под `armv7`: разметка SD-карты, bootstrap базовой системы одним из двух способов (готовый `alpine-minirootfs` или `apk.static` «с нуля») и настройка системы внутри chroot — репозитории, пакеты, fstab, консоль `ttyPS0`, сеть, пользователи, часовой пояс, уровни запуска OpenRC.

Перед началом подготовьте хост ([«Подготовка хоста»](Host-Build-Environment.md)). Общая схема загрузки и разделов SD-карты — [«Загрузочная цепочка», раздел 1](Boot-Chain.md#1-как-устроена-загрузка-zynq-7010).

## Оглавление

- [1. Разметка SD-карты](#1-разметка-sd-карты)
- [2. Способ A: быстрый старт с alpine-minirootfs](#2-способ-a-быстрый-старт-с-alpine-minirootfs)
- [3. Способ B: сборка rootfs "с нуля" через apk-tools-static](#3-способ-b-сборка-rootfs-с-нуля-через-apk-tools-static)
- [4. Настройка системы внутри rootfs](#4-настройка-системы-внутри-rootfs)

## 1. Разметка SD-карты

Определите устройство карты (**внимательно!** — ошибка здесь стирает не тот диск):

```bash
lsblk
```

Далее `$SDCARD` — это `/dev/sdX` (USB-картридер) либо `/dev/mmcblkX` (встроенный слот); в обоих случаях разделы у них называются по-разному (`sdX1`/`sdX2` против `mmcblkXp1`/`mmcblkXp2`) — учитывайте это в командах ниже.

```bash
export SDCARD=/dev/sdX   # ЗАМЕНИТЕ на реальное устройство!

sudo parted -s "$SDCARD" mklabel msdos
sudo parted -s "$SDCARD" mkpart primary fat32 4MiB 260MiB
sudo parted -s "$SDCARD" set 1 boot on
sudo parted -s "$SDCARD" mkpart primary ext4 260MiB 100%
sudo partprobe "$SDCARD"

case "$SDCARD" in *[0-9]) PART_PREFIX="${SDCARD}p" ;; *) PART_PREFIX="$SDCARD" ;; esac
export BOOT_PART="${PART_PREFIX}1" ROOT_PART="${PART_PREFIX}2"
sudo udevadm settle  # на хосте с udev; в контейнере создание /dev-узлов может быть недоступно
test -b "$BOOT_PART" && test -b "$ROOT_PART" || { echo "Разделы ещё не доступны"; exit 1; }
sudo mkfs.vfat -F 32 -n BOOT "$BOOT_PART"
sudo mkfs.ext4 -L rootfs "$ROOT_PART"
```

Отступ 4 МиБ от начала карты — стандартная практика выравнивания под erase-block; первый раздел не должен начинаться с сектора 0.

## 2. Способ A: быстрый старт с alpine-minirootfs

Alpine официально публикует готовые архивы `alpine-minirootfs` под armv7 — это самый быстрый путь получить рабочую базовую систему, которую затем донастраивают в chroot ([chroot-окружение](Host-Build-Environment.md#3-chroot-окружение-qemu-user-static--binfmt_misc) и [настройка системы](#4-настройка-системы-внутри-rootfs)).

```bash
ALPINE_BRANCH=3.20
ALPINE_PATCH=3.20.10     # проверьте актуальный номер: dl-cdn.alpinelinux.org/alpine/v3.20/releases/armv7/
ARCH=armv7                 # см. пояснение во «Введении», раздел 2 — при необходимости можно вернуть armhf

mkdir -p ~/alpine-zynq/rootfs && cd ~/alpine-zynq

wget "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/releases/${ARCH}/alpine-minirootfs-${ALPINE_PATCH}-${ARCH}.tar.gz"
wget "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_BRANCH}/releases/${ARCH}/alpine-minirootfs-${ALPINE_PATCH}-${ARCH}.tar.gz.sha256"
sha256sum -c "alpine-minirootfs-${ALPINE_PATCH}-${ARCH}.tar.gz.sha256"

sudo tar -xzf "alpine-minirootfs-${ALPINE_PATCH}-${ARCH}.tar.gz" -C rootfs
```

На выходе — минимальная система (busybox, apk-tools, alpine-baselayout, musl) без OpenRC и других пакетов; их ставим уже в chroot ([раздел 4](#4-настройка-системы-внутри-rootfs)). Если вам подходит этот путь — переходите сразу к [разделу 3 страницы «Подготовка хоста»](Host-Build-Environment.md#3-chroot-окружение-qemu-user-static--binfmt_misc), пропустив [раздел 3](#3-способ-b-сборка-rootfs-с-нуля-через-apk-tools-static).

## 3. Способ B: сборка rootfs "с нуля" через apk-tools-static

Этот способ ближе к буквальному смыслу "**сборки**" файловой системы: система инициализируется пакетным менеджером `apk` напрямую в пустой каталог, без готового архива. Официально описан в Alpine Wiki ("Bootstrapping Alpine Linux").

Перед началом скачайте статический бинарник `apk.static` в `~/alpine-zynq` — см. [«Подготовка хоста», раздел 2](Host-Build-Environment.md#2-статический-apk-tools-apkstatic).

```bash
mkdir -p ~/alpine-zynq/rootfs && cd ~/alpine-zynq

ARCH=armv7
BRANCH=v3.20

sudo ./apk.static \
    --arch "$ARCH" \
    -X "https://dl-cdn.alpinelinux.org/alpine/${BRANCH}/main" \
    -X "https://dl-cdn.alpinelinux.org/alpine/${BRANCH}/community" \
    -U --allow-untrusted \
    --root "$(pwd)/rootfs" \
    --initdb add alpine-base
```

Пояснения к флагам:

- `--arch armv7` — целевая архитектура пакетов (не хоста!).
- `-X <url>` — источник пакетов; указываем main и community отдельно, оба нужны для дальнейшей установки пакетов вроде `openssh`, `chrony` и т.д.
- `-U --allow-untrusted` — на этом шаге в чистом каталоге ещё нет доверенных ключей подписи Alpine, поэтому первичная установка идёт без проверки подписей индекса **и пакетов**. Пакет `alpine-keys` при этом устанавливается вместе с `alpine-base`, и **все последующие** `apk add` внутри уже готовой системы будут проходить с полной проверкой подписи — `--allow-untrusted` используется только один раз, на bootstrap.
- `--initdb` — инициализировать базу данных apk в новом `--root`.

После этой команды `rootfs/` содержит `alpine-base`, включая OpenRC и служебные пакеты BusyBox. Способ A даёт более минимальный набор; следующий раздел добавляет недостающие компоненты.

## 4. Настройка системы внутри rootfs

### 4.1 Репозитории apk

```sh
cat > /etc/apk/repositories <<'EOF'
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
EOF

echo "nameserver 1.1.1.1" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf

apk update
apk upgrade
```

### 4.2 Базовый набор пакетов

```sh
apk add alpine-base openrc alpine-conf \
    e2fsprogs e2fsprogs-extra dosfstools parted util-linux \
    kmod \
    openssh chrony tzdata \
    nano less \
    iproute2 iptables
```

Пояснения по выбору:

- `openrc` — система инициализации Alpine (обычно уже тянется как зависимость `alpine-base`, но явное добавление не повредит).
- `e2fsprogs`/`dosfstools`/`parted`/`util-linux` — работа с файловыми системами и разделами прямо с платы (полезно для обслуживания).
- `kmod` — загрузка модулей ядра, если часть драйверов собрана как `=m`.
- `openssh` — полноценный SSH-сервер; для более компактного варианта замените на `dropbear` (заметно меньше по размеру, распространённый выбор для embedded).
- `chrony` — синхронизация времени по NTP (на большинстве embedded-плат нет RTC с батарейкой, время после включения "уезжает" в 1970/2000 год).
- Устройства в `/dev` на Alpine по умолчанию управляются `mdev` (часть busybox) — отдельный пакет не требуется; `eudev` ставьте отдельно только если нужен полноценный udev с сложными правилами hotplug.

Опционально, под задачу:

```sh
apk add wpa_supplicant iw          # USB Wi-Fi адаптер (сам Zynq PS Wi-Fi не имеет)
apk add python3                     # скрипты на плате
apk add i2c-tools spi-tools usbutils # работа с периферией через PL/EMIO
```

### 4.3 hostname и fstab

```sh
echo "zynq7010" > /etc/hostname

cat > /etc/fstab <<'EOF'
/dev/mmcblk0p1  /boot     vfat    defaults          0  2
/dev/mmcblk0p2  /         ext4    defaults,noatime  0  1
proc            /proc     proc    defaults          0  0
sysfs           /sys      sysfs   defaults          0  0
devpts          /dev/pts  devpts  defaults          0  0
tmpfs           /tmp      tmpfs   defaults,nosuid,size=64m  0  0
EOF

mkdir -p /boot
```

### 4.4 Консоль: inittab и ttyPS0

Драйвер PS UART в mainline-ядре (`xuartps`/Cadence UART) регистрирует устройство как `/dev/ttyPS0` (иногда `ttyPS1` для второго UART) — не `ttyS0` и не `ttyAMA0`. Добавьте getty на этот терминал и уберите неиспользуемые виртуальные консоли, которых на безголовой плате не существует:

```sh
sed -i '/^tty[2-6]::/d' /etc/inittab
grep -q '^ttyPS0::' /etc/inittab || \
    echo 'ttyPS0::respawn:/sbin/getty -L 115200 ttyPS0 vt100' >> /etc/inittab
grep -qxF ttyPS0 /etc/securetty || echo ttyPS0 >> /etc/securetty
```

Последняя строка разрешает вход **root через физическую UART-консоль**. Без неё Alpine может сразу ответить `Login incorrect`, даже при правильном пароле. Это не разрешает парольный вход root по SSH: для SSH настройте ключи либо обычного пользователя отдельно.

### 4.5 Сеть

Встроенный в PS Zynq контроллер Gigabit Ethernet (Cadence GEM, драйвер `macb` в mainline-ядре) обычно виден в системе как `eth0`:

```sh
mkdir -p /etc/network
cat > /etc/network/interfaces <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
EOF
```

### 4.6 Пароль root и пользователи

```sh
passwd root
# adduser myuser && addgroup myuser wheel   # при необходимости обычного пользователя
```

> Не оставляйте root без пароля на устройстве, доступном по сети (SSH включён в разделах [4.2](#42-базовый-набор-пакетов)/[4.8](#48-openrc--уровни-запуска)) — это открытый вход для кого угодно в вашей локальной сети.

### 4.7 Часовой пояс

```sh
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
echo "Europe/Moscow" > /etc/timezone
```
(замените `Europe/Moscow` на нужный пояс; список — `ls /usr/share/zoneinfo/`).

### 4.8 OpenRC — уровни запуска

Стандартный для Alpine набор сервисов по runlevel’ам:

```sh
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add mdev sysinit
rc-update add hwdrivers sysinit

rc-update add fsck boot
rc-update add root boot
rc-update add localmount boot
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
```

Самой установки пакетов недостаточно для гарантированного наполнения runlevel: добавляйте службы явно, как выше. `alpine-base` нужен и для minirootfs: он устанавливает `busybox-openrc` (служба `syslog`) и `busybox-mdev-openrc` (служба `mdev`). `root` перемонтирует корень, `localmount` обрабатывает fstab. Проверьте список: `rc-update show`. Если на плате нет RTC, вместо `hwclock` выберите `swclock`.

Завершение работы с chroot:

```sh
exit
```
```bash
sudo umount "$ROOTFS/dev/pts" "$ROOTFS/dev" "$ROOTFS/sys" "$ROOTFS/proc"
```

На этом сама rootfs готова. Дальше — доведение её до реально загружающейся системы на плате: [«Загрузочная цепочка»](Boot-Chain.md) и [«Развёртывание и первая загрузка»](Deployment.md).

---

← [Подготовка хоста](Host-Build-Environment.md) · [Главная](Home.md) · [Загрузочная цепочка](Boot-Chain.md) →
