# Oracle Linux 8 with GCC 11.5

This fork adds `MANYLINUX_VARIANT=oraclelinux8-gcc11` to the upstream build
workflow. It supports **`POLICY=manylinux_2_28` with `PLATFORM=x86_64` or
`PLATFORM=aarch64`** and uses the official `oraclelinux:8` image.
Leaving `MANYLINUX_VARIANT` unset
preserves the upstream image selection.
The build uses its fully qualified name `docker.io/library/oraclelinux:8`
so Podman's short-name aliases cannot select a different registry.

The Docker image name distinguishes this fork's toolchain. Wheel tags remain
`manylinux_2_28_x86_64` and `manylinux_2_28_aarch64`: Oracle Linux is not a new
wheel policy. Under
[PEP 600](https://peps.python.org/pep-0600/), compatibility is a promise about
the resulting wheel's runtime requirements. Building on EL8 is necessary for
this configuration, but each wheel still needs ABI inspection and repair.

## Build locally

Run from the repository root with a working Docker daemon and Buildx:

```bash
POLICY=manylinux_2_28 PLATFORM=x86_64 \
MANYLINUX_VARIANT=oraclelinux8-gcc11 COMMIT_SHA=local \
./build.sh
```

For ARM64, use the same workflow with `PLATFORM=aarch64`:

```bash
POLICY=manylinux_2_28 PLATFORM=aarch64 \
MANYLINUX_VARIANT=oraclelinux8-gcc11 COMMIT_SHA=local \
./build.sh
```

| `PLATFORM` | Container platform | Local image |
| --- | --- | --- |
| `x86_64` | `linux/amd64` | `manylinux_2_28_oraclelinux8_gcc11_x86_64:local` |
| `aarch64` | `linux/arm64` | `manylinux_2_28_oraclelinux8_gcc11_aarch64:local` |

`build.sh` builds the existing
multi-stage `docker/Dockerfile` and runs the complete upstream
`docker/tests/run_tests.sh`, including the additional Oracle checks. It does
not push an image. Set `MANYLINUX_IMAGE` to choose another full image name/tag.
Use `MANYLINUX_BUILD_FRONTEND=docker` or `podman` to select the existing
alternative frontends.

For native Podman builds, set `MANYLINUX_BUILDARCH=amd64` on x86_64 or
`MANYLINUX_BUILDARCH=arm64` on ARM64; some Podman versions do not support
upstream's Docker-style architecture detection. For example:

```bash
POLICY=manylinux_2_28 PLATFORM=x86_64 \
MANYLINUX_VARIANT=oraclelinux8-gcc11 COMMIT_SHA=local \
MANYLINUX_BUILD_FRONTEND=podman MANYLINUX_BUILDARCH=amd64 ./build.sh
```

If the default Buildx driver cannot export the build cache, select the Docker
frontend explicitly (or configure a Buildx builder with the
`docker-container` driver):

```bash
POLICY=manylinux_2_28 PLATFORM=x86_64 \
MANYLINUX_VARIANT=oraclelinux8-gcc11 COMMIT_SHA=local \
MANYLINUX_BUILD_FRONTEND=docker ./build.sh
```

A native Linux builder matching the target architecture is recommended for
the full interpreter build. Building for another architecture requires
working container emulation and substantially more time.
The image retains all upstream Python interpreters under `/opt/python`,
the interpreter installer, pip, build, auditwheel, CMake, patchelf, and the
other upstream development tools. No interpreter stages or upstream tests
are removed for this variant.

## Build and repair a wheel

For a Python project in the current directory:

```bash
mkdir -p output/wheels output/repaired
docker run --rm --platform linux/amd64 \
  -v "$PWD:/io" -w /io \
  manylinux_2_28_oraclelinux8_gcc11_x86_64:local \
  /bin/bash -euxo pipefail -c '
    /opt/python/cp312-cp312/bin/python -m build --wheel --outdir /io/output/wheels
    for wheel in /io/output/wheels/*.whl; do
      auditwheel show "$wheel"
      auditwheel repair --plat "${AUDITWHEEL_PLAT}" --only-plat \
        --wheel-dir /io/output/repaired "$wheel"
    done
  '
```

Choose the `/opt/python/<python tag>-<abi tag>` interpreter required by your
project. For ARM64, use `--platform linux/arm64` and the `aarch64` image;
`AUDITWHEEL_PLAT` selects that image's standard wheel tag. Keep each build's
output directory free of unrelated wheels.
`auditwheel repair` can bundle eligible non-policy libraries; it cannot make
an incompatible glibc or libstdc++ requirement compatible merely by changing
the filename. Do not force a tag onto a wheel that fails validation.

## Repositories and pinned toolchain

Only Oracle's official `ol8_baseos_latest`, `ol8_appstream`, and
`ol8_codeready_builder` repositories are needed. CodeReady Builder supplies
packages including `yasm` and `uuid-devel`; `ol8_developer_EPEL` is not needed.
AlmaLinux, CentOS, RHEL, and third-party GCC repositories are not added.
RPM signature checking remains enabled.

The pinned packages are published in Oracle AppStream for
[x86_64](https://yum.oracle.com/repo/OracleLinux/OL8/appstream/x86_64/) and
[aarch64](https://yum.oracle.com/repo/OracleLinux/OL8/appstream/aarch64/).
The initial selection was checked against these repositories, the
[CodeReady Builder index](https://yum.oracle.com/repo/OracleLinux/OL8/codeready/builder/x86_64/),
and [Oracle's GCC 11.5 errata](https://linux.oracle.com/errata/ELBA-2024-12848.html):

| Package family | Version-release |
| --- | --- |
| `gcc-toolset-11-gcc`, `gcc-c++`, `gcc-gfortran` | `11.5.0-2.0.1.el8_6` |
| `gcc-toolset-11-libstdc++-devel`, `libatomic-devel` | `11.5.0-2.0.1.el8_6` |
| `gcc-toolset-11-libquadmath-devel` (x86_64 only) | `11.5.0-2.0.1.el8_6` |
| `gcc-toolset-11-binutils` | `2.36.1-4.0.2.el8_6` |
| `gcc-toolset-11-runtime` | `11.1-1.el8` |

Names after the first entry in each grouped row share the `gcc-toolset-11-`
prefix. Both architectures use the same version-release pins. Oracle does
not provide `gcc-toolset-11-libquadmath-devel` for aarch64; the ARM64
configuration omits that x86_64 dependency. The toolset's `runtime` RPM
describes the software collection; its
`11.1` version does not indicate the installed compiler version. The selected
compiler must report exactly `11.5.0`; there is no fallback to GCC 11.2, GCC 14,
or the system GCC 8.

The toolchain root is `/opt/rh/gcc-toolset-11/root`. Its `usr/bin` is selected
through `PATH`, and its runtime search directories are included in
`LD_LIBRARY_PATH`, following upstream's toolset setup. The standard compiler
commands `gcc`, `g++`, and `gfortran` are available without running
`scl enable` or sourcing an interactive shell profile.

## libstdc++ and runtime compatibility

Oracle's GCC 11.5 toolchain supplies a text linker script, rather than a
new replacement shared libstdc++, at the compiler's `libstdc++.so` path.
The script belongs to `gcc-toolset-11-gcc-c++` on x86_64 and
`gcc-toolset-11-libstdc++-devel` on aarch64. On x86_64 it contains:

```text
OUTPUT_FORMAT(elf64-x86-64)
INPUT ( /usr/lib64/libstdc++.so.6 -lstdc++_nonshared )
```

The aarch64 script uses `OUTPUT_FORMAT(elf64-littleaarch64)` with the same
`INPUT` line.

The matching `gcc-toolset-11-libstdc++-devel` RPM supplies
`libstdc++_nonshared.a`. This links selected newer implementation code from
the archive while retaining the base system's `libstdc++.so.6` dependency.
The Oracle variant preserves this script and does not apply the upstream
GCC 14 linker-script rewrite. It does not globally enable
`-static-libstdc++`.

This mechanism is not a blanket ABI guarantee: the selected archive members
may introduce additional symbol requirements. The tests compile C++17
filesystem and exception code, inspect ELF dependencies and versioned
symbols, and build and repair a real extension wheel against the installed
auditwheel `manylinux_2_28` policy for the target architecture. The
clean-runtime test checks the result without `LD_LIBRARY_PATH` or a GCC
Toolset installation.

GFortran also uses a nonshared linker script with the base system's
`libgfortran.so.5`. Toolset development linker scripts for libatomic, and
libquadmath on x86_64, target the corresponding base system shared libraries.
Compiler runtimes outside auditwheel's allowlist must be bundled where
permitted. Downstream projects using Fortran, OpenMP, or other runtimes
must run auditwheel on their own wheels as well.

## Validation and CI

The Oracle checks are part of `run_tests.sh` and can also be run separately:

```bash
docker run --rm --platform linux/amd64 \
  manylinux_2_28_oraclelinux8_gcc11_x86_64:local \
  /opt/_internal/tests/oraclelinux8-gcc11.sh

./tests/test-oraclelinux8-clean.sh \
  manylinux_2_28_oraclelinux8_gcc11_x86_64:local
```

The second command exports fresh probe binaries, ELF inspection logs, and a
repaired CPython 3.9 C++ wheel into a unique directory under
`output/oraclelinux8-gcc11-clean/` in the current workdir. It then installs
the wheel into a fresh `almalinux:8` container using a virtual environment
created by the distribution's `python39`. It runs the C/C++ programs, loads
the shared library, and imports the extension with isolated Python (`-I`).
The runtime has no GCC Toolset packages. Its virtual environment uses pip
25.3 for PEP 600 support and isolates the installed wheel from the build
environment. Set `ORACLELINUX_CLEAN_IMAGE=docker.io/library/rockylinux:8`
to repeat with Rocky Linux, or `CONTAINER_ENGINE=podman` to use Podman for
this helper. The helper selects the target architecture from the local
image metadata; pass the `aarch64` image name to test ARM64.

An additional runtime check uses the corresponding official upstream
`quay.io/pypa/manylinux_2_28_<architecture>:latest` image:

```bash
./tests/test-oraclelinux8-upstream.sh \
  manylinux_2_28_oraclelinux8_gcc11_x86_64:local
```

This checks the repaired wheel and native probes with library-path overrides
removed, so the upstream image's own compiler toolset cannot mask a runtime
dependency.

The manual **Oracle Linux 8 GCC 11.5** GitHub Actions workflow invokes the
same build and clean-runtime tests on native `ubuntu-24.04` (x86_64) and
`ubuntu-24.04-arm` (aarch64) runners. It has no registry
login, push step, or package-write permission. Image publication is a
separate maintainer action and must use a registry namespace you control.
Enable the `test_upstream_runtime` dispatch input to include the optional
upstream-image runtime check for both architectures.
The upstream image-matrix and dependency-update jobs are gated to
`pypa/manylinux`; they do not run for this fork. Repository lint checks
remain available independently of the manual Oracle image build.

The upstream test suite still validates its entire supported interpreter
matrix, including optional interpreters installed by `ensure-all`. The
additional C++ wheel probe uses CPython 3.9 to match a clean EL8 distribution
interpreter. Symbol checks and ordinary execution do not prove every code
path is safe on every supported CPU. Retain the baseline compiler target
for each architecture, avoid `-march=native`, and test representative
downstream wheels on suitable baseline hardware when extending this
configuration.

The [validation record](oraclelinux8-gcc11-validation.md) records the
completed native x86_64 and aarch64 builds, full upstream suites, clean
AlmaLinux wheel tests, upstream runtime checks, and remaining validation limits.

## Maintenance

Keep the variant-specific changes separate from upstream policy definitions
and Python/tool dependency pins. Track `https://github.com/pypa/manylinux.git`
as an `upstream` remote and periodically merge `upstream/main` into the
fork's maintenance branch. Review changes to base-image selection,
repository setup, compiler installation, finalization, the GCC wrapper,
and the complete test pipeline before rerunning the build and validation
commands above.

Toolchain packages are selected at explicit version-release values and
locked across package upgrades. Changing a pin requires verifying Oracle
repository availability and signatures, package dependencies, the linker
scripts and nonshared archives, followed by the full build, upstream tests,
Oracle ABI tests, and clean EL8 runtime test. A removed pin or a changed
compiler version should fail the build rather than silently choose a
different toolchain.

The `oraclelinux:8` tag and Oracle repositories receive updates. Exact
toolchain pins do not make the whole image bit-for-bit reproducible: base
image digests, non-toolchain RPMs, interpreter downloads, and upstream
dependency revisions also matter. Record the Git commit, resolved base
image digest, build logs, and installed RPM manifest with each release.
The image stores its RPM manifest at
`/opt/_internal/oraclelinux8-rpm-manifest.txt`.
Review Oracle security errata regularly; a version lock deliberately means
a newer compiler RPM is adopted only after an explicit pin update and
compatibility validation. The glibc baseline remains 2.28 across EL8 security
updates.
