"""Exercise build selection without a Docker daemon or registry writes."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class BuildVariantTests(unittest.TestCase):
    def setUp(self):
        (ROOT / "tmp").mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "tmp")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.log = self.work / "calls.jsonl"
        docker = self.work / "docker"
        docker.write_text(
            "#!/usr/bin/env python3\n"
            "import json, os, pathlib, sys\n"
            "with open(os.environ['CALL_LOG'], 'a') as stream:\n"
            "    stream.write(json.dumps({'args': sys.argv[1:], 'env': dict(os.environ)}) + '\\n')\n"
            "for arg in sys.argv:\n"
            "    if arg.startswith('--cache-to=type=local,dest='):\n"
            "        pathlib.Path(arg.split('dest=', 1)[1].split(',')[0]).mkdir()\n"
        )
        docker.chmod(0o755)
        self.env = {
            "PATH": f"{self.work}:{os.environ['PATH']}",
            "CALL_LOG": str(self.log),
            "POLICY": "manylinux_2_28",
            "PLATFORM": "x86_64",
            "MANYLINUX_BUILD_FRONTEND": "docker",
            "MANYLINUX_BUILDARCH": "amd64",
            "COMMIT_SHA": "test",
        }

    def run_build(self, **updates):
        return subprocess.run(
            ["bash", str(ROOT / "build.sh")],
            cwd=self.work,
            env={**self.env, **updates},
            capture_output=True,
            text=True,
            check=False,
        )

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def test_oracle_configuration_and_tests(self):
        for platform, goarch in (("x86_64", "amd64"), ("aarch64", "arm64")):
            with self.subTest(platform=platform):
                self.log.unlink(missing_ok=True)
                result = self.run_build(
                    MANYLINUX_VARIANT="oraclelinux8-gcc11",
                    PLATFORM=platform,
                    MANYLINUX_BUILDARCH=goarch,
                )
                assert result.returncode == 0, result.stderr
                build, test = self.calls()
                assert build["env"]["BASEIMAGE"] == "docker.io/library/oraclelinux:8"
                root = "/opt/rh/gcc-toolset-11/root"
                assert build["env"]["DEVTOOLSET_ROOTPATH"] == root
                assert build["env"]["PREPEND_PATH"] == f"{root}/usr/bin:"
                assert f"{root}/usr/lib64" in build["env"]["LD_LIBRARY_PATH_ARG"]
                image = f"manylinux_2_28_oraclelinux8_gcc11_{platform}:test"
                assert image in build["args"]
                assert image in test["args"]
                assert f"--platform=linux/{goarch}" in build["args"]
                assert f"--platform=linux/{goarch}" in test["args"]
                assert test["args"][-1] == "/opt/_internal/tests/run_tests.sh"

    def test_upstream_default_is_unchanged(self):
        result = self.run_build()
        assert result.returncode == 0, result.stderr
        build = self.calls()[0]
        assert build["env"]["BASEIMAGE"] == "quay.io/almalinuxorg/almalinux:8"
        assert build["env"]["DEVTOOLSET_ROOTPATH"] == "/opt/rh/gcc-toolset-14/root"
        assert "quay.io/pypa/manylinux_2_28_x86_64:test" in build["args"]

    def test_unsupported_combinations_fail_before_docker(self):
        for overrides in (
            {"MANYLINUX_VARIANT": "typo"},
            {"MANYLINUX_VARIANT": "oraclelinux8-gcc11", "PLATFORM": "ppc64le"},
            {"MANYLINUX_VARIANT": "oraclelinux8-gcc11", "POLICY": "manylinux_2_34"},
        ):
            with self.subTest(overrides=overrides):
                assert self.run_build(**overrides).returncode != 0
                assert not self.log.exists()

    def test_custom_image_and_cache_never_publish_to_upstream(self):
        result = self.run_build(
            MANYLINUX_VARIANT="oraclelinux8-gcc11",
            MANYLINUX_IMAGE="example.invalid/fork/image:check",
            MANYLINUX_BUILD_FRONTEND="docker-buildx",
            GITHUB_REPOSITORY="pypa/manylinux",
            GITHUB_EVENT_NAME="push",
            GITHUB_REF="refs/heads/main",
        )
        assert result.returncode == 0, result.stderr
        build, test = self.calls()
        assert "example.invalid/fork/image:check" in build["args"]
        assert "example.invalid/fork/image:check" in test["args"]
        assert "pypa" not in " ".join(build["args"])
        assert "--push" not in build["args"]
        assert "oraclelinux8_gcc11" in " ".join(build["args"])

    def test_upstream_deploy_rejects_variant(self):
        for script in ("deploy.sh", "deploy_multiarch.sh"):
            with self.subTest(script=script):
                result = subprocess.run(
                    ["bash", str(ROOT / script), "--dry-run"],
                    cwd=self.work,
                    env={**self.env, "MANYLINUX_VARIANT": "oraclelinux8-gcc11"},
                    capture_output=True,
                    check=False,
                )
                assert result.returncode != 0
                assert not self.log.exists()


if __name__ == "__main__":
    unittest.main()
