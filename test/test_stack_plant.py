#!/usr/bin/env python3
"""The installer's printer-stack planting (stack_check, pick_webui, plant_stack) on files."""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "installer/opencreator-os/install.sh"
LIBRARY = REPO / "installer/opencreator-os/lib.sh"


def shell_function(source, name):
    lines = source.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(name + "()"))
    if lines[start].endswith(" }"):
        return lines[start]
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
    return "\n".join(lines[start:end + 1])


@unittest.skipUnless(os.name == "posix", "requires POSIX sh (run in WSL)")
class StackPlantTest(unittest.TestCase):
    def setUp(self):
        for tool in ("sh", "sha256sum", "awk"):
            if not shutil.which(tool):
                self.skipTest(f"requires {tool}")
        self.temp = tempfile.TemporaryDirectory(prefix="c5-stack-plant-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.stick = root / "stick"
        self.ocdir = root / "c5os/opencreator-os"
        self.ocdir.mkdir(parents=True)
        (self.stick / "stack").mkdir(parents=True)
        (self.stick / "opencreator-os").mkdir()
        self.archives = {name: f"{name} payload\n".encode() * 50
                         for name in ("stack.tar.gz", "fluidd.tar.gz", "mainsail.tar.gz")}
        for name, data in self.archives.items():
            (self.stick / "stack" / name).write_bytes(data)
        self.write_sums()
        source = INSTALLER.read_text()
        section = "#" + source.split("# --- printer stack", 1)[1].split("# --- eMMC backup to the stick", 1)[0]
        library = LIBRARY.read_text()
        self.functions = "\n".join([section] + [shell_function(library, name)
            for name in ("sum_init", "file_sum", "file_bytes", "sums_get")])

    def digest(self, name):
        return hashlib.sha256(self.archives[name]).hexdigest()

    def write_sums(self, override=None):
        lines = [f"{(override or {}).get(name, self.digest(name))}  stack/{name}"
                 for name in self.archives if (self.stick / "stack" / name).exists()]
        (self.stick / "SHA256SUMS").write_text("\n".join(lines) + "\n")

    def key(self, webui):
        return (f"SHA256SUMS\n{self.digest('stack.tar.gz')}  stack.tar.gz\n"
                f"{self.digest(webui + '.tar.gz')}  {webui}.tar.gz\n")

    def run_sh(self, body):
        q = lambda path: shlex.quote(str(path))
        script = "\n".join([
            "set -u", self.functions,
            "log() { printf '%s\\n' \"$*\"; }", "ui_info() { :; }",
            "abort() { printf '%s\\n' \"$*\" >&2; exit 2; }",
            "free_bytes() { echo 1073741824; }",
            f"STICK={q(self.stick)}", f"OCDIR={q(self.ocdir)}",
            "UI=0 C5_SYSTEM=stock MIN_FREE=0 C5_SUM=sha256sum", body,
        ])
        return subprocess.run(["sh", "-c", script], text=True, capture_output=True, timeout=30)

    def plant(self):
        return self.run_sh("stack_check && pick_webui && plant_stack")

    def test_headless_webui_plants_only_that_interface(self):
        (self.stick / "opencreator-os/WEBUI").write_bytes(b"mainsail\r\n")
        result = self.plant()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("webui: mainsail", result.stdout)
        stack = self.ocdir / "stack"
        self.assertEqual(sorted(p.name for p in stack.iterdir()),
                         ["SHA256SUMS", "mainsail.tar.gz", "pending", "stack.tar.gz", "webui"])
        self.assertEqual((stack / "webui").read_text(), "mainsail\n")
        self.assertEqual((stack / "SHA256SUMS").read_text(), self.key("mainsail").split("\n", 1)[1])
        self.assertEqual((stack / "mainsail.tar.gz").read_bytes(), self.archives["mainsail.tar.gz"])
        self.assertFalse((self.ocdir / "stack.new").exists())

    def test_default_webui_is_fluidd(self):
        result = self.plant()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.ocdir / "stack/webui").read_text(), "fluidd\n")

    def test_installed_stack_is_not_planted_again(self):
        (self.ocdir / "stack.installed").write_text(self.key("fluidd"))
        result = self.plant()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already installed; not planted", result.stdout)
        self.assertFalse((self.ocdir / "stack").exists())

    def test_installed_stack_with_other_webui_is_planted(self):
        (self.ocdir / "stack.installed").write_text(self.key("mainsail"))
        result = self.plant()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.ocdir / "stack/webui").read_text(), "fluidd\n")

    def test_copy_mismatch_leaves_nothing(self):
        # a stick whose archive no longer matches its checksum list
        (self.stick / "stack/fluidd.tar.gz").write_bytes(b"changed on the stick")
        result = self.run_sh("stack_check && pick_webui && plant_stack; echo rc=$?")
        self.assertIn("rc=1", result.stdout)
        self.assertIn("fluidd.tar.gz copy does not match SHA256SUMS", result.stdout)
        self.assertFalse((self.ocdir / "stack").exists())
        self.assertFalse((self.ocdir / "stack.new").exists())

    def test_invalid_webui_aborts(self):
        (self.stick / "opencreator-os/WEBUI").write_text("octoprint\n")
        result = self.plant()
        self.assertEqual(result.returncode, 2)
        self.assertIn("opencreator-os/WEBUI must be fluidd or mainsail, not 'octoprint'", result.stderr)
        self.assertFalse((self.ocdir / "stack").exists())

    def test_incomplete_stick_stack_aborts(self):
        (self.stick / "stack/mainsail.tar.gz").unlink()
        result = self.run_sh("stack_check")
        self.assertEqual(result.returncode, 2)
        self.assertIn("stick stack/ is incomplete: stack/mainsail.tar.gz", result.stderr)

    def test_unlisted_archive_aborts(self):
        self.write_sums()
        sums = self.stick / "SHA256SUMS"
        sums.write_text("".join(line + "\n" for line in sums.read_text().splitlines()
                                if "fluidd" not in line))
        result = self.run_sh("stack_check")
        self.assertEqual(result.returncode, 2)
        self.assertIn("stack/fluidd.tar.gz missing or not in SHA256SUMS", result.stderr)

    def test_stack_bytes_counts_the_larger_webui(self):
        self.archives["mainsail.tar.gz"] *= 3
        (self.stick / "stack/mainsail.tar.gz").write_bytes(self.archives["mainsail.tar.gz"])
        self.write_sums()
        result = self.run_sh('stack_check; echo "have=$HAVE_STACK bytes=$STACK_BYTES"')
        want = len(self.archives["stack.tar.gz"]) + len(self.archives["mainsail.tar.gz"])
        self.assertIn(f"have=1 bytes={want}", result.stdout)

    def test_no_stack_on_stick(self):
        shutil.rmtree(self.stick / "stack")
        result = self.run_sh('stack_check; echo "have=$HAVE_STACK bytes=$STACK_BYTES"')
        self.assertIn("have=0 bytes=0", result.stdout)

    def test_plant_clears_failed_setup_state(self):
        (self.ocdir / "stack.tries").write_text("3\n")
        (self.ocdir / "stack.failed").write_text("install.sh exited 1\n")
        result = self.plant()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("the last setup failed: install.sh exited 1", result.stdout)
        self.assertFalse((self.ocdir / "stack.tries").exists())
        self.assertFalse((self.ocdir / "stack.failed").exists())
        self.assertTrue((self.ocdir / "stack/pending").exists())

    def test_not_enough_space(self):
        result = self.run_sh("free_bytes() { echo 1000; }\nstack_check && pick_webui && plant_stack; echo rc=$?")
        self.assertIn("rc=1", result.stdout)
        self.assertIn("the printer software needs", result.stdout)
        self.assertFalse((self.ocdir / "stack").exists())


if __name__ == "__main__":
    unittest.main()
