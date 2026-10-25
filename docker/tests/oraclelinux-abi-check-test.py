"""Exercise the ABI checker with real linked ELF files, including bad inputs.

Run with auditwheel's Python on x86_64 or aarch64 Linux. The fixtures never execute: small
versioned provider libraries let us test an ABI newer than the build host.
"""

import platform
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

CHECKER = Path(__file__).with_name("oraclelinux-abi-check.py")
ARCH = platform.machine()


@unittest.skipUnless(
    sys.platform == "linux" and ARCH in {"x86_64", "aarch64"},
    "requires x86_64 or aarch64 Linux",
)
class AbiCheckerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)

    def fixture(self, version="GLIBC_2.28", soname="libc.so.6", rpath=None):
        provider = self.work / "provider.c"
        provider.write_text("int abi_probe(void) { return 42; }\n")
        consumer = self.work / "consumer.c"
        consumer.write_text(
            "extern int abi_probe(void);\nint answer(void) { return abi_probe(); }\n"
        )
        version_script = self.work / "versions.map"
        version_script.write_text(f"{version} {{ global: abi_probe; local: *; }};\n")
        library = self.work / "libfixture.so"
        subprocess.run(
            [
                "gcc",
                "-shared",
                "-fPIC",
                "-nostdlib",
                str(provider),
                f"-Wl,--version-script={version_script}",
                f"-Wl,-soname,{soname}",
                "-o",
                str(library),
            ],
            check=True,
        )
        binary = self.work / "consumer.so"
        command = ["gcc", "-shared", "-fPIC", "-nostdlib", str(consumer), str(library)]
        if rpath:
            command.append(f"-Wl,-rpath,{rpath}")
        subprocess.run([*command, "-o", str(binary)], check=True)
        return binary

    def check(self, binary):
        return subprocess.run(
            [sys.executable, str(CHECKER), "--arch", ARCH, str(binary)],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_accepts_baseline_version(self):
        result = self.check(self.fixture())
        assert result.returncode == 0, result.stderr
        assert "GLIBC_2.28" in result.stdout

    def test_rejects_new_symbol_versions(self):
        for version in ("GLIBC_2.29", "GLIBCXX_3.4.25", "CXXABI_1.3.99"):
            with self.subTest(version=version):
                result = self.check(self.fixture(version=version))
                assert result.returncode != 0
                assert "symbols outside manylinux_2_28" in result.stderr
                assert version in result.stderr

    def test_rejects_vendor_dependency(self):
        result = self.check(self.fixture(soname="liboracle_smoke.so"))
        assert result.returncode != 0
        assert "unexpected runtime dependencies" in result.stderr
        assert "liboracle_smoke.so" in result.stderr

    def test_rejects_toolset_search_path(self):
        result = self.check(self.fixture(rpath="/opt/rh/gcc-toolset-11/root/usr/lib64"))
        assert result.returncode != 0
        assert "unexpected embedded library search path" in result.stderr

    def test_rejects_wrong_architecture(self):
        binary = self.fixture()
        data = bytearray(binary.read_bytes())
        # Corrupt ELF e_machine to the other supported architecture.
        wrong_machine = 183 if ARCH == "x86_64" else 62
        data[18:20] = wrong_machine.to_bytes(2, "little")
        binary.write_bytes(data)
        result = self.check(binary)
        assert result.returncode != 0
        assert f"expected an {ARCH} ELF" in result.stderr


if __name__ == "__main__":
    unittest.main()
