#!/usr/bin/env python3
"""The image's c5-stack-setup: offline stack install with rollback, on files."""
import hashlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest


REPO = Path(__file__).resolve().parents[1]
SETUP = REPO / "feed/x2600/base-files/usr/libexec/c5-stack-setup"
SLOT = REPO / "feed/x2600/base-files/lib/c5/slot.sh"
SERVICES = ("mcu-wake", "klipper", "moonraker", "nginx", "grumpyscreen")

INSTALL_SH = """set -u
D=$C5_PRINTER_DATA
mkdir -p "$D"
echo "run $(cat "$1/webui")" >> "$D/runs"
[ ! -f "$D/fail" ] || exit 1
while [ -f "$D/hang" ]; do sleep 1; done
exit 0
"""


def targz(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, text in files.items():
            data = text.encode()
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o755 if name.endswith(".sh") else 0o644
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


@unittest.skipUnless(os.name == "posix", "requires POSIX sh (run in WSL)")
class StackSetupTest(unittest.TestCase):
    def setUp(self):
        for tool in ("sh", "sha256sum", "tar", "flock"):
            if not shutil.which(tool):
                self.skipTest(f"requires {tool}")
        self.temp = tempfile.TemporaryDirectory(prefix="c5-stack-setup-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.data = self.root / "data"
        self.ocdir = self.data / "opencreator-os"
        self.ocdir.mkdir(parents=True)
        (self.ocdir / "model").write_text("Creator5Pro 0029\n")
        self.printer = self.data / "printer"
        self.pdata = self.data / "printer_data"
        self.mounts = self.root / "mounts"
        self.mounts.write_text(f"x {self.data} ext4 rw 0 0\n")
        self.initd = self.root / "initd"
        self.initd.mkdir()
        self.restarts = self.root / "restarts"
        for name in SERVICES:
            path = self.initd / name
            path.write_text(f'#!/bin/sh\necho "$0 $1" >> {self.restarts}\n')
            path.chmod(0o755)
        (self.root / "sysblock").mkdir()
        self.script = self.root / "c5-stack-setup"
        self.script.write_text(SETUP.read_text().replace(". /lib/c5/slot.sh", f". {SLOT}"))

    def plant(self, webui="fluidd", version="stack new 2", corrupt=False):
        stack = self.ocdir / "stack"
        stack.mkdir(exist_ok=True)
        archives = {
            "stack.tar.gz": targz({"install.sh": INSTALL_SH, "VERSION": version + "\n"}),
            f"{webui}.tar.gz": targz({"index.html": f"{webui} index\n"}),
        }
        sums = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in archives.items())
        for name, data in archives.items():
            (stack / name).write_bytes(data + (b"x" if corrupt and name == "stack.tar.gz" else b""))
        (stack / "SHA256SUMS").write_text(sums)
        (stack / "webui").write_text(webui + "\n")
        (stack / "pending").write_text("")
        return "SHA256SUMS\n" + sums

    def install_v1(self):
        (self.printer / "www").mkdir(parents=True)
        (self.printer / "VERSION").write_text("stack v1\n")
        (self.printer / "install.sh").write_text("exit 0\n")

    def run_setup(self, timeout=30):
        env = dict(os.environ, C5_DATA=str(self.data), C5_MOUNTS=str(self.mounts),
                   C5_KMSG="/dev/null", C5_PARTX="false", C5_DISK=str(self.root / "nodisk"),
                   C5_SYSBLOCK=str(self.root / "sysblock"), C5_INITD=str(self.initd),
                   C5_STACK_LOCK=str(self.root / "lock"), C5_STACK_TIMEOUT="5")
        return subprocess.run(["sh", str(self.script)], env=env, text=True,
                              capture_output=True, timeout=timeout)

    def restarted(self):
        if not self.restarts.exists():
            return []
        return self.restarts.read_text().split()[1::2]

    def runs(self):
        path = self.pdata / "runs"
        return path.read_text().splitlines() if path.exists() else []

    def test_first_install(self):
        key = self.plant("mainsail")
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((self.printer / "VERSION").read_text(), "stack new 2\n")
        self.assertEqual((self.printer / "www/index.html").read_text(), "mainsail index\n")
        self.assertEqual((self.printer / "webui").read_text(), "mainsail\n")
        self.assertEqual((self.ocdir / "stack.installed").read_text(), key)
        self.assertFalse((self.ocdir / "stack").exists())
        self.assertFalse((self.ocdir / "stack.tries").exists())
        self.assertEqual(self.restarted(), ["restart"] * 5)
        self.assertEqual(self.runs(), ["run mainsail"])
        self.assertIn("stack: installed stack new 2 with mainsail",
                      (self.ocdir / "logs/stack.log").read_text())

    def test_failure_restores_previous_stack(self):
        self.install_v1()
        self.plant()
        self.pdata.mkdir()
        (self.pdata / "fail").write_text("")
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.printer / "VERSION").read_text(), "stack v1\n")
        self.assertFalse((self.data / "printer.old").exists())
        self.assertFalse((self.data / "printer.new").exists())
        self.assertEqual((self.ocdir / "stack.tries").read_text().strip(), "1")
        self.assertTrue((self.ocdir / "stack/pending").exists())
        self.assertFalse((self.ocdir / "stack.installed").exists())
        self.assertEqual(self.restarted(), ["restart"] * 5)
        self.assertIn("install.sh exited 1", result.stdout)

    def test_gives_up_after_three_failures(self):
        self.install_v1()
        self.plant()
        self.pdata.mkdir()
        (self.pdata / "fail").write_text("")
        for _ in range(3):
            self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertEqual((self.ocdir / "stack.failed").read_text(), "install.sh exited 1\n")
        self.assertFalse((self.ocdir / "stack/pending").exists())
        self.assertEqual(len(self.runs()), 3)
        self.restarts.unlink()
        result = self.run_setup()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(self.runs()), 3)
        self.assertEqual(self.restarted(), [])
        self.assertEqual((self.printer / "VERSION").read_text(), "stack v1\n")

    def test_failed_first_install_leaves_no_stack(self):
        self.plant()
        self.pdata.mkdir()
        (self.pdata / "fail").write_text("")
        self.assertNotEqual(self.run_setup().returncode, 0)
        self.assertFalse(self.printer.exists())
        self.assertFalse((self.data / "printer.old").exists())

    def test_interrupted_setup_is_restored_then_completed(self):
        self.install_v1()
        self.printer.rename(self.data / "printer.old")
        (self.printer / "half").mkdir(parents=True)
        (self.data / "printer.new").mkdir()
        self.plant()
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("restoring", result.stdout)
        self.assertEqual((self.printer / "VERSION").read_text(), "stack new 2\n")
        self.assertFalse((self.printer / "half").exists())
        self.assertFalse((self.data / "printer.old").exists())
        self.assertFalse((self.data / "printer.new").exists())

    def test_corrupt_archive_fails_before_the_swap(self):
        self.install_v1()
        self.plant(corrupt=True)
        result = self.run_setup()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("do not match their checksums", result.stdout)
        self.assertEqual((self.printer / "VERSION").read_text(), "stack v1\n")
        self.assertEqual(self.restarted(), [])
        self.assertEqual(self.runs(), [])

    def test_nothing_planted(self):
        self.install_v1()
        result = self.run_setup()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.restarted(), [])
        self.assertFalse((self.ocdir / "stack.tries").exists())

    def test_data_not_mounted(self):
        self.plant()
        self.mounts.write_text("x / ext4 rw 0 0\n")
        result = self.run_setup()
        self.assertEqual(result.returncode, 0)
        self.assertTrue((self.ocdir / "stack/pending").exists())
        self.assertFalse(self.printer.exists())
        self.assertFalse((self.ocdir / "stack.tries").exists())

    def test_hanging_install_is_killed_and_rolled_back(self):
        self.install_v1()
        self.plant()
        self.pdata.mkdir()
        (self.pdata / "hang").write_text("")
        start = time.monotonic()
        result = self.run_setup(timeout=25)
        elapsed = time.monotonic() - start
        self.assertNotEqual(result.returncode, 0)
        self.assertGreaterEqual(elapsed, 4.5)
        self.assertEqual((self.printer / "VERSION").read_text(), "stack v1\n")
        self.assertFalse((self.data / "printer.old").exists())
        self.assertIn("still running after 5 s", (self.ocdir / "logs/stack.log").read_text())


if __name__ == "__main__":
    unittest.main()
