from setuptools import Extension, setup

setup(
    name="oraclelinux_cpp_smoke",
    version="0.1.0",
    python_requires=">=3.9",
    ext_modules=[
        Extension(
            "oraclelinux_cpp_smoke",
            sources=["extension.cpp", "probe.cpp"],
            language="c++",
            extra_compile_args=["-std=c++17", "-D_GLIBCXX_ASSERTIONS"],
            extra_link_args=["-Wl,--as-needed"],
        )
    ],
)
