# Развёртывание на SD-карту, проверка в QEMU и первая загрузка

Перенос собранной rootfs и загрузочных файлов на SD-карту, проверка системы в QEMU без реальной платы и первая загрузка на железе. Предполагается, что rootfs ([«Сборка rootfs»](Rootfs-Build.md)) и компоненты загрузчика ([«Загрузочная цепочка»](Boot-Chain.md)) уже собраны.

## Оглавление

- [1. Перенос rootfs и загрузочных файлов на SD-карту](#1-перенос-rootfs-и-загрузочных-файлов-на-sd-карту)
- [2. Проверка в QEMU без реальной платы](#2-проверка-в-qemu-без-реальной-платы)
- [3. Первая загрузка платы](#3-первая-загрузка-платы)

## 1. Перенос rootfs и загрузочных файлов на SD-карту

Важно копировать rootfs с сохранением владельца, прав и спецфайлов (`cp -r` без флагов для этого **не годится**):

```bash
mkdir -p /mnt/boot /mnt/root
sudo mount "${SDCARD}1" /mnt/boot     # для mmcblk: "${SDCARD}p1"
sudo mount "${SDCARD}2" /mnt/root     # для mmcblk: "${SDCARD}p2"

sudo rsync -aHAX --numeric-ids "$ROOTFS"/ /mnt/root/

sudo cp BOOT.BIN               /mnt/boot/
sudo cp linux/arch/arm/boot/uImage /mnt/boot/          # или zImage
sudo cp linux/arch/arm/boot/dts/zynq-zybo-z7.dtb /mnt/boot/devicetree.dtb
sudo cp boot.scr               /mnt/boot/               # см. «Загрузочная цепочка», раздел 9

sync
sudo umount /mnt/boot /mnt/root
```

> **Продвинутый вариант** (без физической карты — например, для CI): те же образы можно собрать в файл через `dd if=/dev/zero of=sdcard.img bs=1M count=<N>`, разметить `losetup`/`kpartx` (`sudo losetup -fP sdcard.img`), затем работать с `/dev/loopXp1`/`p2` как с обычными разделами по инструкциям выше.

## 2. Проверка в QEMU без реальной платы

QEMU умеет эмулировать Zynq-7000 нативно (машина `xilinx-zynq-a9`: Cortex-A9, Cadence UART/GEM/SDHCI, DDR и т.д.) — удобно проверить, что rootfs и ядро в принципе поднимаются, ещё до прошивки на плату:

```bash
sudo apt-get install -y qemu-system-arm

# Быстрая проверка через initrd (без эмуляции SD-карты):
( cd "$ROOTFS" && find . | cpio -o -H newc | gzip > ../rootfs.cpio.gz )

qemu-system-arm -M xilinx-zynq-a9 -m 1G \
    -serial mon:stdio -nographic \
    -dtb linux/arch/arm/boot/dts/zynq-zc702.dtb \
    -kernel linux/arch/arm/boot/zImage \
    -initrd rootfs.cpio.gz \
    -append "console=ttyPS0,115200 root=/dev/ram rw earlyprintk"
```

Обратите внимание: для эмуляции в примере используется `zynq-zc702.dtb` (плата, которую знает сама QEMU-модель) — это нормально для проверки базовой ОС/rootfs, но специфичная для вашей реальной платы PL-периферия таким способом не тестируется. Выход — `Ctrl+A`, затем `X`.

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
