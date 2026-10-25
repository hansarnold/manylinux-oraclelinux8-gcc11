#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <exception>

extern "C" int oraclelinux_answer();

static PyObject* answer(PyObject*, PyObject*) {
    try {
        return PyLong_FromLong(oraclelinux_answer());
    } catch (const std::exception& error) {
        PyErr_SetString(PyExc_RuntimeError, error.what());
        return nullptr;
    }
}

static PyMethodDef methods[] = {
    {"answer", answer, METH_NOARGS, "Exercise the C++17 runtime."},
    {nullptr, nullptr, 0, nullptr},
};

static struct PyModuleDef module = {
    PyModuleDef_HEAD_INIT, "oraclelinux_cpp_smoke", nullptr, -1, methods,
    nullptr, nullptr, nullptr, nullptr,
};

PyMODINIT_FUNC PyInit_oraclelinux_cpp_smoke() {
    return PyModule_Create(&module);
}
