#define PY_LIMITED_API 3
#define PY_SSIZE_T_CLEAN
#include <Python.h>

extern void zig_hello(void);

// static struct PyMethodDef methods = {

// }

static struct PyModuleDef module = {
    .m_base = PyModuleDef_HEAD_INIT,
    .m_name = "libxmm",
    .m_doc = NULL,
    .m_size = -1,
    .m_methods = NULL, // &methods,
    .m_slots = NULL,
    .m_traverse = NULL,
    .m_clear = NULL,
    .m_free = NULL,
};

PyMODINIT_FUNC
PyInit_libxmm(void)
{
    // zig_hello();
    return PyModule_Create(&module);
}
