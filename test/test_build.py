#!/usr/bin/env python3
"""Exercise the build wrapper on temporary trees without downloading or compiling."""
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
TARGET = "CONFIG_TARGET_x2600_generic_DEVICE_flashforge_creator5pro=y\n"


class BuildConfigTest(unittest.TestCase):
    def setUp(self):
        for name in ("bash", "git", "tar", "sha256sum"):
            if not shutil.which(name):
                self.skipTest(f"requires {name}")
        self.temp = tempfile.TemporaryDirectory(prefix="c5-build-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.work = self.root / "work"
        self.ow = self.work / "openwrt"
        self.kernel = self.work / "kernel"
        self.bin = self.root / "bin"
        self.log = self.root / "make.log"
        self.put(self.repo / "build.sh", (REPO / "build.sh").read_text(), 0o755)
        self.put(self.repo / "config/openwrt.seed", TARGET)
        self.put(self.repo / "feed/x2600/Makefile", "BOARD:=x2600\n")
        self.put(self.repo / "feed/x2600/config-6.6", "CONFIG_KERNEL_TEST=y\n")
        self.put(self.kernel / "Makefile", "# prepared kernel\n")
        self.put(self.repo / "kernel/prepare.sh",
                 '#!/bin/sh\nprintf "%s\\n" "$C5_TEST_KERNEL"\n', 0o755)
        (self.ow / ".git").mkdir(parents=True)
        self.put(self.ow / ".c5-feeds-tag", "v24.10.8\n")
        self.put(self.ow / "feeds.conf.default", "src-git packages test-feed\n")
        self.feed = self.ow / "feeds/packages"
        self.put(self.feed / "Makefile", "# package metadata\n")
        self.git("init", "-q", str(self.feed))
        self.commit_feed()
        (self.ow / "package/feeds/packages").mkdir(parents=True)
        (self.ow / "package/feeds/packages/example").symlink_to(self.feed)
        self.put(self.ow / "scripts/feeds", "#!/bin/sh\nexit 0\n", 0o755)
        prefix = "bin/targets/x2600/generic/opencreator-os-x2600-generic-flashforge_creator5pro"
        self.put(self.ow / (prefix + "-kernel.uimage"), "test artifact\n")
        self.put(self.ow / "bin/targets/x2600/generic/sha256sums", "test sums\n")
        self.put(self.bin / "dpkg", "#!/bin/sh\nexit 0\n", 0o755)
        self.put(self.bin / "git", '\n'.join([
            "#!/bin/sh",
            'if [ "$1" = -C ] && [ "$2" = "$C5_TEST_REPO" ]; then',
            '    case "$3" in',
            '    describe) printf "%s\\n" "$C5_TEST_VERSION"; exit 0 ;;',
            '    ls-files) exit 0 ;;',
            '    esac',
            'elif [ "$1" = -C ] && [ "$2" = "$C5_TEST_OW" ] && [ "$3" = describe ]; then',
            '    cat "$C5_TEST_OW/.c5-feeds-tag"; exit 0',
            'fi',
            f"exec {shlex.quote(shutil.which('git'))} \"$@\"",
            "",
        ]), 0o755)
        self.put(self.bin / "make", '''#!/bin/bash
set -eu
printf '%s\\n' "$*" >> "$C5_TEST_MAKE_LOG"
case "$*" in
defconfig)
    [ ! -e "$C5_TEST_OW/fail-defconfig" ] || exit 1
    if [ -e "$C5_TEST_OW/wrong-target" ]; then
        printf 'CONFIG_WRONG_TARGET=y\\n' > .config
    else
        printf 'CONFIG_RESOLVED=y\\n' >> .config
    fi
    ;;
menuconfig)
    printf 'CONFIG_MENU_EDIT=y\\n' >> .config
    ;;
kernel_menuconfig)
    printf 'CONFIG_KERNEL_MENU_EDIT=y\\n' >> target/linux/x2600/config-6.6
    ;;
*world*)
    [ ! -e "$C5_TEST_KERNEL/.config.prev" ] || exit 1
    printf 'kernel config copied\\n' > "$C5_TEST_KERNEL/.config.prev"
    ;;
*) exit 1 ;;
esac
''', 0o755)
        self.env = dict(os.environ, WORK=str(self.work), OUT=str(self.root / "out"),
                        JOBS="2", PATH=str(self.bin) + ":" + os.environ["PATH"],
                        C5_TEST_REPO=str(self.repo), C5_TEST_OW=str(self.ow),
                        C5_TEST_KERNEL=str(self.kernel), C5_TEST_VERSION="test-version",
                        C5_TEST_MAKE_LOG=str(self.log))

    @staticmethod
    def put(path, content, mode=0o644):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(mode)

    def git(self, *args):
        result = subprocess.run(["git", *args], text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def commit_feed(self):
        self.git("-C", str(self.feed), "add", ".")
        self.git("-C", str(self.feed), "-c", "user.name=Build Test", "-c",
                 "user.email=build@example.invalid", "-c", "commit.gpgsign=false",
                 "commit", "-qm", "test feed state")

    def build(self, *args, success=True):
        result = subprocess.run(["bash", str(self.repo / "build.sh"), *args],
                                env=self.env, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def goals(self):
        return self.log.read_text().splitlines()

    def test_unchanged_build_reuses_config_and_runs_world_without_download(self):
        self.build()
        resolved = (self.ow / ".config").read_bytes()
        before = (self.ow / ".config").stat().st_mtime_ns
        self.build()
        self.assertEqual(self.goals(), ["defconfig", "-j2 world", "-j2 world"])
        self.assertEqual((self.ow / ".config").read_bytes(), resolved)
        self.assertEqual((self.ow / ".config").stat().st_mtime_ns, before)
        self.assertEqual((self.kernel / ".config.prev").read_text(), "kernel config copied\n")

    def test_each_configuration_input_change_reruns_defconfig(self):
        self.build()
        changes = [
            lambda: self.put(self.repo / "config/openwrt.seed", TARGET + "CONFIG_EXTRA=y\n"),
            lambda: self.env.update(C5_TEST_VERSION="next-version"),
            lambda: self.put(self.repo / "feed/x2600/new-config", "CONFIG_NEW=y\n"),
            lambda: self.put(self.ow / "feeds.conf.default", "src-git packages changed-feed\n"),
            lambda: self.put(self.feed / "Makefile", "# changed package metadata\n"),
            self.commit_feed,
            lambda: self.put(self.feed / "new-package/Makefile", "# new package metadata\n"),
            lambda: self.put(self.ow / "feeds/packages.index", "# refreshed feed index\n"),
            lambda: (self.ow / "package/feeds/packages/example").unlink(),
            lambda: self.env.update(C5_TEST_KERNEL=str(self.work / "other-kernel")),
        ]
        self.put(self.work / "other-kernel/Makefile", "# another prepared kernel\n")
        for change in changes:
            with self.subTest(change=changes.index(change)):
                before = self.goals().count("defconfig")
                change()
                self.build()
                self.assertEqual(self.goals().count("defconfig"), before + 1)
                self.build()
                self.assertEqual(self.goals().count("defconfig"), before + 1)

    def test_release_tag_change_reruns_defconfig(self):
        self.build()
        script = self.repo / "build.sh"
        script.write_text(script.read_text().replace("OPENWRT_TAG=v24.10.8", "OPENWRT_TAG=test-release"))
        self.put(self.ow / ".c5-feeds-tag", "test-release\n")
        self.build()
        self.assertEqual(self.goals().count("defconfig"), 2)

    def test_missing_or_edited_config_is_restored_from_seed(self):
        self.build()
        config = self.ow / ".config"
        config.unlink()
        self.build()
        self.assertIn(TARGET, config.read_text())
        self.put(config, TARGET + "CONFIG_MANUAL_EDIT=y\n")
        self.build()
        self.assertNotIn("CONFIG_MANUAL_EDIT", config.read_text())
        self.assertEqual(self.goals().count("defconfig"), 3)

    def test_interactive_flags_start_from_seed_and_do_not_persist_edits(self):
        self.build()
        for flag, goal, path, edit in (
                ("--menuconfig", "menuconfig", ".config", "CONFIG_MENU_EDIT=y"),
                ("--kernel-menuconfig", "kernel_menuconfig",
                 "target/linux/x2600/config-6.6", "CONFIG_KERNEL_MENU_EDIT=y")):
            with self.subTest(flag=flag):
                self.build(flag)
                self.assertEqual(self.goals()[-3:], ["defconfig", goal, "-j2 world"])
                self.assertIn(edit, (self.ow / path).read_text())
                self.build()
                self.assertNotIn(edit, (self.ow / path).read_text())

    def test_failed_defconfig_is_not_cached(self):
        self.put(self.ow / "fail-defconfig", "fail\n")
        self.build(success=False)
        (self.ow / "fail-defconfig").unlink()
        self.build()
        self.assertEqual(self.goals(), ["defconfig", "defconfig", "-j2 world"])

    def test_target_assertion_blocks_build_and_does_not_cache_bad_config(self):
        self.put(self.ow / "wrong-target", "wrong\n")
        result = self.build(success=False)
        self.assertIn("target not selected", result.stderr)
        (self.ow / "wrong-target").unlink()
        self.build()
        self.assertEqual(self.goals(), ["defconfig", "defconfig", "-j2 world"])


if __name__ == "__main__":
    unittest.main()
