#!/bin/bash
# Oracle-only repository setup and invariants, also checked after system upgrades.
set -exuo pipefail

# shellcheck source=/dev/null
source /etc/os-release
if [ "${MANYLINUX_VARIANT:-}" != "oraclelinux8-gcc11" ] || \
   [ "${ID}-${VERSION_ID%%.*}" != "ol-8" ] || \
   [ "${AUDITWHEEL_POLICY}" != "manylinux_2_28" ] || \
   [ "${DEVTOOLSET_ROOTPATH}" != "/opt/rh/gcc-toolset-11/root" ]; then
	echo "Invalid Oracle Linux 8 / GCC Toolset 11 configuration" >&2
	exit 1
fi
case "${AUDITWHEEL_ARCH}" in
	x86_64) BASELINE_ISA=x86-64;;
	aarch64) BASELINE_ISA=armv8-a;;
	*) echo "Unsupported Oracle variant architecture: ${AUDITWHEEL_ARCH}" >&2; exit 1;;
esac
test "$(rpm --eval '%{_arch}')" = "${AUDITWHEEL_ARCH}"

# Reviewed together; never substitute the system compiler or another toolset.
GCC_EVR=11.5.0-2.0.1.el8_6
BINUTILS_EVR=2.36.1-4.0.2.el8_6
RUNTIME_EVR=11.1-1.el8
PACKAGES=(
	"gcc-toolset-11-runtime-${RUNTIME_EVR}.${AUDITWHEEL_ARCH}"
	"gcc-toolset-11-binutils-${BINUTILS_EVR}.${AUDITWHEEL_ARCH}"
	"gcc-toolset-11-gcc-${GCC_EVR}.${AUDITWHEEL_ARCH}"
	"gcc-toolset-11-gcc-c++-${GCC_EVR}.${AUDITWHEEL_ARCH}"
	"gcc-toolset-11-gcc-gfortran-${GCC_EVR}.${AUDITWHEEL_ARCH}"
	"gcc-toolset-11-libstdc++-devel-${GCC_EVR}.${AUDITWHEEL_ARCH}"
	"gcc-toolset-11-libatomic-devel-${GCC_EVR}.${AUDITWHEEL_ARCH}"
)
if [ "${AUDITWHEEL_ARCH}" == "x86_64" ]; then
	# Oracle does not publish libquadmath-devel for aarch64.
	PACKAGES+=("gcc-toolset-11-libquadmath-devel-${GCC_EVR}.${AUDITWHEEL_ARCH}")
fi

if [ "${1:-check}" == "install" ]; then
	# Bootstrap only from Oracle's two default repositories. CodeReady supplies
	# yasm and uuid-devel; this variant does not need EPEL or non-Oracle repos.
	dnf -y --disablerepo='*' --enablerepo=ol8_baseos_latest,ol8_appstream install \
		dnf-plugins-core python3-dnf-plugin-versionlock
	dnf config-manager --set-disabled '*'
	dnf config-manager --set-enabled ol8_baseos_latest ol8_appstream ol8_codeready_builder
	dnf -y upgrade --nobest
	dnf -y install "${PACKAGES[@]}"
	# Also lock any transitive collection packages. Base OS
	# packages still receive upstream's normal updates, including security fixes.
	dnf versionlock add 'gcc-toolset-11-*'
elif [ "${1:-check}" != "check" ]; then
	echo "Usage: $0 [install|check]" >&2
	exit 1
fi

rpm -q "${PACKAGES[@]}"
test "$(getconf GNU_LIBC_VERSION)" = "glibc 2.28"
for COMPILER in gcc g++ gfortran; do
	test "$(command -v "${COMPILER}")" = "${DEVTOOLSET_ROOTPATH}/usr/bin/${COMPILER}"
	test "$("${COMPILER}" -dumpfullversion)" = "11.5.0"
	# Check the vendor default before building interpreters, without overriding it.
	test "$("${COMPILER}" -Q --help=target | awk '$1 == "-march=" {print $2}')" = "${BASELINE_ISA}"
done

# Oracle's GCC 11 RPM intentionally links the base libstdc++.so.6 and resolves
# newer functions from this archive. Preserve its vendor linker script, rather
# than applying the GCC 14 workaround or forcing -static-libstdc++.
LINKER_SCRIPT=$(g++ -print-file-name=libstdc++.so)
NONSHARED=$(g++ -print-file-name=libstdc++_nonshared.a)
test -f "${NONSHARED}"
grep -Eq '^INPUT \( /usr/lib64/libstdc\+\+\.so\.6 -lstdc\+\+_nonshared \)$' "${LINKER_SCRIPT}"

mkdir -p /opt/_internal
rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | LC_ALL=C sort > /opt/_internal/oraclelinux8-rpm-manifest.txt
