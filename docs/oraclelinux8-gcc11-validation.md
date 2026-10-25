# Oracle Linux 8 / GCC 11.5 validation — 2026-10-25

This record covers the initial Oracle variant implementation on upstream
manylinux commit
[`c6afd89b132ea698ee88ce8f0bb6a13a6c5761c4`](https://github.com/pypa/manylinux/commit/c6afd89b132ea698ee88ce8f0bb6a13a6c5761c4).
The complete image was built and tested on native x86_64 Linux using
Podman 5.8.9. The [build and maintenance guide](oraclelinux8-gcc11.md)
documents the commands and pinned Oracle RPM versions.

## Results

The resulting image uses Oracle Linux 8, glibc 2.28, and GCC/G++/GFortran
11.5.0. Its toolchain paths and `manylinux_2_28_x86_64` policy environment
were verified.

| Check | Result |
| --- | --- |
| Repository pre-commit checks, including ShellCheck, Ruff, and zizmor | Passed |
| Host build-selection and publishing-guard tests | 5 passed |
| ELF checker tests using compiled accepted/rejected fixtures | 5 passed |
| Compiler origin, exact version, and default `x86-64` target | Passed |
| C program, C++17 filesystem/exception program, and C++ shared library | Passed |
| Partial static linking of libstdc++ | Linker map confirmed nonshared archive members; dynamic dependency resolved to the base system libstdc++ |
| Native probe ELF dependencies and symbol versions | Passed; maximum requirements were GLIBC 2.17, GLIBCXX 3.4.21, and CXXABI 1.3.9 |
| Real CPython 3.9 C++ extension wheel | `auditwheel show`, repair for `manylinux_2_28_x86_64`, installation, and import passed |
| Clean AlmaLinux 8 runtime | C/C++ programs, shared-library loading, and repaired wheel installation and isolated import passed without GCC Toolset or library-path overrides |
| Complete upstream `docker/tests/run_tests.sh` | Exit 0: Oracle checks, all 17 interpreter configurations, development tools, and Clang helper tests; no exclusions or interpreter-count overrides |
| Manual GitHub Actions workflow | Linted; not dispatched |

The clean-runtime test used the official AlmaLinux 8.10 image with these
distribution packages:

| Package | Version-release |
| --- | --- |
| `glibc` | `2.28-251.el8_10.40` |
| `libstdc++` | `8.5.0-29.el8_10.alma.1` |
| `python39` | `3.9.25-2.module_el8.10.0+4083+53cad1fb` |

The wheel was installed in a virtual environment created by the
distribution's Python 3.9 and imported with `-I`. Source checksums, RPM
signature checks, and ABI validation remained enabled throughout testing.

## Scope and limitations

Only x86_64 is supported. Default compiler targets and ELF requirements were
checked, but no physical baseline-era x86_64 CPU was used. The C++ extension
probe covers CPython 3.9; upstream's extension-wheel tests cover all 17
interpreter configurations. Actual downstream wheels still require their
own auditwheel validation and runtime tests.

The mutable base-image tag and non-toolchain dependencies mean this build
is not bit-for-bit reproducible. Repeat validation when updating the
toolchain, dependencies, or upstream revision. No container image was
published as part of this validation.
