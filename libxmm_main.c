#define PY_LIMITED_API 3
#define PY_SSIZE_T_CLEAN
#include <Python.h>

extern void zig_hello(void);

struct FrameStackPythonObject;
extern const size_t FrameStackPythonObject_size;
extern void      FrameStack_deinit (struct FrameStackPythonObject *);
extern int       FrameStack_new    (struct FrameStackPythonObject *);

#define FRAMESTACK_METHODS \
    X(push) X(pop) X(lookup_v) X(add_v) X(lookup_d) X(add_d) X(dbg)

#define X(METHOD) \
    extern PyObject *FrameStack_##METHOD(PyObject *, PyObject *);
FRAMESTACK_METHODS
#undef X

static void
FrameStack_dealloc(PyObject *self) {
    FrameStack_deinit((struct FrameStackPythonObject *)self);
    Py_TYPE(self)->tp_free(self);
}

static int
FrameStack_init(PyObject *self, PyObject *args, PyObject *kwargs) {
    static char *kwlist[] = {NULL};
    if (!PyArg_ParseTupleAndKeywords(args, kwargs, "", kwlist)) {
        return -1;
    }
    return FrameStack_new((struct FrameStackPythonObject *)self);
}

static struct PyMethodDef FrameStack_methods[] = {
    #define X(METHOD)                        \
        {                                    \
            .ml_name  = #METHOD,             \
            .ml_meth  = FrameStack_##METHOD, \
            .ml_flags = METH_VARARGS,        \
            .ml_doc   = NULL,                \
        },
    FRAMESTACK_METHODS
    #undef X
    { NULL }
};

static PyTypeObject FrameStack_cls = {
    .ob_base      = PyVarObject_HEAD_INIT(NULL, 0)
    .tp_name      = "libxmm.FrameStack",
    .tp_doc       = NULL,
    .tp_basicsize = 0, /* to be fixed upon init */
    .tp_itemsize  = 0,
    .tp_flags     = Py_TPFLAGS_DEFAULT,
    .tp_new       = PyType_GenericNew,
    .tp_init      = FrameStack_init,
    .tp_dealloc   = FrameStack_dealloc,
    .tp_methods   = FrameStack_methods,
};

static void
FrameStack_cls_init(void) {
    FrameStack_cls.tp_basicsize = FrameStackPythonObject_size;
}

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
PyInit_libxmm(void) {
    zig_hello();

    FrameStack_cls_init();
    if (PyType_Ready(&FrameStack_cls) < 0) return NULL;
    PyObject *m = PyModule_Create(&module);
    if (m == NULL) return NULL;

    PyObject *ty = (PyObject *)&FrameStack_cls;
    Py_INCREF(ty);
    if (PyModule_AddObject(m, "FrameStack", ty) < 0) {
        Py_DECREF(ty);
        Py_DECREF(m);
        return NULL;
    }
    return m;
}
