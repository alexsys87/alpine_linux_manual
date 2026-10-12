# Подготовка x86_64-хоста: пакеты, apk.static, chroot на qemu-user-static

Всё, что нужно подготовить на x86_64-хосте для сборки: пакеты хоста и требования к целевому оборудованию, статический `apk.static` для bootstrap rootfs и chroot-окружение на базе qemu-user-static + binfmt_misc, позволяющее исполнять armv7-бинарники целевой системы прямо на хосте.

Сама rootfs собирается на странице [«Сборка rootfs»](Rootfs-Build.md); chroot из раздела 3 используется там для её настройки.

## Оглавление

- [1. Требования](#1-требования)
- [2. Статический apk-tools (apk.static)](#2-статический-apk-tools-apkstatic)
- [3. Chroot-окружение: qemu-user-static + binfmt_misc](#3-chroot-окружение-qemu-user-static--binfmt_misc)

## 1. Требования

### 1.1 Хост-система и пакеты

Сборка выполняется на любом x86_64 Linux (примеры даны для Debian/Ubuntu; для Alpine-хоста и Fedora — см. сноски). Понадобится root/`sudo`.

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential git wget curl tar xz-utils rsync \
    qemu-user-static binfmt-support \
    parted dosfstools e2fsprogs util-linux \
    device-tree-compiler u-boot-tools \
    gcc-arm-linux-gnueabihf g++-arm-linux-gnueabihf \
    bc bison flex libssl-dev libncurses-dev python3 swig \
    cpio gzip bzip2 cmake pkg-config file
```

Команды пакетов выше проверяются на Debian/Ubuntu. Для **Alpine-хоста** нужен отдельный набор и Linux ARM-кросс-компилятор: `gcc-arm-none-eabi` предназначен для bare-metal и не является заменой `arm-linux-gnueabihf-` во всех шагах. Обычный динамический `qemu-arm` также не равнозначен `qemu-arm-static` для chroot. Выберите статический QEMU и подходящий Linux-тулчейн либо используйте подготовленный Debian/Ubuntu-хост; Alpine/Fedora-варианты здесь не проверялись сборкой.

### 1.2 Целевое оборудование

- Плата на базе Zynq-7010/XC7Z010 (в примерах — Digilent **Zybo Z7-10**; при другой плате замените имена dts/defconfig).
- microSD-карта от 4 ГБ (рекомендуется class 10 / UHS-I).
- USB-UART переходник 3.3 В (на большинстве отладочных плат уже встроен через USB-JTAG мост) и терминал (`minicom`, `picocom`, `screen`) на **115200 8N1**.
- Опционально — Ethernet-кабель (на PS Zynq есть встроенный Gigabit-контроллер Cadence GEM).

## 2. Статический apk-tools (apk.static)

Для сборки rootfs «с нуля» ([способ B на странице «Сборка rootfs»](Rootfs-Build.md#3-способ-b-сборка-rootfs-с-нуля-через-apk-tools-static)) нужен статически собранный пакетный менеджер `apk` под x86_64-хост: он устанавливает пакеты под armv7 прямо в каталог будущей rootfs, не требуя Alpine в роли хоста. Скачайте его в рабочий каталог `~/alpine-zynq`:

```bash
mkdir -p ~/alpine-zynq && cd ~/alpine-zynq

# Статический бинарник apk для x86_64-хоста (собирает армовый rootfs с хоста)
wget -O apk.static \
  "https://gitlab.alpinelinux.org/api/v4/projects/5/packages/generic/v2.14.6/x86_64/apk.static"
chmod +x apk.static
# Актуальную версию сверяйте на: https://wiki.alpinelinux.org/wiki/Bootstrapping_Alpine_Linux
```

## 3. Chroot-окружение: qemu-user-static + binfmt_misc

Оба способа bootstrap'а rootfs ([способ A](Rootfs-Build.md#2-способ-a-быстрый-старт-с-alpine-minirootfs) и [способ B](Rootfs-Build.md#3-способ-b-сборка-rootfs-с-нуля-через-apk-tools-static) на странице «Сборка rootfs») дают файлы под armv7, но выполнить что-либо *внутри* этой системы (chroot, `apk add`, `passwd` и т.д.) с x86_64-хоста напрямую нельзя — процессор хоста не умеет исполнять ARM-код. Решение — `qemu-user-static` в связке с `binfmt_misc`: ядро хоста прозрачно перенаправляет запуск ARM-бинарников в QEMU.

```bash
# Debian/Ubuntu: пакет qemu-user-static уже регистрирует binfmt автоматически.
# Проверить регистрацию:
sudo update-binfmts --display qemu-arm

# Если регистрации нет — включить вручную:
sudo update-binfmts --enable qemu-arm
```

На хостах без `binfmt-support` (например, Alpine) регистрацию делают вручную через `/proc/sys/fs/binfmt_misc/register` — самый надёжный способ это сделать одной командой:

```bash
docker run --rm --privileged multiarch/qemu-user-static -p yes
# Не используйте --reset без необходимости: он удаляет другие binfmt-регистрации.
# Для регистрации без Docker используйте printf, не echo:
# sudo mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc  # если ещё не смонтировано
# printf '%b\n' ':qemu-arm:M::\x7fELF\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/usr/bin/qemu-arm-static:F' | sudo tee /proc/sys/fs/binfmt_misc/register > /dev/null
```

Флаг `F` в binfmt-регистрации удерживает открытый интерпретатор, поэтому при такой регистрации копия внутри chroot не обязательна. Ниже копируем её для совместимости с регистрациями без `F` и прямого запуска QEMU:

```bash
ROOTFS=~/alpine-zynq/rootfs
QEMU_BIN="$(command -v qemu-arm-static)"
test -n "$QEMU_BIN" || { echo "Нет qemu-arm-static"; exit 1; }
sudo cp "$QEMU_BIN" "$ROOTFS/usr/bin/"
sudo cp -L /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
```

Монтируем псевдо-ФС и заходим в chroot:

```bash
sudo mount -t proc none "$ROOTFS/proc"
sudo mount -t sysfs none "$ROOTFS/sys"
sudo mount -o bind /dev "$ROOTFS/dev"
sudo mount --make-private "$ROOTFS/dev"
sudo mount -o bind /dev/pts "$ROOTFS/dev/pts"

sudo chroot "$ROOTFS" /bin/sh
```

Дальнейшие команды [раздела 4 страницы «Сборка rootfs»](Rootfs-Build.md#4-настройка-системы-внутри-rootfs) выполняются **уже внутри chroot** (приглашение вида `/ #`).

> Не забудьте по завершении работы ([раздел 4 страницы «Сборка rootfs»](Rootfs-Build.md#4-настройка-системы-внутри-rootfs)) размонтировать `proc`, `sys`, `dev/pts`, `dev` в обратном порядке — команды даны в конце [раздела 4 страницы «Сборка rootfs»](Rootfs-Build.md#4-настройка-системы-внутри-rootfs) и в скрипте автоматизации ([раздел «Скрипт сборки rootfs»](Build-Script.md)).

---

← [Введение](Introduction.md) · [Главная](Home.md) · [Сборка rootfs](Rootfs-Build.md) →
