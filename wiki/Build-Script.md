# Автоматизация: единый скрипт сборки rootfs

Скрипт автоматизирует bootstrap и настройку [rootfs](Rootfs-Build.md). Он **не** собирает FSBL, U-Boot, ядро или Device Tree — они зависят от платы и описаны в [«Загрузочной цепочке»](Boot-Chain.md).

Запускайте на подготовленном Debian/Ubuntu-хосте от root. Требуются `wget`, `tar`, `mount`, `mountpoint`, `chroot`, статический `qemu-arm-static` и включённый binfmt для ARM. Скрипт сначала проверяет исполнение ARM, затем монтирует псевдо-ФС. Очистка выполняется и при ошибке/прерывании. Не запускайте параллельно два экземпляра для одной rootfs.

Первый bootstrap использует `--allow-untrusted`: подписи индекса **и пакетов** на этом шаге не проверяются. URL скачиваются по HTTPS; это не замена независимой проверке происхождения. После установки `alpine-keys` обновления идут с проверкой подписей. Для особо строгой сборки заранее установите доверенные публичные ключи Alpine и уберите `--allow-untrusted`.

Скрипт лежит в репозитории отдельным файлом: [`scripts/build-alpine-zynq-rootfs.sh`](../scripts/build-alpine-zynq-rootfs.sh). Запустите его из отдельного рабочего каталога:

```sh
sudo sh scripts/build-alpine-zynq-rootfs.sh
```

## Сборка в GitHub Actions (без WSL)

Workflow [`.github/workflows/build-rootfs.yml`](../.github/workflows/build-rootfs.yml) запускает тот же скрипт на `ubuntu-latest` (с `qemu-user-static` и binfmt) и публикует `alpine-zynq-rootfs.tar.gz` как artifact; при push тега `v*` архив прикрепляется к релизу. Запуск вручную: вкладка Actions → Build rootfs → Run workflow. Архив распаковывайте от root: `sudo tar --numeric-owner -xzf alpine-zynq-rootfs.tar.gz -C /mnt/rootfs`.

`WORKDIR` должен быть отдельным каталогом сборки. Для другой архитектуры задайте `ARCH=armhf`; меняйте ветку Alpine только после проверки совместимости. Если на плате нет RTC, замените `hwclock` на `swclock`. Не запускайте службы платы внутри chroot. Скрипт не задаёт пароль и не настраивает разрешение входа root по SSH: это отдельный осознанный выбор пользователя.

---

← [SquashFS + OverlayFS](SquashFS-OverlayFS.md) · [Главная](Home.md) · [Диагностика](Troubleshooting.md) →
