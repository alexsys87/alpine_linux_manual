# Развёртывание на SD-карту, проверка в QEMU и первая загрузка

Перенос собранной rootfs и загрузочных файлов на SD-карту, проверка системы в QEMU без реальной платы и первая загрузка на железе. Предполагается, что rootfs ([«Сборка rootfs»](Rootfs-Build.md)) и компоненты загрузчика ([«Загрузочная цепочка»](Boot-Chain.md)) уже собраны.

## Оглавление

- [1. Перенос rootfs и загрузочных файлов на SD-карту](#1-перенос-rootfs-и-загрузочных-файлов-на-sd-карту)
- [2. Проверка в QEMU без реальной платы](#2-проверка-в-qemu-без-реальной-платы)
- [3. Первая загрузка платы](#3-первая-загрузка-платы)

## 1. Перенос rootfs и загрузочных файлов на SD-карту

Важно копировать rootfs с сохранением владельца, прав и спецфайлов (`cp -r` без флагов для этого **не годится**):

```bash
sudo mkdir -p /mnt/boot /mnt/root
# BOOT_PART и ROOT_PART заданы при разметке (см. «Сборка rootfs»).
: "${BOOT_PART:?Укажите раздел FAT32}" "${ROOT_PART:?Укажите раздел ext4}"
sudo mount "$BOOT_PART" /mnt/boot
sudo mount "$ROOT_PART" /mnt/root

# До копирования размонтируйте псевдо-ФС chroot: иначе rsync скопирует хостовые /dev, /proc, /sys.
sudo rsync -aHAX --numeric-ids --one-file-system "$ROOTFS"/ /mnt/root/

sudo cp BOOT.BIN               /mnt/boot/
# Только для варианта SPL: второй этап обязателен (не требуется для FSBL BOOT.BIN с включённым u-boot.elf).
# sudo cp u-boot/u-boot.img /mnt/boot/
sudo cp linux/arch/arm/boot/uImage /mnt/boot/          # или zImage
sudo cp linux/arch/arm/boot/dts/xilinx/zynq-zybo-z7.dtb /mnt/boot/devicetree.dtb
sudo cp boot.scr               /mnt/boot/               # см. «Загрузочная цепочка», раздел 9

sync
sudo umount /mnt/boot /mnt/root
```

> **Продвинутый вариант** (без физической карты — например, для CI): те же образы можно собрать в файл через `dd if=/dev/zero of=sdcard.img bs=1M count=<N>`, разметить `losetup`/`kpartx` (`sudo losetup -fP sdcard.img`), затем работать с `/dev/loopXp1`/`p2` как с обычными разделами по инструкциям выше.

## 2. Проверка в QEMU без реальной платы

QEMU умеет эмулировать Zynq-7000 нативно (машина `xilinx-zynq-a9`: Cortex-A9, Cadence UART/GEM/SDHCI, DDR и т.д.) — удобно проверить, что rootfs и ядро в принципе поднимаются, ещё до прошивки на плату:

```bash
sudo apt-get install -y qemu-system-arm cpio gzip

# Быстрая проверка через initrd (без эмуляции SD-карты):
# Выполнять после размонтирования /proc, /sys, /dev в rootfs.
# bash pipefail не позволяет скрыть ошибку find/cpio за успешным gzip.
set -o pipefail
sudo bash -o pipefail -c 'cd "$1"; find . -xdev -print0 | cpio --null -o -H newc' _ "$ROOTFS" | gzip -n > rootfs.cpio.gz

qemu-system-arm -M xilinx-zynq-a9 -m 1G \
    -serial null -serial mon:stdio -nographic \
    -dtb linux/arch/arm/boot/dts/xilinx/zynq-zc702.dtb \
    -kernel linux/arch/arm/boot/zImage \
    -initrd rootfs.cpio.gz \
    -append "console=ttyPS0,115200 rdinit=/sbin/init rw earlycon"
```

Это **cpio initramfs**, не блочный ramdisk: параметр `root=/dev/ram` не нужен. В ядре обязательны `CONFIG_BLK_DEV_INITRD=y` и `CONFIG_RD_GZIP=y`; память должна вмещать распакованную rootfs. Для теста без SD-карты уберите только в копии rootfs записи `/dev/mmcblk0p1`/`p2` из fstab — на плате они нужны. Настройте тестовый пароль через `passwd` в chroot, не оставляйте его в производственном образе.

Для initramfs с OpenRC `swclock` оставьте также `CONFIG_INITRAMFS_PRESERVE_MTIME=y`: без него ядро заменяет временные метки файлов на раннее время загрузки. При отсутствии сохранённого `/var/lib/misc/openrc-shutdowntime` служба использует mtime `/sbin/openrc-run`; попытка выставить слишком раннее время может дать `Invalid argument` и заблокировать зависимый `syslog`. Это воспроизведено в QEMU и устранено пересборкой ядра с сохранением mtime; сам `cpio` уже содержит правильные метки.

Обратите внимание: `zynq-zc702.dtb` выбирает **UART1**, тогда как первый `-serial` в QEMU соответствует UART0. Поэтому сначала указан `-serial null`, затем консоль второго UART: без этого исправления окно может оставаться пустым при работающем ядре. Это проверяет базовую ОС/rootfs, но не специфичную для вашей реальной платы PL-периферию. Выход — `Ctrl+A`, затем `X`.

Более простая и уже пройденная проверка — то, что вы уже делали в [разделе 3 страницы «Подготовка хоста»](Host-Build-Environment.md#3-chroot-окружение-qemu-user-static--binfmt_misc): если внутри chroot (через `qemu-arm-static`) команды вроде `apk`, `passwd`, `ls` отрабатывают без `Illegal instruction`/`exec format error`, значит сама rootfs собрана под правильную архитектуру и в целом работоспособна.

## 3. Первая загрузка платы

1. Вставьте SD-карту, подключите UART-переходник, откройте терминал на **115200 8N1**.
2. Убедитесь, что джампер/переключатель boot mode платы выставлен на **SD** (для Zybo Z7 — `JP5`, для других плат см. документацию производителя).
3. Подайте питание. Ожидаемая последовательность в терминале: сообщения FSBL → баннер U-Boot → автозагрузка (или её прерывание по нажатию любой клавиши в течение таймаута) → распаковка ядра → лог инициализации драйверов Linux → приглашение входа Alpine (`zynq7010 login:`).
4. Войдите как `root` с паролем, заданным в [разделе 4.6 страницы «Сборка rootfs»](Rootfs-Build.md#46-пароль-root-и-пользователи).
5. Проверьте сеть и репозитории:

```sh
ip addr show eth0
apk update
```

---

← [Загрузочная цепочка](Boot-Chain.md) · [Главная](Home.md) · [Кросс-компиляция](Cross-Compilation.md) →
