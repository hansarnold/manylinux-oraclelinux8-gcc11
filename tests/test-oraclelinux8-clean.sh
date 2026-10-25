#!/bin/bash
# Run the repaired Oracle build artifacts in a clean EL8 userspace.
set -euo pipefail

IMAGE=${1:-manylinux_2_28_oraclelinux8_gcc11_x86_64:local}
CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}
CLEAN_IMAGE=${ORACLELINUX_CLEAN_IMAGE:-docker.io/library/almalinux:8}

# Keep exported artifacts in the invoking workdir, with no stale wheels from a
# previous run. The image test writes logs and binaries into this directory.
mkdir -p output/oraclelinux8-gcc11-clean
OUTPUT_ROOT=$(cd output/oraclelinux8-gcc11-clean && pwd)
ARTIFACTS=$(mktemp -d "${OUTPUT_ROOT}/run.XXXXXXXX")
echo "Clean-container test artifacts: ${ARTIFACTS}"

"${CONTAINER_ENGINE}" run --rm --platform linux/amd64 \
	-v "${ARTIFACTS}:/artifacts:Z" \
	-e ORACLELINUX_TEST_OUTPUT=/artifacts \
	"${IMAGE}" /opt/_internal/tests/oraclelinux8-gcc11.sh

# Variables in the command body must expand inside the clean container.
# shellcheck disable=SC2016
"${CONTAINER_ENGINE}" run --rm --platform linux/amd64 \
	-v "${ARTIFACTS}:/artifacts:ro,Z" \
	"${CLEAN_IMAGE}" /bin/bash -euxo pipefail -c '
	source /etc/os-release
	case "${ID}" in almalinux|rocky) ;; *) exit 1;; esac
	test "${VERSION_ID%%.*}" = 8
	# Use the target distribution Python and libstdc++, without a toolset.
	dnf -y install python39 python39-pip libstdc++
	# A venv also keeps isolated Python (-I) independent of the patched EL8
	# system /usr/local site-packages handling.
	python3.9 -m venv /tmp/oracle-wheel-venv
	PYTHON=/tmp/oracle-wheel-venv/bin/python
	"${PYTHON}" -m pip install --disable-pip-version-check --upgrade pip==25.3
	if rpm -qa | grep -E "^(gcc-toolset-|devtoolset-)"; then
		echo "Clean runtime unexpectedly contains a compiler toolset" >&2
		exit 1
	fi
	test ! -d /opt/rh/gcc-toolset-11
	test "$(getconf GNU_LIBC_VERSION)" = "glibc 2.28"
	rpm -q libstdc++ glibc python39
	unset LD_LIBRARY_PATH PYTHONPATH
	/artifacts/programs/c-smoke
	/artifacts/programs/cxx-smoke
	"${PYTHON}" -m pip install --no-index --no-deps /artifacts/wheelhouse/*-cp39-cp39-manylinux_2_28_x86_64.whl
	"${PYTHON}" -I -c "import oraclelinux_cpp_smoke; assert oraclelinux_cpp_smoke.answer() == 42"
	"${PYTHON}" -I -c "import ctypes; lib = ctypes.CDLL(\"/artifacts/programs/liboraclelinux_smoke.so\"); assert lib.oraclelinux_answer() == 42"
	'

echo "Clean EL8 runtime test passed (${CLEAN_IMAGE})"
