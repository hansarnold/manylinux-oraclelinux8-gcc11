#!/bin/bash
# Additional ABI checks for the Oracle variant; also runnable independently.
set -exuo pipefail

MY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=/opt/rh/gcc-toolset-11/root
OUT=${ORACLELINUX_TEST_OUTPUT:-/tmp/oraclelinux8-abi}
mkdir -p "${OUT}/programs" "${OUT}/wheelhouse" "${OUT}/reports"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# shellcheck source=/dev/null
source /etc/os-release
test "${ID}" = ol
test "${VERSION_ID%%.*}" = 8
test "${MANYLINUX_VARIANT}" = oraclelinux8-gcc11
test "${AUDITWHEEL_POLICY}" = manylinux_2_28
ARCH=${AUDITWHEEL_ARCH}
case "${ARCH}" in
	x86_64) EXPECTED_MARCH=x86-64;;
	aarch64) EXPECTED_MARCH=armv8-a;;
	*) echo "Unsupported Oracle test architecture: ${ARCH}" >&2; exit 1;;
esac
WHEEL_PLATFORM=manylinux_2_28_${ARCH}
test "${AUDITWHEEL_PLAT}" = "${WHEEL_PLATFORM}"
test "${DEVTOOLSET_ROOTPATH}" = "${ROOT}"
test "$(getconf GNU_LIBC_VERSION)" = 'glibc 2.28'
ldd --version | tee "${OUT}/reports/ldd-version.txt"
grep -E '^ldd .* 2\.28$' "${OUT}/reports/ldd-version.txt"

for COMPILER in gcc g++ gfortran; do
	"${COMPILER}" --version
	test "$("${COMPILER}" -dumpfullversion)" = 11.5.0
	case "$(readlink -f "$(command -v "${COMPILER}")")" in
		"${ROOT}"/usr/bin/*) ;;
		*) echo "${COMPILER} did not resolve to GCC Toolset 11"; exit 1;;
	esac
	# Test default code generation, without masking it with our own -march.
	TARGET_OPTIONS=$("${COMPILER}" -Q --help=target)
	test "$(awk '$1 == "-march=" {print $2}' <<< "${TARGET_OPTIONS}")" = "${EXPECTED_MARCH}"
	if [ "${ARCH}" == aarch64 ]; then
		test "$(awk '$1 == "-mcpu=" {print $2}' <<< "${TARGET_OPTIONS}")" = generic
		test "$(awk '$1 == "-mtune=" {print $2}' <<< "${TARGET_OPTIONS}")" = generic
	fi
done
if [ "${ARCH}" == aarch64 ]; then
	for COMPILER in gcc g++; do
		SOURCE_LANGUAGE=c
		if [ "${COMPILER}" == g++ ]; then SOURCE_LANGUAGE=c++; fi
		"${COMPILER}" -dM -E -x "${SOURCE_LANGUAGE}" /dev/null > "${OUT}/reports/${COMPILER}-macros.txt"
		if grep -E '^#define __ARM_FEATURE_(ATOMICS|SVE)' "${OUT}/reports/${COMPILER}-macros.txt"; then
			echo "Compiler enables instructions beyond the ARMv8-A baseline" >&2
			exit 1
		fi
	done
fi
for TOOL in ld as ar nm readelf objdump; do
	case "$(readlink -f "$(command -v "${TOOL}")")" in
		"${ROOT}"/usr/bin/*) ;;
		*) echo "${TOOL} did not resolve to GCC Toolset 11"; exit 1;;
	esac
done
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort > "${OUT}/reports/rpms.txt"

# Verify the actual vendor linker script and archive, then prove archive members
# were pulled into a real link. Do not inject -static-libstdc++ or rewrite it.
LINKER_SCRIPT=$(g++ -print-file-name=libstdc++.so)
NONSHARED=$(g++ -print-file-name=libstdc++_nonshared.a)
test -f "${LINKER_SCRIPT}"
test -f "${NONSHARED}"
grep -E 'INPUT.*(libstdc\+\+_nonshared\.a|-lstdc\+\+_nonshared)' "${LINKER_SCRIPT}"
cp "${LINKER_SCRIPT}" "${OUT}/reports/libstdc++.so.txt"
test -f "$(gcc -print-file-name=libatomic.so)"

CXX_FLAGS=(-std=c++17 -O2 -D_GLIBCXX_ASSERTIONS "-Wl,--as-needed")
gcc -O2 "${MY_DIR}/oraclelinux-cpp/smoke.c" -o "${OUT}/programs/c-smoke"
g++ "${CXX_FLAGS[@]}" "${MY_DIR}/oraclelinux-cpp/probe.cpp" "${MY_DIR}/oraclelinux-cpp/main.cpp" -o "${OUT}/programs/cxx-smoke"
g++ "${CXX_FLAGS[@]}" -fPIC -shared "${MY_DIR}/oraclelinux-cpp/probe.cpp" \
	-Wl,-z,defs "-Wl,-Map,${OUT}/reports/shared-link.map" \
	-o "${OUT}/programs/liboraclelinux_smoke.so"
grep -m1 -E 'libstdc\+\+_nonshared\.a\(' "${OUT}/reports/shared-link.map"
env -u LD_LIBRARY_PATH "${OUT}/programs/c-smoke"
env -u LD_LIBRARY_PATH "${OUT}/programs/cxx-smoke"
# Both normal and clean search paths must resolve the base-system libstdc++.
for SEARCH_PATH in "${LD_LIBRARY_PATH}" ''; do
	LD_LIBRARY_PATH=${SEARCH_PATH} ldd "${OUT}/programs/cxx-smoke" > "${OUT}/reports/cxx-ldd.txt"
	cat "${OUT}/reports/cxx-ldd.txt"
	LIBSTDCXX=$(awk '$1 == "libstdc++.so.6" {print $3}' "${OUT}/reports/cxx-ldd.txt")
	test "$(readlink -f "${LIBSTDCXX}")" = "$(readlink -f /usr/lib64/libstdc++.so.6)"
	test "$(rpm -qf --qf '%{NAME}' "$(readlink -f "${LIBSTDCXX}")")" = libstdc++
done

# Use the oldest installed CPython, also available in a clean EL8 container.
# The upstream run_tests.sh still tests every supported interpreter separately.
PYTHON=/opt/python/cp39-cp39/bin/python
test -x "${PYTHON}"
cp -r "${MY_DIR}/oraclelinux-cpp" "${WORK}/source"
CC=gcc CXX=g++ "${PYTHON}" -m build --wheel --outdir "${WORK}/dist" "${WORK}/source"
WHEEL=${WORK}/dist/oraclelinux_cpp_smoke-0.1.0-cp39-cp39-linux_${ARCH}.whl
test -f "${WHEEL}"
auditwheel show "${WHEEL}" | tee "${OUT}/reports/auditwheel-before.txt"
auditwheel repair --plat "${WHEEL_PLATFORM}" --only-plat -w "${WORK}/repaired" "${WHEEL}"
REPAIRED=${WORK}/repaired/oraclelinux_cpp_smoke-0.1.0-cp39-cp39-${WHEEL_PLATFORM}.whl
test -f "${REPAIRED}"
auditwheel show "${REPAIRED}" | tee "${OUT}/reports/auditwheel-after.txt"
"${PYTHON}" -m zipfile -e "${REPAIRED}" "${WORK}/unpacked"

# Resolve pipx's auditwheel environment so the policy and pyelftools are exactly
# the versions already installed by upstream; do not add a separate policy copy.
AUDITWHEEL_PYTHON=$(dirname "$(readlink -f "$(command -v auditwheel)")")/python
test -x "${AUDITWHEEL_PYTHON}"
"${AUDITWHEEL_PYTHON}" "${MY_DIR}/oraclelinux-abi-check-test.py"
mapfile -t EXTENSIONS < <(find "${WORK}/unpacked" -type f -name '*.so')
test "${#EXTENSIONS[@]}" -gt 0
ELFS=("${OUT}/programs/c-smoke" "${OUT}/programs/cxx-smoke" "${OUT}/programs/liboraclelinux_smoke.so" "${EXTENSIONS[@]}")
for ELF in "${ELFS[@]}"; do
	readelf -h -d -V -n "${ELF}"
	objdump -p -T "${ELF}"
done > "${OUT}/reports/elf.txt"
"${AUDITWHEEL_PYTHON}" "${MY_DIR}/oraclelinux-abi-check.py" --arch "${ARCH}" "${ELFS[@]}" | tee "${OUT}/reports/abi-policy.txt"

"${PYTHON}" -m venv "${WORK}/venv"
"${WORK}/venv/bin/python" -m pip install --no-index "${REPAIRED}"
env -u LD_LIBRARY_PATH -u PYTHONPATH "${WORK}/venv/bin/python" -c 'import oraclelinux_cpp_smoke; assert oraclelinux_cpp_smoke.answer() == 42'
cp "${REPAIRED}" "${OUT}/wheelhouse/"
echo "Oracle Linux GCC 11.5 ABI checks successful; artifacts: ${OUT}"
