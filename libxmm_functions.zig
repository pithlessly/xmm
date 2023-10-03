const py = @cImport({
    @cDefine("PY_LIMITED_API", "3");
    @cInclude("Python.h");
});

const PyObject = py.PyObject;

const std = @import("std");

export fn zig_hello() void {
    std.io.getStdOut().writeAll("Initializing module; hello from Zig\n") catch {};
}
