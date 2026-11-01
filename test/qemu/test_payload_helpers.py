#!/usr/bin/env python3
"""Real temporary payload assembly; no kernel builds, booting, or printer I/O."""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[2]
HARNESS = REPO / "test/qemu/lib/harness.sh"
PREFIX = "opencreator-os-x2600-generic-flashforge_creator5pro-squashfs"


class PayloadHelpersTest(unittest.TestCase):
    def setUp(self):
        for tool in ("bash", "mksquashfs", "sha256sum", "md5sum"):
            if not shutil.which(tool):
                self.skipTest(f"requires {tool}")
        self.temp = tempfile.TemporaryDirectory(prefix="c5-payload-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        for name in ("tools/make-install-stick.sh", "installer/runFirmwareExe.sh",
                     "installer/opencreator-os/install.sh", "installer/opencreator-os/lib.sh",
                     "installer/opencreator-os/restore.sh", "feed/x2600/base-files/lib/c5/slot.sh",
                     "chainload/c5-chainload.sh", "chainload/chainload_main.c",
                     "test/qemu/fixtures/fake-c5-chainload.sh",
                     "test/qemu/fixtures/fake-ui.sh", "test/qemu/fixtures/qemu-ui-hook.sh"):
            dest = self.repo / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / name, dest)
            dest.chmod((REPO / name).stat().st_mode & 0o777)
        (self.repo / "tools/make-install-stick.sh").chmod(0o755)
        for name in ("installer/tools/out/sfdisk", "installer/tools/out/partx"):
            self.put(self.repo / name, "#!/bin/sh\nexit 0\n", 0o755)
        # These artifacts are only packaged, never loaded or executed.
        self.put(self.repo / "chainload/out/chainload.ko", "test module payload\n")
        self.art = self.root / PREFIX
        Path(str(self.art) + "-kernel.uimage").write_bytes(
            b"\x27\x05\x19\x56" + bytes(60) + b"test kernel payload\n")
        self.put(Path(str(self.art) + "-sysupgrade.tar"), "test sysupgrade payload\n")
        tree = self.root / "squashfs-source"
        self.put(tree / "etc/test", "test rootfs\n")
        self.sqfs = Path(str(self.art) + "-root.squashfs")
        self.must(self.command("mksquashfs", str(tree), str(self.sqfs), "-noappend",
                               "-all-root", "-quiet", "-processors", "1"))
        self.run_dir = self.root / "run"
        self.run_dir.mkdir()
        self.out = self.root / "payload"

    @staticmethod
    def put(path, content, mode=0o644):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(mode)

    @staticmethod
    def command(*args, **kwargs):
        return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, **kwargs)

    def must(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def helper(self, name, injection=""):
        args = shlex.quote(str(self.out))
        if name == "make_ui_payload":
            args += " 'menu=2 confirm_install=ok'"
        if name == "fake_chainload":
            args = ""
        if name == "make_stick":
            args += " " + shlex.quote(str(self.root / "stick.img")) + " 64"
        if name == "flow_install":
            args = "assemble"
        script = '\n'.join([
            "set -uo pipefail",
            f"source {shlex.quote(str(HARNESS))}",
            f"QREPO={shlex.quote(str(self.repo))}",
            f"QDIR={shlex.quote(str(self.repo / 'test/qemu'))}",
            f"RUN={shlex.quote(str(self.run_dir))}",
            f"OWRT_ART={shlex.quote(str(self.art))}",
            f"OWRT_SQFS={shlex.quote(str(self.sqfs))}",
            injection,
            f"rc=0; {name} {args} || rc=$?; exit \"$rc\"",
        ])
        env = dict(os.environ, QWORK=str(self.root / "work"),
                   OWRT_BIN=str(self.root / "no-artifacts"))
        return self.command("bash", "-c", script, env=env)

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)

    def assert_checksums(self):
        for name, algorithm in (("SHA256SUMS", "sha256"), ("MD5SUMS", "md5")):
            lines = (self.out / name).read_text().splitlines()
            self.assertGreater(len(lines), 0)
            for line in lines:
                digest, path = line.split(maxsplit=1)
                actual = hashlib.new(algorithm, (self.out / path.lstrip('*')).read_bytes()).hexdigest()
                self.assertEqual(digest, actual, path)

    def test_payload_contains_real_fake_chainloader_and_updated_checksums(self):
        self.must(self.helper("make_payload"))
        script = self.out / "chainload/c5-chainload.sh"
        self.assertIn((self.repo / "chainload/c5-chainload.sh").read_text(), script.read_text())
        self.assertEqual(stat.S_IMODE(script.stat().st_mode), 0o755)
        self.assertEqual((self.out / "root.squashfs").read_bytes(), self.sqfs.read_bytes())
        self.assert_checksums()

    def test_ui_payload_installs_config_executables_and_updated_hook_checksum(self):
        self.must(self.helper("make_ui_payload"))
        for src, dest in (("fake-ui.sh", "qemu/fake-ui.sh"),
                          ("qemu-ui-hook.sh", "runFirmwareExe.sh")):
            self.assertEqual((self.out / dest).read_bytes(),
                             (self.repo / "test/qemu/fixtures" / src).read_bytes())
            self.assertEqual(stat.S_IMODE((self.out / dest).stat().st_mode), 0o755)
        self.assertEqual((self.out / "qemu/ui.conf").read_text(),
                         "menu=2\nconfirm_install=ok\n")
        self.assert_checksums()

    def test_payload_cleanup_failure_is_not_masked_by_assembly(self):
        self.assert_failed(self.helper("make_payload", 'rm() { command rm "$@"; return 1; }'))

    def test_payload_mkdir_failure_is_not_masked_by_assembly(self):
        self.assert_failed(self.helper("make_payload", 'mkdir() { command mkdir "$@"; return 1; }'))

    def test_payload_symlink_failure_is_not_masked_by_assembly(self):
        self.assert_failed(self.helper("make_payload", 'ln() { command ln "$@"; return 1; }'))

    def test_payload_chainloader_generation_failure_is_not_masked_by_checksums(self):
        self.assert_failed(self.helper("make_payload", 'fake_chainload() { printf partial; return 1; }'))

    def test_payload_chmod_failure_is_not_masked_by_checksums(self):
        self.assert_failed(self.helper("make_payload", 'chmod() { command chmod "$@"; return 1; }'))

    def test_fake_chainloader_missing_embedded_source_fails(self):
        (self.repo / "chainload/c5-chainload.sh").unlink()
        self.assert_failed(self.helper("fake_chainload"))

    def test_ui_directory_failure_is_not_masked_by_final_checksums(self):
        self.assert_failed(self.helper("make_ui_payload",
            'mkdir() { command mkdir "$@" || return; '
            'case "${!#}" in */qemu) return 1;; esac; }'))

    def test_ui_executable_install_failure_is_not_masked_by_final_checksums(self):
        self.assert_failed(self.helper("make_ui_payload",
            'install() { command install "$@" || return; '
            'case "${!#}" in */fake-ui.sh) return 1;; esac; }'))

    def test_ui_configuration_write_failure_is_not_masked_by_final_checksums(self):
        self.assert_failed(self.helper("make_ui_payload",
            'mkdir() { command mkdir "$@" || return; '
            'case "${!#}" in */qemu) command mkdir "${!#}/ui.conf";; esac; }'))

    def test_ui_hook_install_failure_is_not_masked_by_final_checksums(self):
        self.assert_failed(self.helper("make_ui_payload",
            'install() { command install "$@" || return; '
            'case "${!#}" in */runFirmwareExe.sh) return 1;; esac; }'))

    def test_missing_checksum_manifest_is_an_error(self):
        self.out.mkdir()
        self.assert_failed(self.helper("resum"))

    def test_resum_updates_actual_file_hashes(self):
        self.out.mkdir()
        self.put(self.out / "file", "changed payload\n")
        self.put(self.out / "SHA256SUMS", "stale  file\n")
        self.put(self.out / "MD5SUMS", "stale  file\n")
        self.must(self.helper("resum"))
        self.assert_checksums()

    def prepare_stick(self):
        for tool in ("sfdisk", "mkfs.vfat", "mcopy", "mtype"):
            if not shutil.which(tool):
                self.skipTest(f"requires {tool}")
        self.out.mkdir()
        self.put(self.out / "hello.txt", "real FAT32 payload\n")

    def test_stick_success_preserves_payload_on_real_fat32_image(self):
        self.prepare_stick()
        self.must(self.helper("make_stick"))
        result = self.must(self.command("mtype", "-i", str(self.root / "stick.img") + "@@1M",
                                        "::hello.txt"))
        self.assertEqual(result.stdout, "real FAT32 payload\n")

    def test_stick_cleanup_failure_is_not_masked_by_successful_copy(self):
        self.prepare_stick()
        self.assert_failed(self.helper("make_stick",
            'rm() { command rm "$@" || return; return 1; }'))

    def test_stick_truncate_failure_is_not_masked_by_successful_copy(self):
        self.prepare_stick()
        self.assert_failed(self.helper("make_stick",
            'truncate() { command truncate "$@" || return; return 1; }'))

    def test_stick_partition_failure_is_not_masked_by_successful_copy(self):
        self.prepare_stick()
        # Report an error after writing the real partition table: subsequent
        # formatting/copy can succeed, but must not erase the reported failure.
        self.assert_failed(self.helper("make_stick",
            'sfdisk() { command sfdisk "$@" || return; return 1; }'))

    def test_stick_format_failure_is_not_masked_by_successful_copy(self):
        self.prepare_stick()
        self.assert_failed(self.helper("make_stick",
            'mkfs.vfat() { command mkfs.vfat "$@" || return; return 1; }'))

    def test_stick_copy_failure_is_reported(self):
        self.prepare_stick()
        self.assert_failed(self.helper("make_stick",
            'mcopy() { command mcopy "$@" || return; return 1; }'))

    def test_install_flow_records_stick_failure_and_never_reaches_boot(self):
        self.prepare_stick()
        result = self.helper("flow_install", '\n'.join([
            f"source {shlex.quote(str(REPO / 'test/qemu/lib/scenarios.sh'))}",
            "DISK=unused FAILS=0",
            # Boot is the external hardware-emulation boundary; no VM should
            # start after assembly failed. All payload/stick work stays real.
            'boot() { touch "$RUN/boot-called"; }',
            "spl_root() { printf /dev/test; }",
            'mkfs.vfat() { command mkfs.vfat "$@" || return; return 1; }',
            """trap 'printf "fails=%s\\n" "$FAILS"' EXIT""",
        ]))
        self.assert_failed(result)
        self.assertIn("fails=1", result.stdout)
        self.assertFalse((self.run_dir / "boot-called").exists())


if __name__ == "__main__":
    unittest.main()
