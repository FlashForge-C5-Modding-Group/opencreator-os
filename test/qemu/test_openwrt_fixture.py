#!/usr/bin/env python3
"""Small real-squashfs regressions; run on Linux/WSL without root or QEMU boots."""
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
RUNNER = REPO / "test/qemu/run.sh"


def run(*args, **kwargs):
    return subprocess.run(args, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, **kwargs)


class OpenWrtFixtureTest(unittest.TestCase):
    def setUp(self):
        for tool in ("bash", "git", "mksquashfs", "unsquashfs"):
            if not shutil.which(tool):
                self.skipTest(f"requires {tool}")
        self.temp = tempfile.TemporaryDirectory(prefix="c5-fixture-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.feed = self.repo / "feed/x2600/base-files"
        self.feed.mkdir(parents=True)
        # Deliberately disagree with tracked executable modes, as on a Windows
        # checkout. The resulting image must recover Git modes, not lose crypto.
        self.files = {
            "etc/init.d/c5-usb-hook": ("#!/bin/sh\nexit 0\n", 0o755),
            "usr/libexec/c5-usb-hook": ("#!/bin/sh\nexit 0\n", 0o755),
            "usr/sbin/c5-check": ("#!/bin/sh\necho check\n", 0o755),
            "lib/c5/crypto.pem": ("test public key\n", 0o644),
        }
        for name, (content, mode) in self.files.items():
            self.put(self.feed / name, content, mode)
        self.must(run("git", "init", "-q", str(self.repo)))
        self.must(run("git", "-C", str(self.repo), "add", "."))
        (self.feed / "usr/sbin/c5-check").chmod(0o644)
        (self.feed / "lib/c5/crypto.pem").chmod(0o777)
        self.fix = self.root / "work/fixtures"
        self.fix.mkdir(parents=True)
        self.output = self.fix / "openwrt-root.squashfs"
        self.key = Path(str(self.output) + ".key")
        self.art = self.root / "artifact"
        self.source = Path(str(self.art) + "-root.squashfs")
        self.kernel = self.root / "vmlinux-test"
        modules = Path(str(self.kernel) + ".modules")
        modules.mkdir()
        self.put(modules / "usbnet.ko", "test module bytes\n")
        tree = self.root / "source"
        for name in ("dev", "etc/rc.d", "etc/init.d", "etc/uci-defaults", "lib/preinit"):
            (tree / name).mkdir(parents=True, exist_ok=True)
        self.put(tree / "sbin/procd", "#!/bin/sh\nexit 0\n", 0o755)
        self.put(tree / "lib/c5/obsolete", "old namespace\n")
        self.put(tree / "usr/sbin/c5-obsolete", "obsolete\n")
        self.put(tree / "etc/unrelated", "keep me\n")
        self.must(run("mksquashfs", str(tree), str(self.source), "-noappend",
                      "-all-root", "-quiet", "-processors", "1", "-p",
                      "/dev/console c 600 0 0 5 1"))

    @staticmethod
    def put(path, content, mode=0o644):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(mode)

    def must(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def build(self, injection="", refresh="1"):
        # No errexit: this is precisely how the real runner invokes the helper.
        script = '\n'.join([
            "set -uo pipefail",
            f"source {shlex.quote(str(HARNESS))}",
            f"QREPO={shlex.quote(str(self.repo))}",
            f"FIX={shlex.quote(str(self.fix))}",
            f"OWRT_ART={shlex.quote(str(self.art))}",
            f"OWRT_SQFS={shlex.quote(str(self.output))}",
            f"VMLINUX={shlex.quote(str(self.kernel))}",
            "KVER=test",
            f"QEMU_REFRESH_ROOTFS={refresh}",
            injection,
            "rc=0; build_openwrt_fixture || rc=$?; exit \"$rc\"",
        ])
        return run("bash", "-c", script, env=self.environment())

    def environment(self):
        return dict(os.environ, QWORK=str(self.root / "work"),
                    OWRT_BIN=str(self.root / "no-artifacts"))

    def assert_failed_without_publication(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotEqual(result.returncode, 77, "real failures must not be skips")
        self.assertFalse(self.output.exists(), "failed build published a fixture")
        self.assertFalse(self.key.exists(), "failed build published a success cache key")
        self.assertEqual(list(self.fix.glob("openwrt-build.*")), [],
                         "failed build leaked its temporary staging tree")

    def test_fresh_stage_ignores_inaccessible_old_stage_and_preserves_contents(self):
        if os.geteuid() == 0:
            self.skipTest("permission regression needs an ordinary user")
        stale = self.fix / "openwrt-stage"
        self.put(stale / "keep", "unrelated old staging data\n")
        stale.chmod(0)
        self.addCleanup(stale.chmod, 0o755)
        result = self.build()
        self.must(result)
        self.assertEqual(stat.S_IMODE(stale.stat().st_mode), 0)
        stale.chmod(0o755)
        self.assertEqual((stale / "keep").read_text(), "unrelated old staging data\n")
        self.assert_image()

    def assert_image(self):
        dest = self.root / "unpacked"
        self.must(run("unsquashfs", "-q", "-n", "-excludes", "-d", str(dest),
                      str(self.output), "dev/console"))
        for name, (content, mode) in self.files.items():
            file = dest / name
            self.assertEqual(file.read_text(), content)
            self.assertEqual(stat.S_IMODE(file.stat().st_mode), mode)
        self.assertEqual((dest / "lib/modules/test/usbnet.ko").read_text(),
                         "test module bytes\n")
        self.assertEqual((dest / "etc/unrelated").read_text(), "keep me\n")
        self.assertFalse((dest / "lib/c5/obsolete").exists())
        self.assertFalse((dest / "usr/sbin/c5-obsolete").exists())
        self.assertEqual(os.readlink(dest / "etc/rc.d/S19c5-usb-hook"),
                         "../init.d/c5-usb-hook")
        listing = self.must(run("unsquashfs", "-lln", str(self.output))).stdout
        self.assertRegex(listing, r"crw-------\s+0/0\s+5,\s*1\s+.*dev/console")

    def test_successful_refresh_has_readable_files_console_modes_and_cache_hit(self):
        self.must(self.build())
        self.assert_image()
        before = self.output.stat().st_mtime_ns
        self.must(self.build("unsquashfs() { return 91; }"))
        self.assertEqual(self.output.stat().st_mtime_ns, before)

    def test_extraction_failure_even_after_procd_exists_is_fatal(self):
        # Real extraction finishes, then the I/O boundary reports a nonfatal
        # extraction error (e.g. xattr/permission failure elsewhere in the tree).
        result = self.build('unsquashfs() { command unsquashfs "$@"; return 2; }')
        self.assert_failed_without_publication(result)

    def test_overlay_copy_failure_is_fatal(self):
        # A regular file in the artifact blocks a new overlay directory. This
        # reaches the real overlay mkdir/copy path after successful hashing.
        self.put(self.feed / "etc/unrelated/setting", "overlay setting\n")
        self.assert_failed_without_publication(self.build())

    def test_overlay_mode_restoration_failure_is_fatal(self):
        # Fail the chmod I/O boundary inside the real Git mode-restoration
        # pipeline; the ordinary copy and initial source chmod still run.
        self.assert_failed_without_publication(self.build(
            'chmod() { case "${!#}" in */etc/init.d/c5-usb-hook) return 1;; '
            'esac; command chmod "$@"; }'))

    def test_module_copy_failure_is_fatal(self):
        shutil.rmtree(Path(str(self.kernel) + ".modules"))
        self.assert_failed_without_publication(self.build())

    def test_packing_failure_never_publishes_partial_image_or_key(self):
        # Simulate disk-full after mksquashfs has opened and partially written
        # its output, while exercising all real extraction and overlay work.
        self.assert_failed_without_publication(self.build(
            'mksquashfs() { printf partial > "$2"; return 1; }'))

    def test_unreadable_packed_file_is_not_silently_replaced_with_empty_file(self):
        if os.geteuid() == 0:
            self.skipTest("unreadable file requires an ordinary user")
        # Inject the permission loss at the pack boundary, then use the actual
        # packer: without -exit-on-error it succeeds with an empty crypto file.
        self.assert_failed_without_publication(self.build(
            'mksquashfs() { chmod 000 "$1/lib/c5/crypto.pem"; '
            'command mksquashfs "$@"; }'))

    def test_failed_rebuild_preserves_previous_fixture_and_does_not_stamp_new_key(self):
        self.must(self.build())
        before = self.output.read_bytes()
        old_key = self.key.read_text()
        self.put(self.feed / "lib/c5/crypto.pem", "changed key\n")
        result = self.build('mksquashfs() { printf partial > "$2"; return 1; }')
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.output.read_bytes(), before)
        self.assertEqual(self.key.read_text(), old_key)

    def test_unwritable_fixture_directory_fails_actionably(self):
        if os.geteuid() == 0:
            self.skipTest("unwritable directory requires an ordinary user")
        self.fix.chmod(0o555)
        self.addCleanup(self.fix.chmod, 0o755)
        result = self.build()
        self.assert_failed_without_publication(result)
        self.assertIn(str(self.fix), result.stderr)
        self.assertRegex(result.stderr.lower(), r"writ|permission|qwork")

    def test_artifact_copy_and_missing_artifact_status(self):
        self.must(self.build(refresh="0"))
        self.assertEqual(self.output.read_bytes(), self.source.read_bytes())
        self.source.unlink()
        self.assertEqual(self.build().returncode, 77)

    def test_failed_artifact_copy_and_publication_have_no_partial_image(self):
        self.assert_failed_without_publication(self.build(
            'cp() { printf partial > "$2"; return 1; }', refresh="0"))

    def test_failed_image_publication_has_no_success_cache_key(self):
        self.assert_failed_without_publication(self.build('mv() { return 1; }'))

    def test_failed_key_publication_has_no_fixture_or_success_cache_key(self):
        self.assert_failed_without_publication(self.build(
            'mv() { case "${!#}" in *.key) return 1;; esac; command mv "$@"; }'))

    def runner(self):
        # Exercise the actual runner's status handling, replacing only unrelated
        # expensive kernel/disk setup. No QEMU scenario should run in either case.
        sandbox = self.root / "runner"
        (sandbox / "lib").mkdir(parents=True)
        shutil.copyfile(RUNNER, sandbox / "run.sh")
        self.put(sandbox / "kernel/build.sh", "#!/bin/sh\nexit 0\n", 0o755)
        for tool in ("sfdisk", "partx"):
            self.put(self.repo / f"installer/tools/out/{tool}", "#!/bin/sh\nexit 0\n", 0o755)
        self.put(sandbox / "lib/harness.sh", '\n'.join([
            f"source {shlex.quote(str(HARNESS))}",
            f"QDIR={shlex.quote(str(sandbox))}",
            f"QREPO={shlex.quote(str(self.repo))}",
            f"OWRT_ART={shlex.quote(str(self.art))}",
            f"VMLINUX={shlex.quote(str(self.kernel))}",
            "KVER=test",
            "build_stock_fixture() { return 0; }",
            "build_base_disk() { return 0; }",
            "remember_base() { return 0; }",
        ]) + '\n')
        self.put(sandbox / "lib/scenarios.sh", '\n'.join([
            "ALL_SCENARIOS=S1", "COMMITTED_BY=S1",
            f"scenario_S1() {{ touch {shlex.quote(str(self.root / 'scenario-ran'))}; }}",
        ]) + '\n')
        # Preflight-only host binaries need not be installed for these tests.
        bin_dir = sandbox / "bin"
        for tool in ("qemu-system-mipsel", "sgdisk", "sfdisk", "mkfs.ext4", "debugfs",
                     "mkfs.vfat", "mcopy", "mtype", "mdir", "flock"):
            self.put(bin_dir / tool, "#!/bin/sh\nexit 99\n", 0o755)
        env = self.environment()
        env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
        return run("bash", str(sandbox / "run.sh"), "-j", "1", "S1", env=env)

    def test_runner_missing_artifact_skips_without_booting(self):
        self.source.unlink()
        result = self.must(self.runner())
        self.assertIn("S1 SKIP", result.stdout)
        self.assertFalse((self.root / "scenario-ran").exists())

    def test_runner_real_fixture_failure_aborts_instead_of_skipping(self):
        self.source.write_text("not a squashfs\n")
        result = self.runner()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("SKIP", result.stdout)
        self.assertFalse((self.root / "scenario-ran").exists())
        self.assertFalse(self.key.exists())


if __name__ == "__main__":
    unittest.main()
