const py = @cImport({
    @cDefine("PY_LIMITED_API", "3");
    @cDefine("PY_SSIZE_T_CLEAN", {});
    @cInclude("Python.h");
});

const PyObject = py.PyObject;

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
const AutoHashMapUnmanaged = std.AutoHashMapUnmanaged;

const FrameStack = struct {
    const Tok = usize;

    const Frame = struct {
        v: AutoHashMapUnmanaged(Tok, void),
        dv: AutoHashMapUnmanaged([2]Tok, void),
        f: ArrayListUnmanaged(*PyObject), // FHyp
        f_labels: AutoHashMapUnmanaged(Tok, void),
        e: ArrayListUnmanaged(*PyObject), // EHyp

        fn new() Frame {
            return .{
                .v = .{},
                .dv = .{},
                .f = .{},
                .f_labels = .{},
                .e = .{},
            };
        }

        fn deinit(self: *Frame, ally: Allocator) void {
            self.v.deinit(ally);
            self.dv.deinit(ally);
            for (self.f.items) |fhyp| py.Py_DecRef(fhyp);
            self.f.deinit(ally);
            self.f_labels.deinit(ally);
            for (self.e.items) |fhyp| py.Py_DecRef(fhyp);
            self.e.deinit(ally);
        }
    };

    ally: Allocator,
    arena: ArenaAllocator,
    var_table: StringHashMapUnmanaged(Tok),
    constants: AutoHashMapUnmanaged(Tok, void),
    frames: ArrayListUnmanaged(Frame),

    const Self = @This();

    fn init(ally: Allocator) Self {
        return .{
            .ally = ally,
            .arena = std.heap.ArenaAllocator.init(ally),
            .var_table = .{},
            .constants = .{},
            .frames = .{},
        };
    }

    fn deinit(self: *Self) void {
        const ally = self.ally;
        self.var_table.deinit(ally);
        self.constants.deinit(ally);
        for (self.frames.items) |*fr| fr.deinit(self.ally);
        self.frames.deinit(ally);
        self.arena.deinit();
    }

    fn push(self: *Self) !void {
        try self.frames.append(self.ally, Frame.new());
    }

    fn top_frame(self: Self) !*Frame {
        const frames = self.frames.items;
        if (frames.len > 0)
            return &frames[frames.len - 1]
        else
            return error.NoFrame;
    }

    fn pop(self: *Self) !void {
        (try self.top_frame()).deinit(self.ally);
        _ = self.frames.pop();
    }

    fn tok(self: *Self, name: []const u8) !Tok {
        const ally = self.ally;
        const slot = try self.var_table.getOrPut(ally, name);
        if (!slot.found_existing) {
            // we have to make a copy since `name` isn't guaranteed to last
            const owned_name = try self.arena.allocator().dupe(u8, name);
            slot.key_ptr.* = owned_name;
            slot.value_ptr.* = self.var_table.count() - 1;
        }
        return slot.value_ptr.*;
    }

    fn lookup_v(self: *Self, v: Tok) !bool {
        if (self.constants.contains(v))
            return error.ConstTreatedAsVar;
        for (self.frames.items) |fr|
            if (fr.v.contains(v))
                return true;
        return false;
    }

    fn lookup_v_tok(self: *Self, tk: []const u8) !bool {
        return try self.lookup_v(try self.tok(tk));
    }

    fn add_v(self: *Self, tk: []const u8) !void {
        const v = try self.tok(tk);
        if (try self.lookup_v(v))
            return error.DuplicateVar;
        try (try self.top_frame()).v.putNoClobber(self.ally, v, {});
    }

    fn dbg(self: *Self) void {
        const stdout = std.io.getStdOut().writer();
        {
            stdout.writeAll("vars: {") catch {};
            var iter = self.var_table.iterator();
            var comma: []const u8 = "";
            while (iter.next()) |entry| {
                stdout.print("{s}{s}={}", .{comma, entry.key_ptr.*, entry.value_ptr.*}) catch {};
                comma = ", ";
            }
            stdout.writeAll("}\n") catch {};
        }
        {
            stdout.writeAll("frames:\n") catch {};
            for (self.frames.items) |fr| {
                var iter = fr.v.iterator();
                while (iter.next()) |entry|
                    stdout.print(" {}", .{entry.key_ptr.*}) catch {};
                stdout.writeAll("\n") catch {};
            }
        }
    }

    comptime {
        export_FrameStack_method("push", push);
        export_FrameStack_method("pop", pop);
        export_FrameStack_method("lookup_v", lookup_v_tok);
        export_FrameStack_method("add_v", add_v);
        export_FrameStack_method("dbg", dbg);
    }

    const PythonObject = extern struct {
        ob_base: PyObject,
        payload: ?*FrameStack,
    };
};

export fn FrameStack_deinit(self: *FrameStack.PythonObject) void {
    if (self.payload) |p| {
        p.deinit();
        std.heap.c_allocator.destroy(p);
    }
}

export fn FrameStack_new(self: *FrameStack.PythonObject) c_int {
    const payload = std.heap.c_allocator.create(FrameStack) catch |e| switch (e) {
        error.OutOfMemory => return -1,
    };
    payload.* = FrameStack.init(std.heap.c_allocator);
    self.payload = payload;
    return 0;
}

fn export_FrameStack_method(
    comptime method_name: []const u8,
    comptime method: anytype,
) void {
    const receiver_and_params = @typeInfo(@TypeOf(method)).Fn.params;
    const ReturnType = @typeInfo(@TypeOf(method)).Fn.return_type.?;
    assert(receiver_and_params[0].type.? == *FrameStack);
    const all_params = receiver_and_params[1..];
    // we iterate through the parameters in two loops, expressed
    // as recursive functions because the accumulators don't have a
    // fixed type.
    // (the first loop tail calls the second, because otherwise we
    // would have to describe the data being passed between the loops
    // in the return type.)
    const helpers = struct {
        // 1. use the param list to build:
        // - the format string for a call to PyArg_ParseTuple
        // - a tuple of pointers (to local variables) for the call
        fn parse_tuple_and_build_args_and_call(
            comptime params: []const std.builtin.Type.Fn.Param,
            comptime acc_format_str: []const u8,
            acc_pointers: anytype,
            receiver: *FrameStack,
            args_tuple: *PyObject,
        ) ?ReturnType {
            if (params.len == 0) {
                const ParseTuple_args = .{
                    args_tuple,
                    acc_format_str ++ ":" ++ method_name,
                } ++ acc_pointers;
                if (0 == @call(.auto, py.PyArg_ParseTuple, ParseTuple_args))
                    return null;
                return build_args_and_call(
                    all_params, // restarting from the beginning!
                    acc_pointers,
                    0, // cursor
                    .{ receiver },
                );
            }
            const param_type = params[0].type.?;
            switch (param_type) {
                *PyObject => {
                    var obj: *PyObject = undefined;
                    return parse_tuple_and_build_args_and_call(
                        params[1..],
                        acc_format_str ++ "O",
                        acc_pointers ++ .{ &obj },
                        receiver,
                        args_tuple,
                    );
                },
                []const u8 => {
                    var ptr: [*]const u8 = undefined;
                    var len: isize = undefined;
                    return parse_tuple_and_build_args_and_call(
                        params[1..],
                        acc_format_str ++ "s#",
                        acc_pointers ++ .{ &ptr, &len },
                        receiver,
                        args_tuple,
                    );
                },
                else => @compileError("unsupported parameter type: " ++ @typeName(param_type)),
            }
        }

        // 2. use the param list to build
        // a tuple of arguments in Zig's preferred representation
        // to be passed to `method`
        fn build_args_and_call(
            comptime params: []const std.builtin.Type.Fn.Param,
            pointers: anytype,
            comptime cursor: usize,
            acc_converted: anytype,
        ) ?ReturnType {
            if (params.len == 0) {
                return @call(.auto, method, acc_converted);
            }
            switch (params[0].type.?) {
                *PyObject => {
                    return build_args_and_call(
                        params[1..], pointers, cursor + 1,
                        acc_converted ++ .{pointers[cursor].*},
                    );
                },
                []const u8 => {
                    const str_ptr = pointers[cursor].*;
                    const str_len = pointers[cursor + 1].*;
                    return build_args_and_call(
                        params[1..], pointers, cursor + 2,
                        acc_converted ++ .{str_ptr[0..@intCast(str_len)]},
                    );
                },
                else => unreachable,
            }
        }

        fn convert(comptime ty: type, result: ty) ?*PyObject {
            switch (ty) {
                *PyObject, ?*PyObject => return result,
                usize => return py.PyLong_FromUnsignedLong(result),
                bool => return py.PyBool_FromLong(@intFromBool(result)),
                void => {
                    py.Py_IncRef(py.Py_None);
                    return py.Py_None;
                },
                else => switch (@typeInfo(ty)) {
                    .ErrorUnion => |eu| {
                        if (result) |ok| {
                            return convert(eu.payload, ok);
                        } else |err| {
                            py.PyErr_SetString(py.PyExc_RuntimeError, @errorName(err));
                            return null;
                        }
                    },
                    else => @compileError("unsupported return type: " ++ @typeName(ReturnType)),
                }
            }
        }

        fn shim(self: *PyObject, args_tuple: *PyObject) callconv(.C) ?*PyObject {
            const obj: *FrameStack.PythonObject = @ptrCast(self);
            const receiver = obj.payload.?;
            const result = parse_tuple_and_build_args_and_call(
                all_params,
                "", .{},
                receiver, args_tuple
            ) orelse return null;
            return convert(ReturnType, result);
        }
    };
    @export(helpers.shim, .{ .name = "FrameStack_" ++ method_name});
}

export const FrameStackPythonObject_size: usize = @sizeOf(FrameStack.PythonObject);

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
