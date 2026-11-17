# U-Boot для Antminer S9 (Zynq-7010)

Сборка U-Boot для управляющей платы Bitmain Antminer S9 (Zynq XC7Z010) по инструкции из [«Загрузочной цепочки», раздел 4](Boot-Chain.md#4-u-boot). Страница одновременно служит проверкой этой инструкции.

## Поддержка в mainline

Плата входит в mainline U-Boot начиная с **v2026.07**: `configs/bitmain_antminer_s9_defconfig`, каталог `board/bitmain/antminer_s9/` (в нём собственный `ps7_init_gpl.c`) и `arch/arm/dts/bitmain-antminer-s9.dts`. В `v2026.04` её ещё нет. Поэтому используется **SPL-путь** ([раздел 4.2](Boot-Chain.md#42-fsbl-или-spl-два-пути-к-первой-стадии-загрузки)): Xilinx FSBL и `bootgen` не нужны.

## Что проверено

| Что | Результат |
|---|---|
| Сборка по wiki на `v2026.04` (`xilinx_zynq_virt_defconfig`, `DEVICE_TREE=zynq-zybo-z7`) | собирается, получены `spl/boot.bin`, `u-boot.img`, `u-boot.elf` |
| Сборка для S9 на `v2026.10` (`bitmain_antminer_s9_defconfig`) | собирается, получены `spl/boot.bin` (→ `BOOT.BIN`) и `u-boot.img`; то же в GitHub Actions |
| Запуск на самой плате S9 | **не проверялось** |

## Сборка

```bash
sudo apt-get install -y build-essential bison flex libssl-dev libgnutls28-dev \
    python3 python3-dev python3-setuptools swig device-tree-compiler \
    gcc-arm-linux-gnueabihf bc
sh scripts/build-uboot-antminer-s9.sh
```

Скрипт `scripts/build-uboot-antminer-s9.sh` клонирует U-Boot (тег по умолчанию `v2026.10`, меняется переменной `UBOOT_TAG`), выполняет `make bitmain_antminer_s9_defconfig && make` и кладёт `BOOT.BIN` (это `spl/boot.bin`) и `u-boot.img` в `uboot-build/out/`. В GitHub Actions то же делает workflow `build-uboot-s9.yml`, результат — artifact `uboot-antminer-s9`.

## Установка и первый запуск

1. Скопируйте **оба** файла на FAT-раздел SD-карты: `BOOT.BIN` и `u-boot.img` ([раздел 4.4](Boot-Chain.md#44-сборка)). Одного `BOOT.BIN` недостаточно — он содержит только SPL.
2. Подключите UART-консоль (115200 8N1) и загрузитесь с SD-карты (выбор источника загрузки на S9 задаётся перемычками платы — см. документацию на вашу ревизию).
3. Ожидаемый результат — приглашение `antminer> ` в консоли.

Особенности штатного конфига: окружение хранится в FAT и NAND (`CONFIG_ENV_IS_IN_FAT`, `CONFIG_ENV_IS_IN_NAND`), консоль — UART1, Ethernet — GEM0 с PHY по адресу 1, поддержка NAND включена. **Не затирайте штатный NAND**, пока не убедились, что загрузка с SD работает.

Если вывода нет, проверьте источник загрузки и консольный UART; см. также [«Диагностику»](Troubleshooting.md).

---

← [Загрузочная цепочка](Boot-Chain.md) · [Главная](Home.md)
