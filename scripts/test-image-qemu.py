#!/usr/bin/env python3
"""Boot the S9 image in QEMU (xilinx-zynq-a9) and check the SquashFS + OverlayFS root.

QEMU emulates a generic Zynq board, not the S9 itself and not U-Boot: the kernel,
DTB and initramfs are passed directly, the image is attached as the SD card.
This checks the initramfs, SquashFS and OverlayFS logic, the userspace boot and
persistence across a reboot (kept in persistent mode, lost in tmpfs mode).
The image file itself is never modified (a padded temporary copy is used).

Usage: test-image-qemu.py IMAGE KERNEL DTB INITRAMFS MODE [ROOT_PASSWORD]
"""
import os
import re
import subprocess
import sys
import time

image, kernel, dtb, initramfs, mode = sys.argv[1:6]
password = sys.argv[6] if len(sys.argv) > 6 else None
TIMEOUT = int(os.environ.get("BOOT_TIMEOUT", "300"))

# QEMU's SD card model needs a power-of-two size: test on a padded temporary copy.
size = os.path.getsize(image)
padded = 1
while padded < size:
    padded *= 2
tmp_image = image + ".qemu-test"
subprocess.run(["cp", "--sparse=always", image, tmp_image], check=True)
os.truncate(tmp_image, padded)


class Session:
    def __init__(self):
        cmd = [
            "qemu-system-arm", "-M", "xilinx-zynq-a9", "-m", "1024",
            "-kernel", kernel, "-dtb", dtb, "-initrd", initramfs,
            "-drive", f"if=sd,format=raw,file={tmp_image}",
            "-append", "console=ttyPS0,115200 earlycon",
            "-display", "none", "-monitor", "none",
            "-serial", "null", "-serial", "stdio",   # ttyPS0 is the second UART
        ]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        os.set_blocking(self.proc.stdout.fileno(), False)
        self.log = bytearray()
        self.n = 0

    def pump(self, wait=0.2):
        time.sleep(wait)
        try:
            data = self.proc.stdout.read()
        except BlockingIOError:
            data = None
        if data:
            self.log.extend(data)

    def text(self):
        return self.log.decode("utf-8", "replace")

    def send(self, s):
        self.proc.stdin.write(s.encode())
        self.proc.stdin.flush()

    def wait_for(self, pattern, timeout, since=0):
        end = time.time() + timeout
        rx = re.compile(pattern)
        while time.time() < end:
            self.pump()
            m = rx.search(self.text(), since)
            if m:
                return m
            if self.proc.poll() is not None:
                break
        return None

    def fail(self, msg):
        print(self.text()[-3000:])
        print("FAIL:", msg)
        self.proc.kill()
        os.unlink(tmp_image)
        sys.exit(1)

    def login(self):
        m = self.wait_for(r"login: $|[#$] $", TIMEOUT)
        if not m:
            self.fail("no login prompt or shell within timeout")
        if m.group(0).startswith("login"):
            if not password:
                self.fail("login prompt reached (boot OK) but no ROOT_PASSWORD given")
            self.send("root\n")
            if not self.wait_for(r"[Pp]assword: ?$", 30, m.end()):
                self.fail("no password prompt")
            self.send(password + "\n")
        time.sleep(2)
        self.pump(1)

    def run(self, command):
        self.n += 1
        s, e = f"TOKS{self.n}X", f"TOKE{self.n}X"
        pos = len(self.text())
        # Quote-split tokens so the echoed command line never matches the output pattern.
        self.send(f'echo "{s[:3]}""{s[3:]}"; {command}; echo "{e[:3]}""{e[3:]}"\n')
        end = time.time() + 30
        rx = re.compile(re.escape(s) + r"\r?\n(.*?)\r?\n?" + re.escape(e), re.S)
        while time.time() < end:
            self.pump()
            m = rx.search(self.text(), pos)
            if m:
                return m.group(1).strip()
        self.fail(f"command timed out: {command}")

    def stop(self):
        self.proc.kill()
        self.proc.wait()


results = []


def check(name, passed):
    results.append(passed)
    print(("PASS " if passed else "FAIL ") + name)


# --- boot 1: layout and writes
s = Session()
s.login()
root = s.run("grep ' / ' /proc/mounts")
lower = s.run("grep ' /mnt/lower ' /proc/mounts")
upper = s.run("grep ' /mnt/upper ' /proc/mounts")
check("root is overlay", root.startswith("overlay / overlay"))
check("lowerdir is /mnt/lower", "lowerdir=/mnt/lower" in root)
check("squashfs is a read-only lower", "squashfs" in lower and " ro," in lower)
check("root is writable", "WRITE_OK" in s.run("touch /rwtest && echo WRITE_OK"))
check("write goes to the upper layer", "UPPER_OK" in s.run(
    "test -f /mnt/upper/data/rwtest && echo UPPER_OK"))
if mode == "persistent":
    check("upper is ext4 on mmcblk0p3", "ext4" in upper and "mmcblk0p3" in upper)
else:
    check("upper is tmpfs", "tmpfs" in upper)
s.run("sync")
s.stop()   # hard stop, like pulling the power after sync

# --- boot 2: persistence
s = Session()
s.login()
present = "PRESENT" in s.run("test -f /rwtest && echo PRESENT")
if mode == "persistent":
    check("file survives a reboot (persistent)", present)
else:
    check("file is gone after a reboot (tmpfs)", not present)
s.stop()

os.unlink(tmp_image)
print("--- /proc/mounts (root) ---\n" + root)
sys.exit(0 if all(results) else 1)
