#!/usr/bin/env python3
"""Exercise the installer's real backup loop on files using POSIX sh, not disks."""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
INSTALLER = REPO / "installer/opencreator-os/install.sh"
LIBRARY = REPO / "installer/opencreator-os/lib.sh"
MIB = 1024 * 1024


def shell_function(source, name):
    lines = source.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(name + "()"))
    if lines[start].endswith(" }"):
        return lines[start]
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
    return "\n".join(lines[start:end + 1])


@unittest.skipUnless(os.name == "posix", "requires POSIX sh and process groups (run in WSL)")
class InstallerBackupTest(unittest.TestCase):
    def setUp(self):
        for tool in ("sh", "dd", "tee", "sha256sum", "md5sum", "mkfifo", "mktemp"):
            if not shutil.which(tool):
                self.skipTest(f"requires {tool}")
        self.temp = tempfile.TemporaryDirectory(prefix="c5-backup-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.stick = self.root / "stick"
        self.stick.mkdir()
        self.work = self.root / "tmp"
        self.work.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.partition = self.root / "userdata"
        self.data = bytes(range(256)) * (2 * MIB // 256) + b"last-sector".ljust(512, b"!")
        self.partition.write_bytes(self.data)
        self.disk = self.root / "disk"
        self.head = bytes(reversed(range(256))) * (MIB // 256)
        self.tail = b"unaligned-tail".ljust(7 * 512, b"+")
        self.disk.write_bytes(self.head + b"not-backed-up".ljust(3 * 512, b"-") + self.tail)
        self.pids = self.root / "children"
        self.dd_log = self.root / "source-reads"
        self.stage = self.root / "readback"
        self.backup = self.stick / "emmc-backup"
        source = INSTALLER.read_text()
        self.functions = source.split("# --- eMMC backup to the stick", 1)[1].split(
            "# --- c5os partition", 1)[0]
        library = LIBRARY.read_text()
        self.functions += "\n" + "\n".join(shell_function(library, name)
            for name in ("file_sum", "file_bytes", "sums_get"))
        self.make_wrapper("dd", '''
case " $* " in *" if=$TEST_PART "*|*" if=$TEST_DISK "*)
    printf '%s\\n' "$*" >> "$TEST_DD_LOG"
    case "${FAULT:-}" in
        dd-error) exit 7 ;;
        signal-copy) kill -TERM "$PPID" ;;
        dd-error-after-data) "$REAL_TOOL" "$@"; exit 7 ;;
    esac ;;
esac
exec "$REAL_TOOL" "$@"
''')
        self.make_wrapper("tee", '''
if [ "${FAULT:-}" = output-open-error ]; then
    for file do mkdir "$file" || exit; done
fi
[ "${FAULT:-}" != output-error ] || exit 7
"$REAL_TOOL" "$@" || exit $?
if [ "${FAULT:-}" = corrupt-output ]; then
    for file do printf X | dd of="$file" bs=1 count=1 conv=notrunc 2>/dev/null || exit; done
fi
''')
        for name in ("sha256sum", "md5sum"):
            self.make_wrapper(name, '''
case "${FAULT:-}" in
    hash-error) exit 7 ;;
    hash-error-after-data) "$REAL_TOOL" "$@"; exit 7 ;;
    readback-hash-error) if [ -f "$TEST_STAGE" ]; then "$REAL_TOOL" "$@"; exit 7; fi ;;
esac
exec "$REAL_TOOL" "$@"
''')
        self.make_wrapper("cat", '''
if [ "${FAULT:-}" = readback-read-error ] && [ -f "$TEST_STAGE" ]; then
    case " $* " in *".img."*|*first-mib.bin*) "$REAL_TOOL" "$@"; exit 7 ;; esac
fi
exec "$REAL_TOOL" "$@"
''')

    def make_wrapper(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" +
            f"REAL_TOOL={shlex.quote(shutil.which(name))}\n" +
            'echo "$$" >> "$TEST_PIDS"\n' + body)
        path.chmod(0o755)

    def run_backup(self, fault="", algorithm="sha256sum", injection="", shell=None):
        q = lambda path: shlex.quote(str(path))
        script = "\n".join([
            "set -u", self.functions,
            f"STICK={q(self.stick)}", f"BK={q(self.backup)}", "BK_DIR=emmc-backup",
            f"C5_DISK={q(self.disk)}", f"SUM={algorithm}",
            "SUMS=SHA256SUMS" if algorithm == "sha256sum" else "SUMS=MD5SUMS",
            "BK_CHUNK_MIB=1", "BK_TOTAL_MIB=5", "BK_NEED_MIB=7", "VERSION=test",
            "DISK_SECTORS=2058", "TAIL_START=2051", "PT='userdata 1 0 4097'",
            f"BK_LIST='first-mib {self.disk} 0 2048\nuserdata {self.partition} 0 4097\ndisk-tail {self.disk} 2051 7'",
            'fail() { printf "%s\\n" "$*" >&2; exit 1; }',
            "log() { :; }", "ui_info() { :; }", "ui_progress() { :; }",
            "ui_block() { exit 1; }", "free_bytes() { echo 1073741824; }",
            "c5_root_dev() { echo test-root; }", "c5_flag_read() { echo 2; }",
            'sync() { printf "sync\\n" >> "$TEST_ORDER"; }',
            'c5_drop_caches() { printf "drop\\n" >> "$TEST_ORDER"; : > "$TEST_STAGE"; }',
            injection, "backup_emmc",
        ])
        env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                   TMPDIR=str(self.work), TEST_PIDS=str(self.pids), TEST_PART=str(self.partition),
                   TEST_DISK=str(self.disk), TEST_DD_LOG=str(self.dd_log),
                   TEST_STAGE=str(self.stage), TEST_ORDER=str(self.root / "order"), FAULT=fault)
        process = subprocess.Popen((shell or ["sh"]) + ["-c", script], env=env, text=True,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=15)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            self.fail("backup hung (FIFO reader/writer not cleaned up)")
        result = subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        self.assertEqual(list(self.work.iterdir()), [], "temporary backup files/FIFOs leaked")
        if self.pids.exists():
            for pid in set(map(int, self.pids.read_text().splitlines())):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    continue
                self.fail(f"backup left child {pid} alive or unreaped")
        return result

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.backup / "VERIFIED").exists())

    def assert_backup(self, algorithm):
        digest = lambda data: hashlib.new(algorithm, data).hexdigest()
        sums_name = "SHA256SUMS" if algorithm == "sha256" else "MD5SUMS"
        sums = (self.backup / sums_name).read_text()
        self.assertEqual(sums, f"{digest(self.head)}  first-mib.bin\n"
                         f"{digest(self.data)}  userdata.img\n"
                         f"{digest(self.tail)}  disk-tail.img\n")
        self.assertEqual((self.backup / "first-mib.bin").read_bytes(), self.head)
        self.assertEqual((self.backup / "userdata.img.000").read_bytes(), self.data[:MIB])
        self.assertEqual((self.backup / "userdata.img.001").read_bytes(), self.data[MIB:2*MIB])
        self.assertEqual((self.backup / "userdata.img.002").read_bytes(), self.data[2*MIB:])
        self.assertEqual((self.backup / "disk-tail.img.000").read_bytes(), self.tail)
        self.assertEqual((self.backup / "VERIFIED").read_text().strip(), digest(sums.encode()))
        self.assertEqual((self.backup / "partmap.txt").read_text(), "userdata 1 0 4097\n")
        self.assertIn("tail: start=2051 sectors=7", (self.backup / "MANIFEST.txt").read_text())
        self.assertEqual((self.root / "order").read_text(), "sync\ndrop\nsync\n")

    def test_multichunk_source_checksums_and_first_mib_and_unaligned_tail(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_backup("sha256")
        # A full-device hash pass via disk_range/dd would add a sixth source read.
        self.assertEqual(len(self.dd_log.read_text().splitlines()), 5)

    def test_md5_fallback_keeps_backup_format(self):
        result = self.run_backup(algorithm="md5sum")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_backup("md5")

    def test_busybox_sh_uses_the_same_portable_stream(self):
        busybox = shutil.which("busybox")
        if not busybox:
            self.skipTest("requires busybox")
        result = self.run_backup(shell=[busybox, "sh"])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_backup("sha256")

    def test_short_source_is_rejected(self):
        self.partition.write_bytes(self.data[:-512])
        self.assert_failed(self.run_backup())

    def test_source_read_error_is_not_hidden_by_tee_or_checksum(self):
        self.assert_failed(self.run_backup("dd-error"))

    def test_source_error_after_all_bytes_is_still_rejected(self):
        self.assert_failed(self.run_backup("dd-error-after-data"))

    def test_output_failure_exits_without_fifo_hang_or_orphan(self):
        self.assert_failed(self.run_backup("output-error"))

    def test_real_output_open_failure_is_rejected(self):
        self.assert_failed(self.run_backup("output-open-error"))

    def test_checksum_early_exit_exits_without_fifo_hang_or_orphan(self):
        self.assert_failed(self.run_backup("hash-error"))

    def test_checksum_error_with_correct_digest_is_rejected(self):
        self.assert_failed(self.run_backup("hash-error-after-data"))

    def test_checksum_is_of_original_stream_not_corrupted_destination(self):
        self.assert_failed(self.run_backup("corrupt-output"))
        sums = (self.backup / "SHA256SUMS").read_text()
        self.assertIn(hashlib.sha256(self.head).hexdigest() + "  first-mib.bin\n", sums)
        self.assertNotEqual((self.backup / "first-mib.bin").read_bytes(), self.head)

    def test_readback_checksum_failure_is_not_hidden_by_cut(self):
        self.assert_failed(self.run_backup("readback-hash-error"))

    def test_readback_read_error_is_not_hidden_by_checksum(self):
        self.assert_failed(self.run_backup("readback-read-error"))

    def test_fifo_creation_failure_cleans_temporary_directory(self):
        self.assert_failed(self.run_backup(injection="mkfifo() { return 7; }"))

    def test_interrupted_copy_cleans_fifo_and_children(self):
        self.assert_failed(self.run_backup("signal-copy"))

    def test_verified_backup_does_not_copy_source_again(self):
        self.assertEqual(self.run_backup().returncode, 0)
        reads = self.dd_log.read_text()
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.dd_log.read_text(), reads)
        self.assert_backup("sha256")

    def test_cached_marker_does_not_hide_checksum_process_failure(self):
        self.assertEqual(self.run_backup().returncode, 0)
        self.assert_failed(self.run_backup("hash-error-after-data"))


if __name__ == "__main__":
    unittest.main()
