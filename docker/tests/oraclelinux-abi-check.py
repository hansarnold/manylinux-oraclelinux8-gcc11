"""Check probe ELFs against the installed, unmodified auditwheel policy.

Run with auditwheel's own Python (which provides auditwheel and pyelftools).
This complements auditwheel repair: it also checks the standalone C/C++ probes.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

import auditwheel
from elftools.elf.elffile import ELFFile

POLICY_PATH = Path(auditwheel.__file__).parent / "policy" / "manylinux-policy.json"
POLICY = next(
    policy for policy in json.loads(POLICY_PATH.read_text()) if policy["name"] == "manylinux_2_28"
)
ALLOWED_VERSIONS = {
    f"{namespace}_{version}"
    for namespace, versions in POLICY["symbol_versions"]["x86_64"].items()
    for version in versions
}


def check_elf(path):
    with path.open("rb") as stream:
        elf = ELFFile(stream)
        if elf.elfclass != 64 or elf.header["e_machine"] != "EM_X86_64":
            msg = f"{path}: expected an x86_64 ELF"
            raise RuntimeError(msg)
        dynamic = elf.get_section_by_name(".dynamic")
        if dynamic is None:
            msg = f"{path}: expected a dynamically linked ELF"
            raise RuntimeError(msg)
        needed = set()
        for tag in dynamic.iter_tags():
            if tag.entry.d_tag == "DT_NEEDED":
                needed.add(tag.needed)
            if tag.entry.d_tag in {"DT_RPATH", "DT_RUNPATH"}:
                msg = f"{path}: unexpected embedded library search path"
                raise RuntimeError(msg)
        # auditwheel also exempts the architecture's ELF interpreter.
        forbidden = needed - set(POLICY["lib_whitelist"]) - {"ld-linux-x86-64.so.2"}
        if forbidden:
            msg = f"{path}: unexpected runtime dependencies: {forbidden}"
            raise RuntimeError(msg)

        requirements = set()
        version_section = elf.get_section_by_name(".gnu.version_r")
        if version_section is not None:
            for _, auxiliary in version_section.iter_versions():
                requirements.update(version.name for version in auxiliary)
        forbidden = requirements - ALLOWED_VERSIONS
        if forbidden:
            msg = f"{path}: symbols outside manylinux_2_28: {forbidden}"
            raise RuntimeError(msg)

        symbols = elf.get_section_by_name(".dynsym")
        undefined = {
            symbol.name for symbol in symbols.iter_symbols() if symbol["st_shndx"] == "SHN_UNDEF"
        }
        for library in needed:
            forbidden = undefined & set(POLICY["blacklist"].get(library, []))
            if forbidden:
                msg = f"{path}: forbidden {library} symbols: {forbidden}"
                raise RuntimeError(msg)

    notes = subprocess.check_output(["readelf", "--notes", str(path)], text=True)
    for isa in re.findall(r"x86 ISA needed:\s*([^\n]+)", notes):
        if isa.strip() != "x86-64-baseline":
            msg = f"{path}: non-baseline x86 ISA requirement: {isa}"
            raise RuntimeError(msg)
    print(f"{path}: needed={sorted(needed)}, versions={sorted(requirements)}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        msg = "usage: oraclelinux-abi-check.py ELF [ELF ...]"
        raise SystemExit(msg)
    for filename in sys.argv[1:]:
        check_elf(Path(filename))
