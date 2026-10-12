# Squashfs + OverlayFS: неизменяемый (read-only) корень для Alpine на Zynq-7010

> Дополнение к основному мануалу «Сборка корневой файловой системы Alpine Linux 3.20 (armv7) для Zynq-7010» ([главная страница вики](Home.md)). Там, в разделе [«Что дальше»](Home.md#что-дальше), был пункт «Squashfs/overlay для read-only корня — если нужна защита от порчи ФС при внезапном отключении питания» — вот эта тема полностью.

## Оглавление

1. [О документе и зачем это нужно](#1-о-документе-и-зачем-это-нужно)
2. [Общая схема](#2-общая-схема)
3. [Stateless (tmpfs) или persistent (отдельный раздел)](#3-stateless-tmpfs-или-persistent-отдельный-раздел)
4. [Необходимые опции ядра](#4-необходимые-опции-ядра)
5. [Разметка SD-карты](#5-разметка-sd-карты)
6. [Сборка SquashFS-образа из готовой rootfs](#6-сборка-squashfs-образа-из-готовой-rootfs)
7. [Кастомный initramfs](#7-кастомный-initramfs)
8. [U-Boot: загрузка initramfs](#8-u-boot-загрузка-initramfs)
9. [Первая загрузка и проверка](#9-первая-загрузка-и-проверка)
10. [Персистентность при stateless-варианте](#10-персистентность-при-stateless-варианте)
11. [Альтернатива: штатный diskless-режим Alpine](#11-альтернатива-штатный-diskless-режим-alpine)
12. [Обновление образа](#12-обновление-образа)
13. [Типичные ошибки](#13-типичные-ошибки)
14. [Источники и ссылки](#14-источники-и-ссылки)

## 1. О документе и зачем это нужно

По умолчанию основной мануал ([«Сборка rootfs»](Rootfs-Build.md)) разворачивает rootfs на обычный ext4-раздел, доступный на запись (`root=/dev/mmcblk0p2 rw`) — это самый простой вариант, но SD-карты плохо переживают внезапное отключение питания во время записи: даже журналируемый ext4 не гарантирует целостность, если питание пропало посреди записи метаданных. Embedded-устройства обычно выключают именно так — по питанию, а не через `poweroff`.

Стандартное решение — сделать корень **read-only** через SquashFS (сжатая, доступная только для чтения ФС) и добавить сверху записываемый слой через **OverlayFS**, куда уходят все runtime-изменения. Это исключает записи в базовую ФС во время обычной работы, но не гарантирует сохранность самой SD-карты: сбой её контроллера, износ или обрыв питания во время обновления образа могут повредить и read-only данные.

## 2. Общая схема

```mermaid
flowchart TB
    A["SquashFS read-only<br/>раздел 2 SD-карты"] -->|lowerdir| C["OverlayFS"]
    B["tmpfs или раздел 3<br/>upperdir + workdir"] -->|upperdir/workdir| C
    C -->|switch_root| D["/sbin/init (OpenRC)<br/>обычный запуск системы"]
```

Загрузка теперь выглядит иначе, чем в [обычной схеме](Boot-Chain.md#1-как-устроена-загрузка-zynq-7010): U-Boot грузит **три** файла вместо двух — ядро, dtb и **initramfs**. Initramfs собирает overlay ещё до запуска настоящего init'а и передаёт ему управление через `switch_root` — только после этого начинается обычная жизнь системы (OpenRC, сеть и т.д. из [«Сборка rootfs», раздел 4](Rootfs-Build.md#4-настройка-системы-внутри-rootfs)).

## 3. Stateless (tmpfs) или persistent (отдельный раздел)

| | Вариант A: tmpfs (stateless) | Вариант B: отдельный раздел (persistent) |
|---|---|---|
| upperdir/workdir | tmpfs (RAM) | ext4 на отдельном разделе SD-карты |
| Изменения переживают перезагрузку? | Нет — при каждой загрузке система «как новая» | Да |
| Риск повреждения при обрыве питания | Нет runtime-записей в корень на SD (RAM исчезает); аппаратные сбои носителя всё ещё возможны | Записываемый ext4 может повредиться и помешать загрузке; базовый squashfs не изменяется программно, но от сбоя SD не защищён |
| Когда уместно | Устройство не обязано помнить состояние (либо важные данные хранятся отдельно, см. раздел 10) | Нужны логи/конфиг/данные между перезагрузками |

Ниже описаны оба варианта — отличаются только тем, что именно монтируется как upperdir в скрипте `/init` (раздел 7.3).

## 4. Необходимые опции ядра

Дополнение к таблице периферии на странице [«Загрузочная цепочка», раздел 6.3](Boot-Chain.md#63-периферия-zynq-ps-что-включить-в-menuconfig) — без этого overlay-схема не соберётся:

| Опция | Назначение |
|---|---|
| `CONFIG_SQUASHFS=y` | Поддержка SquashFS |
| `CONFIG_SQUASHFS_ZSTD=y` | Компрессия zstd — хороший баланс скорости распаковки и степени сжатия для Cortex-A9 (в `multi_v7_defconfig` обычно по умолчанию включена только `CONFIG_SQUASHFS_ZLIB`) |
| `CONFIG_OVERLAY_FS=y` | Поддержка OverlayFS |
| `CONFIG_TMPFS=y`, `CONFIG_TMPFS_XATTR=y` | tmpfs для backing mounts и upper варианта A; xattr необходимы для корректных copy-up/whiteout. Без них при удалении lower-файлов возможен `I/O error` |
| `CONFIG_PROC_FS=y`, `CONFIG_SYSFS=y` | Псевдо-ФС, которые монтирует `/init` |
| `CONFIG_BLK_DEV_INITRD=y` | Поддержка загрузки initramfs/initrd ядром — без неё загруженный initramfs будет просто проигнорирован |
| `CONFIG_RD_GZIP=y` | Распаковка gzip-сжатого cpio из раздела 7.4 |
| `CONFIG_DEVTMPFS=y` | Автозаполнение `/dev` в initramfs без mdev (обычно уже включено в `multi_v7_defconfig`) |

Драйверы MMC/SD Zynq (`CONFIG_MMC`, `CONFIG_MMC_BLOCK`, `CONFIG_MMC_SDHCI`, `CONFIG_MMC_SDHCI_PLTFM`, `CONFIG_MMC_SDHCI_OF_ARASAN`), а для варианта B также `CONFIG_EXT4_FS`, должны быть встроены (`=y`): этот минимальный initramfs не содержит модулей и не запускает `modprobe`.

## 5. Разметка SD-карты

Новая схема (для варианта B; для A — просто нет третьего раздела):

| # | ФС | Содержимое |
|---|---|---|
| 1 | FAT32 | `BOOT.BIN`, `uImage`/`zImage`, `devicetree.dtb`, `uInitrd`, `boot.scr` |
| 2 | squashfs | боевая rootfs (read-only образ, пишется как есть, не через `mkfs`) |
| 3 (только вариант B) | ext4 | upperdir/workdir overlay (persistent) |

```bash
export SDCARD=/dev/sdX   # ЗАМЕНИТЕ на реальное устройство!

# ВНИМАНИЕ: далее уничтожается разметка и содержимое выбранной карты.
# Сначала размонтируйте все её разделы и проверьте устройство через lsblk.
# Суффиксы ниже рассчитаны на /dev/sdX; для /dev/mmcblkN нужны p1/p2/p3.

sudo parted -s "$SDCARD" mklabel msdos
sudo parted -s "$SDCARD" mkpart primary fat32 4MiB 260MiB
sudo parted -s "$SDCARD" set 1 boot on
sudo parted -s "$SDCARD" mkpart primary 260MiB 760MiB
sudo parted -s "$SDCARD" mkpart primary ext4 760MiB 100%    # только вариант B

sudo mkfs.vfat -F 32 -n BOOT "${SDCARD}1"
# раздел 2 НЕ форматируется обычным mkfs -- в него целиком заливается готовый squashfs-образ (раздел 6)
sudo mkfs.ext4 -L overlay "${SDCARD}3"   # только вариант B
```

Размер раздела 2 (в примере 500 МиБ) подбирайте по фактическому размеру `rootfs.squashfs` из раздела 6, с небольшим запасом — партицию под squashfs, в отличие от обычной ФС, потом не расширить «на лету».

## 6. Сборка SquashFS-образа из готовой rootfs

Из уже собранной по страницам [«Подготовка хоста»](Host-Build-Environment.md) и [«Сборка rootfs»](Rootfs-Build.md) rootfs:

```bash
# На Debian/Ubuntu-хосте, не внутри ARM-chroot:
sudo apt-get install squashfs-tools cpio gzip u-boot-tools
sudo mksquashfs "$ROOTFS" rootfs.squashfs -comp zstd -b 256K -noappend
```

Перед сборкой выйдите из chroot и размонтируйте bind mount `/dev`, `/proc`, `/sys` и прочие временные ФС внутри `$ROOTFS`: они не должны попасть в образ. В `$ROOTFS/etc/fstab` не оставляйте старую запись `/dev/mmcblk0p2 / ext4 ...` и автоматическое монтирование разделов 2/3, уже занятых initramfs. Альтернатива на Alpine-хосте — `apk add squashfs-tools`; `$ROOTFS` здесь всегда путь к исходному дереву на хосте, не путь внутри chroot.

`-comp zstd` — быстрая распаковка на Cortex-A9 при хорошей степени сжатия (не забудьте `CONFIG_SQUASHFS_ZSTD=y` из раздела 4, иначе ядро не сможет смонтировать такой образ); `-b 256K` — размер блока (крупнее — чуть лучше сжатие, чуть больше RAM на кэш блоков при чтении).

Записать образ на раздел 2 — побайтово, не через обычное копирование в файловую систему:

```bash
sudo dd if=rootfs.squashfs of="${SDCARD}2" bs=4M conv=fsync status=progress
```

## 7. Кастомный initramfs

### 7.1 Компоненты

Внутри armv7-chroot ([«Подготовка хоста», раздел 3](Host-Build-Environment.md#3-chroot-окружение-qemu-user-static--binfmt_misc)):

```sh
apk add busybox-static
```

Точное имя файла внутри пакета отличается от дистрибутива к дистрибутиву — проверьте его прежде, чем копировать:

```sh
apk info -L busybox-static
```

### 7.2 Дерево initramfs

```bash
mkdir -p initramfs
mkdir -p initramfs/bin initramfs/proc initramfs/sys initramfs/dev
mkdir -p initramfs/mnt initramfs/newroot

cp "$ROOTFS"/bin/busybox.static initramfs/bin/busybox   # имя файла — см. 7.1
chmod +x initramfs/bin/busybox
```

### 7.3 Скрипт `/init`

```sh
cat > initramfs/init << 'EOF'
#!/bin/busybox sh
set -eu
export PATH=/bin:/sbin
/bin/busybox --install -s /bin
rescue() {
    echo 'initramfs: ошибка загрузки; аварийная shell (exit не продолжает загрузку)' >&2
    exec /bin/busybox sh
}
trap rescue EXIT

wait_device() {
    n=0
    while [ ! -b "$1" ]; do
        n=$((n + 1))
        [ "$n" -lt 30 ] || return 1
        sleep 1
    done
}

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

wait_device /dev/mmcblk0p2
# Отдельная точка монтирования позволяет перенести всё дерево backing mounts.
mount -t tmpfs -o size=1M tmpfs /mnt
mkdir -p /mnt/lower /mnt/upper
mount -t squashfs -o ro /dev/mmcblk0p2 /mnt/lower

# --- Вариант A: stateless (tmpfs) ---
mount -t tmpfs tmpfs /mnt/upper
# --- Вариант B: persistent -- закомментируйте mount tmpfs выше и включите обе строки:
# wait_device /dev/mmcblk0p3
# mount -t ext4 /dev/mmcblk0p3 /mnt/upper

mkdir -p /mnt/upper/data /mnt/upper/work
mount -t overlay overlay \
    -o lowerdir=/mnt/lower,upperdir=/mnt/upper/data,workdir=/mnt/upper/work \
    /newroot

test -x /newroot/sbin/init
mkdir -p /newroot/mnt /newroot/dev /newroot/proc /newroot/sys
mount --move /mnt /newroot/mnt
mount --move /dev /newroot/dev
mount --move /proc /newroot/proc
mount --move /sys /newroot/sys
exec switch_root /newroot /sbin/init
EOF
chmod +x initramfs/init
```

`switch_root` (апплет busybox) должен вызываться именно из initramfs — это отдельная временная rootfs-в-RAM, которую ядро распаковывает по указанию бутлоадера ещё до монтирования настоящего корня.

При ошибке скрипт останавливается в аварийной shell, а не продолжает загрузку с неверным корнем. Ожидание устройств ограничено примерно 30 секундами; `rootwait` ядра не заменяет это ожидание в пользовательском `/init`. Перенос `/dev`, `/proc`, `/sys` сохраняет их после смены корня, а `/mnt` делает backing mounts доступными для диагностики. Для persistent-варианта при повреждении ext4 сначала нужна его офлайн-проверка/восстановление; автоматического `fsck` или отката на tmpfs здесь нет. Размер tmpfs upper по умолчанию ограничен половиной RAM; запись больших файлов и `apk add` расходуют память, а не место на SD.

### 7.4 Упаковка и обёртка под U-Boot

```bash
cd initramfs
find . -print0 | cpio --null -o -H newc --owner=0:0 | gzip -9 > ../initramfs.cpio.gz
cd ..
mkimage -A arm -O linux -T ramdisk -C gzip -d initramfs.cpio.gz uInitrd
```

## 8. U-Boot: загрузка initramfs

Копируем `uInitrd` на boot-раздел вместе с остальным ([«Развёртывание и первая загрузка», раздел 1](Deployment.md#1-перенос-rootfs-и-загрузочных-файлов-на-sd-карту)), меняем сценарий загрузки ([«Загрузочная цепочка», раздел 9](Boot-Chain.md#9-параметры-и-сценарии-загрузки-u-boot)):

```
fatload mmc 0 0x03000000 uImage
fatload mmc 0 0x02A00000 devicetree.dtb
fatload mmc 0 0x04000000 uInitrd
setenv bootargs console=ttyPS0,115200
bootm 0x03000000 0x04000000 0x02A00000
```

Ключевое отличие от [обычного сценария загрузки](Boot-Chain.md#9-параметры-и-сценарии-загрузки-u-boot): вместо `-` (нет ramdisk) теперь реальный адрес `uInitrd`, а в `bootargs` **не нужны** `root=`/`rootwait` — какой раздел монтировать как корень теперь решает сам initramfs (раздел 7.3), а не ядро напрямую через `root=`.

Адреса приведены как пример: проверьте по размерам файлов и карте RAM, что ядро, dtb, initramfs и области распаковки не перекрываются. Для `zImage` используется `bootz`, а способ передачи ramdisk (legacy `uInitrd` либо raw cpio с `адрес:размер`) зависит от конфигурации U-Boot. Эти команды не заменяют проверку на конкретной плате.

## 9. Первая загрузка и проверка

После входа стоит убедиться, что корень действительно overlay:

```sh
mount | grep -E 'overlay| / '
```

Ожидаемая строка — что-то вроде `overlay on / type overlay (rw,...,lowerdir=/mnt/lower,upperdir=...)`.

Сначала проверьте обычную перезагрузку: создайте файл, выполните `sync`, перезагрузитесь — при варианте A файл исчезнет, при варианте B должен сохраниться. Испытания обрывом питания проводите только на запасной карте с резервной копией: они могут повредить SD/записываемый ext4, и ни сохранность файла, ни успешная загрузка не гарантированы. Одного такого испытания недостаточно для доказательства устойчивости.

## 10. Персистентность при stateless-варианте

Полностью stateless-система обычно всё равно не может позволить себе терять абсолютно всё (ключи SSH-хоста, накопленные данные приложения). Практичный подход — держать *отдельные* пути на persistent-хранилище через bind mount поверх уже собранного overlay, ещё до запуска основных сервисов:

```sh
mkdir -p /mnt/data /var/lib/myapp
mount -t ext4 /dev/mmcblk0p3 /mnt/data
mkdir -p /mnt/data/var-lib-myapp
mount --bind /mnt/data/var-lib-myapp /var/lib/myapp
```

Для этой комбинации нужен третий ext4-раздел даже при tmpfs-upper (раздел 5). Не используйте одновременно раздел 3 как upper и как отдельное data-хранилище. Сервис должен зависеть от `localmount` и запускаться до приложения; сам bind mount без существующего целевого каталога завершается ошибкой.

Такой bind mount можно сделать отдельным ранним OpenRC-сервисом (по образцу [«Кросс-компиляция», раздел 8](Cross-Compilation.md#8-автозапуск-через-openrc)) — тогда для приложения путь `/var/lib/myapp` выглядит как обычная директория, но физически она на persistent-разделе, а всё остальное дерева `/` при перезагрузке сбрасывается.

## 11. Альтернатива: штатный diskless-режим Alpine

У Alpine есть собственный, «из коробки», механизм именно для этого паттерна — **diskless mode**: `mkinitfs` собирает initramfs с поддержкой поиска/распаковки образов, а `lbu` (Local Backup Utility) сохраняет и восстанавливает изменения `/etc` (и других отмеченных путей) через архив `*.apkovl.tar.gz`, который автоматически ищется и применяется при каждой загрузке (`lbu include /path`, `lbu commit`).

Изначально рассчитан на ISO/USB-загрузку (тот же механизм используют официальные Live-образы Alpine), но применялся и для SBC — есть готовые проекты вроде `alpine-diskless-headless` (Raspberry Pi, Rock Pro 64), использующие тот же приём сборки через qemu+chroot с x86_64-хоста, что и весь основной мануал.

Плюсы: меньше кода писать самому, `lbu` — готовый документированный интерфейс для персистентности конфигурации. Минусы: рассчитан прежде всего на «стандартную» загрузку (initramfs ищет корень по метке/UUID через собственный `nlplug-findfs`, ожидает определённую раскладку) — под кастомный U-Boot-стенд его придётся адаптировать, а у механизма репутация «многих подвижных частей» (найти apkovl, применить, домонтировать по новому fstab, доустановить пакеты, продолжить загрузку). Часть опытных пользователей Alpine в продакшене в итоге пишут свой минимальный init, как в разделах 6–8 этого документа, именно ради предсказуемости.

Для знакомства с механизмом живьём — на «обычном» (не Zynq/U-Boot) железе `setup-alpine` с ответом `disk=none` включает diskless-режим со всеми штатными скриптами.

## 12. Обновление образа

Поменяли что-то в rootfs ([«Сборка rootfs», раздел 4](Rootfs-Build.md#4-настройка-системы-внутри-rootfs)) или добавили свой пакет ([«Сборка пакетов»](Packaging.md)) — пересоберите squashfs и перезалейте раздел 2 (раздел 6). Initramfs пересобирать нужно только при изменении самой логики overlay/разметки разделов, а не при обычных обновлениях содержимого rootfs.

Нельзя выполнять `dd` поверх squashfs, который сейчас смонтирован как lower работающего корня: загрузитесь с другого носителя/в recovery либо обновляйте карту на хосте при размонтированных разделах. Обрыв питания при `dd` оставит неполный, незагрузочный образ; для атомарных обновлений нужна отдельная A/B-схема. Persistent-upper может скрывать новые файлы lower старыми копиями и whiteout: перед обновлением предусмотрите резервное копирование данных и сброс/миграцию upper/work при размонтированном overlay.

## 13. Типичные ошибки

| Ошибка | Причина | Решение |
|---|---|---|
| `VFS: Cannot open root device` / initramfs не запускается вовсе | Забыт `CONFIG_BLK_DEV_INITRD=y`, либо `uInitrd` не указан в `bootm`/`bootz` | Раздел 4 (конфиг ядра), раздел 8 (адрес в `bootm`) |
| `mount: mounting /dev/mmcblk0p2 on /mnt/lower failed: Invalid argument` | `CONFIG_SQUASHFS`/`CONFIG_SQUASHFS_ZSTD` не собраны в ядро, либо раздел 2 не содержит squashfs-образ | Раздел 4; проверить, что раздел 2 действительно залит образом (раздел 6) |
| `switch_root: failed to mount moving /newroot to /: Invalid argument` | `mount -t overlay` не отработал (упал раньше по цепочке), либо скрипт запускается не из initramfs | Проверить каждую строку `/init` по отдельности (раздел 7.3); `switch_root` работает только из initramfs |
| Изменения пропадают при варианте B (должны сохраняться) | В `/init` активна строка `mount -t tmpfs` вместо `mount -t ext4 /dev/mmcblk0p3` | Раздел 7.3 — раскомментировать нужный вариант |
| `Kernel panic - not syncing: Attempted to kill init` сразу после `switch_root` | В squashfs нет `/sbin/init` — скорее всего, в `mksquashfs` (раздел 6) попал не тот каталог | Проверить содержимое `$ROOTFS` перед сборкой образа |
| `apk add` и обычная работа с пакетами не работают | Read-only тут ни при чём — overlay сам по себе полностью доступен на запись; ищите обычные причины (сеть, репозитории) как на странице [«Диагностика»](Troubleshooting.md#1-проблемы-загрузки-и-работы-системы-на-плате) | — |

## 14. Источники и ссылки

- Kernel docs — Overlay Filesystem: https://docs.kernel.org/filesystems/overlayfs.html
- SquashFS-tools (исходники, документация по опциям mksquashfs): https://github.com/plougher/squashfs-tools
- Alpine Wiki — Diskless Mode: https://wiki.alpinelinux.org/wiki/Diskless_Mode
- alpine-conf (реализация `lbu`, `setup-alpine`): https://github.com/alpinelinux/alpine-conf
- mkinitfs — генератор initramfs Alpine: https://github.com/alpinelinux/mkinitfs
- Пример адаптации diskless-режима под SBC: https://github.com/vincentserpoul/alpine-diskless-headless

---

← [Сборка пакетов](Packaging.md) · [Главная](Home.md) · [Скрипт сборки rootfs](Build-Script.md) →
