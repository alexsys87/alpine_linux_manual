# Кросс-компиляция пользовательских программ и добавление в rootfs

Rootfs, ядро и загрузчик — это фундамент; обычно на плате должна работать ещё и **своя** программа. Ниже — как собрать её под armv7/musl и доставить в систему.

## Оглавление

- [1. Три способа получить корректный бинарник](#1-три-способа-получить-корректный-бинарник)
- [2. Способ A: сборка внутри chroot](#2-способ-a-сборка-внутри-chroot)
- [3. Способ B: кросс-тулчейн с musl (Bootlin)](#3-способ-b-кросс-тулчейн-с-musl-bootlin)
- [4. Перенос бинарника в rootfs и на плату](#4-перенос-бинарника-в-rootfs-и-на-плату)
- [5. Динамическая линковка или статическая](#5-динамическая-линковка-или-статическая)
- [6. C++, Go, Rust](#6-c-go-rust)
- [7. Makefile и CMake под кросс-сборку](#7-makefile-и-cmake-под-кросс-сборку)
- [8. Автозапуск через OpenRC](#8-автозапуск-через-openrc)
- [9. Отладка на плате](#9-отладка-на-плате)
- [10. Типичные ошибки](#10-типичные-ошибки)

## 1. Три способа получить корректный бинарник

| | Сборка внутри chroot (qemu) | Кросс-тулчейн с musl (например, Bootlin) |
|---|---|---|
| Установка | `apk add build-base` внутри rootfs ([раздел 3 страницы «Подготовка хоста»](Host-Build-Environment.md#3-chroot-окружение-qemu-user-static--binfmt_misc)) | скачать готовый архив с toolchains.bootlin.com |
| Скорость сборки | медленнее — под эмуляцией qemu | нативная скорость хоста |
| Совместимость ABI с целевой rootfs | гарантированная — это тот же rootfs | нужно явно выбрать `musl` как libc при скачивании тулчейна, не `glibc` |
| Когда уместно | небольшие утилиты, разовая сборка | крупные проекты, частые пересборки, CI |

> **Важно:** тулчейн `arm-linux-gnueabihf-`, который использовался для сборки ядра и U-Boot ([«Загрузочная цепочка», разделы 2](Boot-Chain.md#2-кросс-компилятор) и [4.1](Boot-Chain.md#41-выбор-источника-и-версии)), собирает под **glibc** и **для запуска программ в самой Alpine rootfs не подходит** — Alpine поголовно на **musl**. Для ядра/U-Boot это не важно (они не линкуются с libc цели), а для пользовательских программ, которые должны *работать внутри* rootfs, — критично.

## 2. Способ A: сборка внутри chroot

```bash
sudo chroot "$ROOTFS" /bin/sh
apk add build-base    # gcc, g++, make, musl-dev, binutils
```

```c
/* hello.c */
#include <stdio.h>
int main(void) {
    printf("Hello from Zynq-7010!\n");
    return 0;
}
```

```sh
gcc -O2 -o /usr/local/bin/hello hello.c
exit
```

Бинарник уже лежит в `$ROOTFS/usr/local/bin/hello` — при переносе на SD-карту ([раздел 1 страницы «Развёртывание и первая загрузка»](Deployment.md#1-перенос-rootfs-и-загрузочных-файлов-на-sd-карту)) уйдёт туда автоматически вместе со всей rootfs.

## 3. Способ B: кросс-тулчейн с musl (Bootlin)

```bash
# toolchains.bootlin.com → Architecture: armv7-eabihf, Libc: musl, Variant: stable
# имя архива меняется от релиза к релизу — проверьте актуальное на странице загрузки
wget https://toolchains.bootlin.com/downloads/releases/toolchains/armv7-eabihf/tarballs/armv7-eabihf--musl--stable-2025.08-1.tar.bz2
tar xf armv7-eabihf--musl--stable-2025.08-1.tar.bz2

TOOLCHAIN="$(pwd)/armv7-eabihf--musl--stable-2025.08-1"
export PATH="$TOOLCHAIN/bin:$PATH"
ls "$TOOLCHAIN/bin" | grep -m1 gcc   # уточнить точный префикс, обычно arm-buildroot-linux-musleabihf-
```

```bash
arm-buildroot-linux-musleabihf-gcc -O2 -o hello hello.c
```

## 4. Перенос бинарника в rootfs и на плату

Если собирали вне chroot (способ B), скопируйте результат в rootfs так же, как модули ядра ([раздел 7 страницы «Загрузочная цепочка»](Boot-Chain.md#7-модули-ядра-в-rootfs)):

```bash
sudo cp hello "$ROOTFS/usr/local/bin/"
sudo chmod 755 "$ROOTFS/usr/local/bin/hello"
```

Если система уже развёрнута на SD-карте или плата уже в сети — можно доставить бинарник напрямую, без пересборки всего образа:

```bash
scp hello root@<ip-платы>:/usr/local/bin/
# либо примонтировав SD-карту с хоста, как в разделе 1 страницы «Развёртывание и первая загрузка»
```

## 5. Динамическая линковка или статическая

Динамическая линковка (по умолчанию) требует на плате библиотек той же версии musl, что использовались при сборке — при сборке внутри chroot ([2](#2-способ-a-сборка-внутри-chroot)) это гарантировано автоматически (тот же rootfs); при кросс-тулчейне ([3](#3-способ-b-кросс-тулчейн-с-musl-bootlin)) версии musl обычно достаточно близки, но не гарантированы побайтово. `-static` снимает этот класс проблем полностью: благодаря musl (в отличие от glibc) статическая линковка даёт компактный бинарник без разбухания размера — хороший выбор для одиночных embedded-утилит, которые просто копируют на плату и запускают.

## 6. C++, Go, Rust

- **C++**: `apk add g++` внутри chroot либо `…-g++` из тулчейна; при динамической линковке на плате нужен пакет `libstdc++` (`apk add libstdc++`), либо линкуйте `-static-libstdc++ -static-libgcc` (или просто `-static`).
- **Go**: `GOOS=linux GOARCH=arm GOARM=7 go build` — кросс-компиляция без внешнего тулчейна, бинарник статический по умолчанию.
- **Rust**: `rustup target add armv7-unknown-linux-musleabihf && cargo build --release --target armv7-unknown-linux-musleabihf`.

## 7. Makefile и CMake под кросс-сборку

```makefile
CROSS_COMPILE ?= arm-buildroot-linux-musleabihf-
CC := $(CROSS_COMPILE)gcc
CFLAGS := -O2 -Wall

hello: hello.c
	$(CC) $(CFLAGS) -o $@ $<
```

CMake toolchain-файл (`toolchain-armv7-musl.cmake`):

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-buildroot-linux-musleabihf-gcc)
set(CMAKE_CXX_COMPILER arm-buildroot-linux-musleabihf-g++)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
```

```bash
cmake -B build -DCMAKE_TOOLCHAIN_FILE=toolchain-armv7-musl.cmake
cmake --build build
```

## 8. Автозапуск через OpenRC

Продолжение [раздела 4.8 страницы «Сборка rootfs»](Rootfs-Build.md#48-openrc--уровни-запуска) — простой init-скрипт для своего демона:

```bash
cat > "$ROOTFS/etc/init.d/myapp" <<'EOF'
#!/sbin/openrc-run
name="myapp"
command="/usr/local/bin/myapp"
command_background=true
pidfile="/run/${RC_SVC_NAME}.pid"
EOF
chmod +x "$ROOTFS/etc/init.d/myapp"
sudo chroot "$ROOTFS" rc-update add myapp default
```

## 9. Отладка на плате

```sh
# на плате (или заранее внутри chroot):
apk add gdb
gdbserver :2345 /usr/local/bin/myapp
```

```bash
# на хосте:
gdb-multiarch ./myapp
(gdb) target remote <ip-платы>:2345
```

## 10. Типичные ошибки

| Ошибка | Причина | Решение |
|---|---|---|
| Бинарник на месте, но не запускается / `not found` | Собран под glibc (например, обычным `arm-linux-gnueabihf-gcc` с хоста) вместо musl | Собрать musl-тулчейном ([3](#3-способ-b-кросс-тулчейн-с-musl-bootlin)) либо внутри chroot ([2](#2-способ-a-сборка-внутри-chroot)) |
| `Exec format error` | Архитектура/битность не совпадает (aarch64 или x86 вместо armv7) | `file <бинарник>` — должно быть `ELF 32-bit ... ARM` |
| Динамический бинарник падает с ошибкой отсутствующей `.so` | Версия musl в тулчейне разошлась с версией на плате | Собрать статически (`-static`) либо внутри chroot ([2](#2-способ-a-сборка-внутри-chroot)) |
| `gcc: command not found` внутри chroot | Не установлен `build-base` | `apk add build-base` |
| `libstdc++.so.6: cannot open shared object file` | На плате нет пакета `libstdc++` | `apk add libstdc++` на плате, либо `-static-libstdc++` |

---

← [Развёртывание и первая загрузка](Deployment.md) · [Главная](Home.md) · [Сборка пакетов](Packaging.md) →
