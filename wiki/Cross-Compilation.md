# Кросс-компиляция пользовательских программ и добавление в rootfs

Rootfs, ядро и загрузчик — это фундамент; обычно на плате должна работать ещё и **своя** программа. Ниже — как собрать её под armv7/musl и доставить в систему.

## Оглавление

- [1. Способы получить корректный бинарник](#1-способы-получить-корректный-бинарник)
- [2. Способ A: сборка внутри chroot](#2-способ-a-сборка-внутри-chroot)
- [3. Способ B: кросс-тулчейн с musl (Bootlin)](#3-способ-b-кросс-тулчейн-с-musl-bootlin)
- [4. Перенос бинарника в rootfs и на плату](#4-перенос-бинарника-в-rootfs-и-на-плату)
- [5. Динамическая линковка или статическая](#5-динамическая-линковка-или-статическая)
- [6. C++, Go, Rust](#6-c-go-rust)
- [7. Makefile и CMake под кросс-сборку](#7-makefile-и-cmake-под-кросс-сборку)
- [8. Автозапуск через OpenRC](#8-автозапуск-через-openrc)
- [9. Отладка на плате](#9-отладка-на-плате)
- [10. Типичные ошибки](#10-типичные-ошибки)

## 1. Способы получить корректный бинарник

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
apk add build-base    # внутри chroot, от root: gcc, g++, make, musl-dev, binutils
mkdir -p /usr/local/bin
cd /tmp
cat > hello.c <<'EOF'
#include <stdio.h>
int main(void) {
    printf("Hello from Zynq-7010!\n");
    return 0;
}
EOF
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
/usr/local/bin/hello
exit
```

Бинарник уже лежит в `$ROOTFS/usr/local/bin/hello` — при переносе на SD-карту ([раздел 1 страницы «Развёртывание и первая загрузка»](Deployment.md#1-перенос-rootfs-и-загрузочных-файлов-на-sd-карту)) уйдёт туда автоматически вместе со всей rootfs.

## 3. Способ B: кросс-тулчейн с musl (Bootlin)

```bash
# Проверенный существующий архив. Для нового релиза сверяйте имя в каталоге Bootlin.
TC=armv7-eabihf--musl--stable-2024.02-1
BASE_URL=https://toolchains.bootlin.com/downloads/releases/toolchains/armv7-eabihf/tarballs
wget "$BASE_URL/$TC.tar.bz2"
wget "$BASE_URL/$TC.sha256"
sha256sum -c "$TC.sha256"
tar xf "$TC.tar.bz2"

export TOOLCHAIN="$(pwd)/$TC"
export PATH="$TOOLCHAIN/bin:$PATH"
export CROSS_COMPILE=arm-buildroot-linux-musleabihf-
"${CROSS_COMPILE}gcc" -dumpmachine
```

`hello.c` должен находиться в текущем каталоге **хоста**: скопируйте его из `$ROOTFS/tmp/hello.c` либо создайте из примера выше. Путь внутри chroot не является путём хоста. Для одиночного переносимого примера используем статическую линковку:

```bash
cp "$ROOTFS/tmp/hello.c" ./hello.c
"${CROSS_COMPILE}gcc" -O2 -static -o hello hello.c
file hello
sudo cp hello "$ROOTFS/tmp/hello-cross"
sudo chroot "$ROOTFS" /tmp/hello-cross
```

Старая ссылка `stable-2025.08-1` возвращала 404. Для воспроизводимости здесь указан проверенный архив, а не выдуманный номер последнего релиза. Статический бинарник тоже должен соответствовать CPU/FPU/ABI платы; C++/сторонние библиотеки могут существенно увеличить его размер.

## 4. Перенос бинарника в rootfs и на плату

Если собирали вне chroot (способ B), скопируйте результат в rootfs так же, как модули ядра ([раздел 7 страницы «Загрузочная цепочка»](Boot-Chain.md#7-модули-ядра-в-rootfs)):

```bash
sudo install -Dm755 hello "$ROOTFS/usr/local/bin/hello"
sudo chmod 755 "$ROOTFS/usr/local/bin/hello"
```

Если система уже развёрнута на SD-карте или плата уже в сети — можно доставить бинарник напрямую, без пересборки всего образа:

Нужен настроенный SSH-доступ по ключу. По умолчанию парольный вход root через OpenSSH Alpine запрещён; наличие пароля root для UART не меняет это правило. Не отключайте защиту ради примера: настройте ключ или используйте обычного пользователя и установку через повышение прав.

```bash
BOARD_IP=192.168.1.50  # замените адрес
scp hello "root@$BOARD_IP:/usr/local/bin/"
# либо примонтировав SD-карту с хоста, как в разделе 1 страницы «Развёртывание и первая загрузка»
```

## 5. Динамическая линковка или статическая

Динамическая линковка (по умолчанию) требует на плате библиотек той же версии musl, что использовались при сборке — при сборке внутри chroot ([2](#2-способ-a-сборка-внутри-chroot)) это гарантировано автоматически (тот же rootfs); при кросс-тулчейне ([3](#3-способ-b-кросс-тулчейн-с-musl-bootlin)) версии musl обычно достаточно близки, но не гарантированы побайтово. `-static` снимает этот класс проблем полностью: благодаря musl (в отличие от glibc) статическая линковка даёт компактный бинарник без разбухания размера — хороший выбор для одиночных embedded-утилит, которые просто копируют на плату и запускают.

## 6. C++, Go, Rust

- **C++**: `apk add g++` внутри chroot либо `…-g++` из тулчейна; при динамической линковке на плате нужен пакет `libstdc++` (`apk add libstdc++`), либо линкуйте `-static-libstdc++ -static-libgcc` (или просто `-static`).
- **Go**: на хосте нужен Go (`sudo apt-get install golang-go`). Для ARMv7 без cgo явно задайте `CGO_ENABLED=0`; тогда внешние библиотеки и musl-тулчейн не нужны. Для cgo это не подходит: задайте musl-компилятор и проверьте зависимости.

```bash
mkdir -p go-hello
cd go-hello
cat > main.go <<'EOF'
package main
import "fmt"
func main() { fmt.Println("Hello from Go on Zynq!") }
EOF
CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 go build -o hello-go main.go
sudo cp hello-go "$ROOTFS/tmp/hello-go"
sudo chroot "$ROOTFS" /tmp/hello-go
cd ..
```

- **Rust**: нужны установленные `rustup`/Cargo и выбранный musl-тулчейн из раздела 3. Одного `rustup target add` недостаточно: Cargo должен использовать **ARM musl linker**, а не `cc` хоста. Для crate с C/C++-частью дополнительно настройте его `CC`/`AR`.

```bash
rustup target add armv7-unknown-linux-musleabihf
cargo new --bin rust-hello
cd rust-hello
export CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_LINKER=arm-buildroot-linux-musleabihf-gcc
cargo build --release --target armv7-unknown-linux-musleabihf
sudo cp target/armv7-unknown-linux-musleabihf/release/rust-hello "$ROOTFS/tmp/rust-hello"
sudo chroot "$ROOTFS" /tmp/rust-hello
cd ..
```

Оба примера рассчитаны на **armv7**, не на ARMv6 `armhf`. Для другого CPU/ABI настройте цели отдельно.

## 7. Makefile и CMake под кросс-сборку

```makefile
CROSS_COMPILE ?= arm-buildroot-linux-musleabihf-
CC := $(CROSS_COMPILE)gcc
CFLAGS := -O2 -Wall
LDFLAGS := -static

hello: hello.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
```

CMake toolchain-файл (`toolchain-armv7-musl.cmake`):

```cmake
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR arm)
set(CMAKE_C_COMPILER arm-buildroot-linux-musleabihf-gcc)
set(CMAKE_CXX_COMPILER arm-buildroot-linux-musleabihf-g++)
# Sysroot именно выбранного компилятора, не каталоги библиотек x86_64-хоста.
execute_process(COMMAND ${CMAKE_C_COMPILER} -print-sysroot
    OUTPUT_VARIABLE CMAKE_SYSROOT OUTPUT_STRIP_TRAILING_WHITESPACE)
set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-static")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
```

Также создайте `CMakeLists.txt` рядом с `hello.c` (toolchain-файл сам по себе не описывает проект):

```cmake
cmake_minimum_required(VERSION 3.16)
project(hello_zynq C)
add_executable(hello hello.c)
```

```bash
make hello
cmake -S . -B build -DCMAKE_TOOLCHAIN_FILE=toolchain-armv7-musl.cmake
cmake --build build
```

## 8. Автозапуск через OpenRC

Продолжение [раздела 4.8 страницы «Сборка rootfs»](Rootfs-Build.md#48-openrc--уровни-запуска). Установите реальный `/usr/local/bin/myapp`; он должен работать в foreground, а фоновый запуск и PID берёт на себя OpenRC. Это не пример для мгновенно завершающегося `hello`:

```bash
sudo tee "$ROOTFS/etc/init.d/myapp" > /dev/null <<'EOF'
#!/sbin/openrc-run
name="myapp"
command="/usr/local/bin/myapp"
command_background=true
pidfile="/run/${RC_SVC_NAME}.pid"
EOF
sudo chmod +x "$ROOTFS/etc/init.d/myapp"
sudo chroot "$ROOTFS" rc-update add myapp default
```

## 9. Отладка на плате

```sh
# на плате (или заранее внутри chroot):
apk add gdb
# gdbserver входит в пакет gdb Alpine 3.20. Только в доверенной сети: нет аутентификации.
gdbserver 192.168.1.50:2345 /usr/local/bin/myapp
```

```bash
# на хосте:
sudo apt-get install gdb-multiarch
gdb-multiarch ./myapp
```

В интерактивной консоли GDB (не в shell) выполните `target remote 192.168.1.50:2345`, заменив адрес платы. Соберите приложение с `-g`, сохраните неурезанный ELF на хосте.

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
