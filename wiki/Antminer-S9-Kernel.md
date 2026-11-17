# Ядро Linux для Antminer S9 (Zynq-7010)

Сборка ядра для управляющей платы Antminer S9 по инструкции из [«Загрузочной цепочки», раздел 6](Boot-Chain.md#6-ядро-linux). Парная страница к [U-Boot для Antminer S9](Antminer-S9-U-Boot.md).

## Поддержка в mainline

В отличие от U-Boot, **в mainline Linux платы Antminer S9 нет** (проверено по дереву `torvalds/linux` на 16 ноября 2026 г.: в `arch/arm/boot/dts` нет файлов Bitmain/Antminer). Поэтому в репозитории лежит DTS `kernel/antminer-s9/zynq-antminer-s9.dts` — копия `bitmain-antminer-s9.dts` из mainline U-Boot без свойств, нужных только загрузчику (`bootph-all`). Остальное (UART1, GEM0 с PHY по адресу 1, SDHCI0, NAND, watchdog) берётся оттуда без изменений.

## Что проверено

| Что | Результат |
|---|---|
| Сборка `v6.6.155` (тег из `gregkh/linux`) с `multi_v7_defconfig` + фрагмент конфигурации | собирается: `zImage`, `devicetree.dtb`, модули |
| Расположение DTS в `v6.6.155` | `arch/arm/boot/dts/xilinx/` (как указано в wiki) |
| Запуск в QEMU (`xilinx-zynq-a9`) с этим DTB | ядро стартует, `Machine model: Bitmain Antminer S9 Board`, консоль `ttyPS0`, `macb` (GEM) и SDHCI находятся; паника на монтировании корня — ожидаемо, rootfs не подключалась |
| Запуск на самой плате S9 | **не проверялось** |

## Сборка

```bash
sudo apt-get install -y build-essential bc bison flex libssl-dev libelf-dev \
    libncurses-dev gcc-arm-linux-gnueabihf device-tree-compiler kmod
sh scripts/build-kernel-antminer-s9.sh
```

Скрипт `scripts/build-kernel-antminer-s9.sh` клонирует ядро (по умолчанию `v6.6.155`, меняется переменной `KERNEL_TAG`), копирует DTS, регистрирует его в `Makefile`, применяет `multi_v7_defconfig` и фрагмент `kernel/antminer-s9/antminer_s9.config`, затем собирает `zImage modules dtbs`. Результат — `kernel-build/out/`: `zImage`, `devicetree.dtb`, `modules/`, `config`. В GitHub Actions то же делает workflow `build-kernel-s9.yml` (artifact `kernel-antminer-s9`).

Собирается именно **`zImage`**, а не `uImage`: штатный U-Boot для S9 включает `CONFIG_CMD_BOOTZ=y`, и ядро грузится командой `bootz`.

## Установка

1. На FAT-раздел SD-карты (рядом с `BOOT.BIN` и `u-boot.img`) положите `zImage` и `devicetree.dtb`.
2. Модули распакуйте в rootfs: `sudo tar -xzf modules.tar.gz -C /mnt/rootfs`.
3. В консоли U-Boot задайте `bootargs` с `console=ttyPS0,115200 root=/dev/mmcblk0p2 rootwait` и загрузите ядро с `bootz`; подробности — [«Загрузочная цепочка», раздел 9](Boot-Chain.md#9-параметры-и-сценарии-загрузки-u-boot).

Адреса загрузки подберите под память вашей ревизии платы (в DTS указан 1 ГиБ, у разных ревизий S9 объём отличается — поправьте `reg` в `memory@0`, если нужно).

---

← [U-Boot для Antminer S9](Antminer-S9-U-Boot.md) · [Главная](Home.md)
