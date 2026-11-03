#!/usr/bin/env python3
"""The printer stack's own install.sh (stack/install.sh) on files."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
INSTALL = REPO / "stack/install.sh"
DIRS = ("config", "logs", "gcodes", "database", "comms", "misc", "tmp", "nginx", "grumpyscreen/thumbnails")


@unittest.skipUnless(os.name == "posix", "requires POSIX sh (run in WSL)")
class StackInstallTest(unittest.TestCase):
    def setUp(self):
        if not shutil.which("sh"):
            self.skipTest("requires sh")
        self.temp = tempfile.TemporaryDirectory(prefix="c5-stack-install-")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.stack = root / "printer"
        defaults = self.stack / "defaults/config"
        (defaults / "AFC").mkdir(parents=True)
        (defaults / "printer.cfg").write_text("[include printer.base.cfg]\n")
        (defaults / "printer.base.cfg").write_text("base v2\n")
        (defaults / "AFC/AFC.cfg").write_text("afc\n")
        self.data = root / "printer_data"
        self.calibration = root / "calibration"
        self.calibration.mkdir()
        (self.calibration / "extruder.json").write_text('{"stock": 1}\n')
        self.model = root / "model"
        self.model.write_text("Creator5Pro 0029\n")

    def run_install(self):
        env = dict(os.environ, C5_PRINTER_DATA=str(self.data), C5_MODEL_FILE=str(self.model),
                   C5_CALIBRATION_DIR=str(self.calibration))
        result = subprocess.run(["sh", str(INSTALL), str(self.stack)], env=env, text=True,
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def snapshot(self):
        return {str(p.relative_to(self.data)): (p.read_bytes() if p.is_file() else None)
                for p in sorted(self.data.rglob("*"))}

    def test_fresh_install(self):
        self.run_install()
        for d in DIRS:
            self.assertTrue((self.data / d).is_dir(), d)
        config = self.data / "config"
        self.assertEqual((config / "printer.base.cfg").read_text(), "base v2\n")
        self.assertEqual((config / "AFC/AFC.cfg").read_text(), "afc\n")
        self.assertEqual((config / "calibration/extruder.json").read_text(), '{"stock": 1}\n')
        self.assertEqual((self.data / "moonraker.asvc").read_text().split(),
                         ["klipper", "moonraker", "nginx", "grumpyscreen", "mcu-wake"])

    def test_user_files_are_kept(self):
        (self.data / "config/calibration").mkdir(parents=True)
        (self.data / "config/printer.base.cfg").write_text("edited by the user\n")
        (self.data / "config/calibration/extruder.json").write_text('{"tuned": 1}\n')
        self.run_install()
        self.assertEqual((self.data / "config/printer.base.cfg").read_text(), "edited by the user\n")
        self.assertEqual((self.data / "config/calibration/extruder.json").read_text(), '{"tuned": 1}\n')
        self.assertEqual((self.data / "config/printer.cfg").read_text(), "[include printer.base.cfg]\n")

    def model_cfg(self):
        return (self.data / "config/printer.model.cfg").read_text()

    def test_model_pro(self):
        self.run_install()
        self.assertEqual(self.model_cfg(), "# Written by install.sh: Creator 5 Pro\n[include printer.pro.cfg]\n")

    def test_model_creator5_rewrites_the_file(self):
        self.run_install()
        self.model.write_text("Creator5 0028\n")
        self.run_install()
        self.assertEqual(self.model_cfg(),
                         "# Written by install.sh: Creator 5 (no chamber heater, chamber fans or aux fan)\n")

    def test_model_unknown(self):
        self.model.unlink()
        self.run_install()
        self.assertEqual(self.model_cfg(),
                         "# Written by install.sh: model unknown, assumed Creator 5 Pro\n[include printer.pro.cfg]\n")

    def test_second_run_changes_nothing(self):
        self.run_install()
        before = self.snapshot()
        self.run_install()
        self.assertEqual(self.snapshot(), before)


if __name__ == "__main__":
    unittest.main()
