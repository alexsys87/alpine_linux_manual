# U-Boot для Antminer S9 (Zynq-7010)

Сборка U-Boot для управляющей платы Bitmain Antminer S9 (Zynq XC7Z010) по инструкции из [«Загрузочной цепочки», раздел 4](Boot-Chain.md#4-u-boot). Страница одновременно служит проверкой этой инструкции.

## Что проверено

| Что | Результат |
|---|---|
| Сборка по wiki: mainline `v2026.04`, `xilinx_zynq_virt_defconfig`, `DEVICE_TREE=zynq-zybo-z7` | собирается, получены `spl/boot.bin`, `u-boot.img`, `u-boot.elf` |
| Сборка для S9 (этот раздел) | собирается, получен `u-boot.elf` (SPL отключён) |
| Запуск на самой плате S9 | **не проверялось** — нужна проверка на железе |

## Почему FSBL-путь, а не SPL

В mainline U-Boot нет платы Antminer S9 и нет `ps7_init_gpl.c` для её DDR/MIO. SPL-путь ([раздел 4.2](Boot-Chain.md#42-fsbl-или-spl-два-пути-к-первой-стадии-загрузки)) потребовал бы сгенерировать этот файл из `.xsa`, которого у вас, скорее всего, нет. Поэтому используется FSBL-путь: первую стадию (`fsbl.elf` с настройками DDR и MIO именно этой платы) берёте из вендорной прошивки, а мы собираем только U-Boot proper — `u-boot.elf`.

## Файлы в репозитории

- `uboot/antminer-s9/zynq-antminer-s9.dts` — минимальное дерево устройств (SD, UART, Ethernet), основано на MicroZed.
- `uboot/antminer-s9/antminer_s9.config` — фрагмент конфигурации поверх `xilinx_zynq_virt_defconfig` (SPL выключен).
- `scripts/build-uboot-antminer-s9.sh` — клонирует U-Boot, применяет файлы выше, собирает.
- `.github/workflows/build-uboot-s9.yml` — то же в GitHub Actions; результат — artifact `uboot-antminer-s9`.

## Сборка

```bash
sudo apt-get install -y build-essential bison flex libssl-dev libgnutls28-dev \
    python3 python3-dev python3-setuptools swig device-tree-compiler \
    gcc-arm-linux-gnueabihf bc
sh scripts/build-uboot-antminer-s9.sh
```

Результат — `uboot-build/out/u-boot.elf` и `u-boot.bin`. Тег U-Boot меняется переменной `UBOOT_TAG`.

## Что нужно сделать самому

1. **Получить `fsbl.elf`** для S9 из вендорной прошивки (штатный `BOOT.BIN` содержит FSBL); как именно извлечь — зависит от инструментов, здесь не проверялось.
2. **Собрать `BOOT.BIN`** через `bootgen` по [разделу 8](Boot-Chain.md#8-сборка-bootbin-bootgen): `boot.bif` с `fsbl.elf`, затем `u-boot.elf`.
3. **Сверить DTS с вашей ревизией платы.** В `zynq-antminer-s9.dts` заложены предположения, не проверенные на железе: UART1 как консоль 115200, 256 МиБ DDR (у части ревизий 512 МиБ — `reg = <0x0 0x20000000>`), PHY Ethernet по адресу 0, загрузка с SD (`sdhci0`). NAND, USB и QSPI не описаны.
4. **Не затирать штатный NAND** до проверки: сначала загружайтесь с SD-карты и убедитесь, что консоль и U-Boot работают.

## Первый запуск

Подключите UART-консоль (115200 8N1) и загрузитесь с SD-карты с `BOOT.BIN` на FAT-разделе. Ожидаемый результат — приглашение `=>` в консоли. Если вывода нет, вероятнее всего, консоль на другом UART или FSBL не от этой платы; см. [«Диагностику»](Troubleshooting.md).

---

← [Загрузочная цепочка](Boot-Chain.md) · [Главная](Home.md)
