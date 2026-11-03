#!/usr/bin/env python3
"""tools/ipk_closure.py against fake ipks."""
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
TOOL = REPO / "tools/ipk_closure.py"


def targz(files):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class IpkClosureTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ipk-closure-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.ipks = self.root / "bin"
        (self.ipks / "packages/base").mkdir(parents=True)
        self.manifest = self.root / "image.manifest"
        self.manifest.write_text("busybox - 1.36\nlibgcc1 - 13.3.0\nkmod-usb-core - 6.6\n")

    def ipk(self, name, depends="", provides="", sub="packages/base", mtime=None, tag=""):
        control = f"Package: {name}\nVersion: 1{tag}\nArchitecture: mipsel_mips32\n"
        if depends:
            control += f"Depends: {depends}\n"
        if provides:
            control += f"Provides: {provides}\n"
        data = targz({"./debian-binary": b"2.0\n",
                      "./control.tar.gz": targz({"./control": control.encode()}),
                      "./data.tar.gz": targz({})})
        path = self.ipks / sub / f"{name}_1{tag}_mipsel_mips32.ipk"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        if mtime is not None:
            os.utime(path, (mtime, mtime))
        return str(path)

    def run_tool(self, *roots):
        return subprocess.run([sys.executable, str(TOOL), str(self.manifest), str(self.ipks), *roots],
                              text=True, capture_output=True, timeout=30)

    def closure(self, *roots):
        result = self.run_tool(*roots)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_transitive_dependencies_without_the_image(self):
        a = self.ipk("python3", "libc, python3-base, libgcc1")
        b = self.ipk("python3-base", "libpython3-3.11")
        c = self.ipk("libpython3-3.11", "busybox")
        self.ipk("unrelated")
        self.assertEqual(self.closure("python3"), sorted([a, b, c]))

    def test_version_constraints_and_alternatives(self):
        a = self.ipk("nginx-ssl", "libpcre2 (>= 10.42), libopenssl3 | libmbedtls, zlib (=1.3)")
        deps = [self.ipk("libpcre2"), self.ipk("libopenssl3"), self.ipk("zlib")]
        self.ipk("libmbedtls")
        self.assertEqual(self.closure("nginx-ssl"), sorted([a] + deps))

    def test_provides_resolves_a_virtual_name(self):
        a = self.ipk("python3-pillow", "libjpeg")
        b = self.ipk("libjpeg-turbo", provides="libjpeg")
        self.assertEqual(self.closure("python3-pillow"), sorted([a, b]))

    def test_provides_satisfied_by_the_image(self):
        a = self.ipk("tool", "sh-provider")
        self.ipk("busybox", provides="sh-provider")
        self.assertEqual(self.closure("tool"), [a])

    def test_missing_dependency_fails(self):
        self.ipk("python3-numpy", "libopenblas")
        result = self.run_tool("python3-numpy")
        self.assertEqual(result.returncode, 1)
        self.assertIn("libopenblas (needed by python3-numpy) has no ipk under IPKDIR and is not in the image",
                      result.stderr)

    def test_kernel_module_outside_the_image_fails(self):
        self.ipk("python3-thing", "kmod-foo")
        self.ipk("kmod-foo")
        result = self.run_tool("python3-thing")
        self.assertEqual(result.returncode, 1)
        self.assertIn("needs kernel module kmod-foo", result.stderr)

    def test_kernel_module_in_the_image_is_fine(self):
        a = self.ipk("usbtool", "kmod-usb-core")
        self.assertEqual(self.closure("usbtool"), [a])

    def test_duplicate_package_takes_the_newest(self):
        old = self.ipk("libsodium", sub="packages/old", mtime=1_000_000, tag="-old")
        new = self.ipk("libsodium", sub="packages/new", mtime=2_000_000, tag="-new")
        result = self.run_tool("libsodium")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [new])
        self.assertIn(old, result.stderr)


if __name__ == "__main__":
    unittest.main()
