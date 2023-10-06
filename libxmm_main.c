#define PY_LIMITED_API 3
#define PY_SSIZE_T_CLEAN
#include <Python.h>

extern void zig_hello(void);

extern PyObject *apply_subst(PyObject *, PyObject *);

static struct PyMethodDef methods[] = {
    {
        .ml_name = "apply_subst",
        .ml_meth = apply_subst,
        .ml_flags = METH_VARARGS,
        .ml_doc = NULL,
    },
    { NULL }
};

static struct PyModuleDef module = {
    .m_base     = PyModuleDef_HEAD_INIT,
    .m_name     = "libxmm",
    .m_doc      = NULL,
    .m_size     = -1,
    .m_methods  = methods,
    .m_slots    = NULL,
    .m_traverse = NULL,
    .m_clear    = NULL,
    .m_free     = NULL,
};

PyMODINIT_FUNC
PyInit_libxmm(void)
{
    // zig_hello();
    return PyModule_Create(&module);
}
