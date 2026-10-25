#!/bin/bash
# Verify Oracle-built artifacts in the original upstream manylinux environment.
set -euo pipefail

IMAGE=${1:-manylinux_2_28_oraclelinux8_gcc11_x86_64:local}
CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}
IMAGE_ARCH=$("${CONTAINER_ENGINE}" image inspect --format '{{.Architecture}}' "${IMAGE}")
case "${IMAGE_ARCH}" in
	amd64) ARCH=x86_64; CONTAINER_PLATFORM=linux/amd64;;
	arm64) ARCH=aarch64; CONTAINER_PLATFORM=linux/arm64;;
	*) echo "Unsupported Oracle image architecture: ${IMAGE_ARCH}" >&2; exit 1;;
esac
UPSTREAM_IMAGE=${ORACLELINUX_UPSTREAM_IMAGE:-quay.io/pypa/manylinux_2_28_${ARCH}:latest}

# Export a fresh, self-contained artifact set so separate runtime checks cannot
# accidentally consume a wheel or binary from another architecture or build.
mkdir -p output/oraclelinux8-gcc11-upstream
OUTPUT_ROOT=$(cd output/oraclelinux8-gcc11-upstream && pwd)
ARTIFACTS=$(mktemp -d "${OUTPUT_ROOT}/run.XXXXXXXX")
echo "Upstream-runtime test artifacts: ${ARTIFACTS}"

"${CONTAINER_ENGINE}" run --rm --platform "${CONTAINER_PLATFORM}" \
	-v "${ARTIFACTS}:/artifacts:Z" \
	-e ORACLELINUX_TEST_OUTPUT=/artifacts \
	"${IMAGE}" /opt/_internal/tests/oraclelinux8-gcc11.sh

# The upstream image contains its own compiler toolset. Unset its library search
# overrides so this check uses the distribution runtime for the exported ELFs.
# shellcheck disable=SC2016
"${CONTAINER_ENGINE}" run --rm --platform "${CONTAINER_PLATFORM}" \
	-v "${ARTIFACTS}:/artifacts:ro,Z" \
	-e ORACLELINUX_TEST_ARCH="${ARCH}" \
	"${UPSTREAM_IMAGE}" /bin/bash -euxo pipefail -c '
	test "${AUDITWHEEL_POLICY}" = manylinux_2_28
	test "${AUDITWHEEL_ARCH}" = "${ORACLELINUX_TEST_ARCH}"
	test -z "${MANYLINUX_VARIANT:-}"
	test "$(getconf GNU_LIBC_VERSION)" = "glibc 2.28"
	unset LD_LIBRARY_PATH PYTHONPATH
	/artifacts/programs/c-smoke
	/artifacts/programs/cxx-smoke
	/opt/python/cp39-cp39/bin/python -m venv /tmp/oracle-wheel-venv
	PYTHON=/tmp/oracle-wheel-venv/bin/python
	"${PYTHON}" -m pip install --no-index --no-deps /artifacts/wheelhouse/*-cp39-cp39-manylinux_2_28_${ORACLELINUX_TEST_ARCH}.whl
	"${PYTHON}" -I -c "import oraclelinux_cpp_smoke; assert oraclelinux_cpp_smoke.answer() == 42"
	"${PYTHON}" -I -c "import ctypes; lib = ctypes.CDLL(\"/artifacts/programs/liboraclelinux_smoke.so\"); assert lib.oraclelinux_answer() == 42"
	'

echo "Original upstream runtime test passed (${UPSTREAM_IMAGE})"
