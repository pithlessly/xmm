const py = @cImport({
    @cDefine("PY_LIMITED_API", "3");
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

const PyObject = py.PyObject;

const std = @import("std");

export fn apply_subst(
    self: *PyObject,
    args: *PyObject,
) ?*PyObject {
    _ = self;
    var stmt: *PyObject = undefined; // : Stmt
    var subst: *PyObject = undefined; // : dict[Var, Stmt]
    if (0 == py.PyArg_UnpackTuple(args, "apply_subst", 2, 2, &stmt, &subst))
        return null;
    if (0 == py.PyList_CheckExact(stmt)) {
        py.PyErr_SetString(py.PyExc_TypeError, "expected stmt to be a Stmt");
        return null;
    }
    if (0 == py.PyDict_CheckExact(subst)) {
        py.PyErr_SetString(py.PyExc_TypeError, "expected subst to be a dictionary");
        return null;
    }
    var result_len: isize = 0;
    const stmt_len: isize = py.PyList_Size(stmt);
    {
        var i: isize = 0;
        while (i < stmt_len) : (i += 1) {
            const tok = py.PyList_GetItem(stmt, i);
            if (0 == py.PyUnicode_CheckExact(tok)) {
                py.PyErr_SetString(py.PyExc_TypeError, "expected the elements of stmt to be str");
                return null;
            }
            const replacement = py.PyDict_GetItem(subst, tok);
            if (replacement == null) {
                result_len += 1;
            } else {
                if (0 == py.PyList_CheckExact(replacement)) {
                    py.PyErr_SetString(py.PyExc_TypeError, "expected the values of subst to be Stmt");
                    return null;
                }
                result_len += py.PyList_Size(replacement);
            }
        }
    }
    const result = py.PyList_New(result_len);
    if (result == null) return null;
    var succeeded = false;
    defer if (!succeeded) py.Py_DecRef(result);
    {
        var i: isize = 0;
        var j: isize = 0;
        while (i < stmt_len) : (i += 1) {
            const tok = py.PyList_GetItem(stmt, i);
            const replacement = py.PyDict_GetItem(subst, tok);
            if (replacement == null) {
                py.Py_IncRef(tok);
                _ = py.PyList_SetItem(result, j, tok);
                j += 1;
            } else {
                const replacement_len = py.PyList_Size(replacement);
                var k: isize = 0;
                while (k < replacement_len) : (k += 1) {
                    const replacement_tok = py.PyList_GetItem(replacement, k);
                    py.Py_IncRef(replacement_tok);
                    _ = py.PyList_SetItem(result, j, replacement_tok);
                    j += 1;
                }
            }
        }
    }
    succeeded = true;
    return result;
}

export fn zig_hello() void {
    std.io.getStdOut().writeAll("Initializing module; hello from Zig\n") catch {};
}
