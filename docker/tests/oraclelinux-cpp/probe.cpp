#include <filesystem>
#include <stdexcept>
#include <string>

// Filesystem uses GCC 11's nonshared archive on EL8. Keep this out of headers so
// both the native shared library and the Python wheel exercise the linker.
extern "C" int oraclelinux_answer() {
    const auto directory = std::filesystem::canonical(".");
    const auto path = (directory / "probe" / ".." / "42").lexically_normal();
    if (!directory.is_absolute() || path.filename().string() != "42") {
        throw std::runtime_error("filesystem probe failed");
    }
    try {
        throw std::runtime_error("42");
    } catch (const std::exception& error) {
        return std::stoi(error.what());
    }
}
