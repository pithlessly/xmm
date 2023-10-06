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
const AutoArrayHashMapUnmanaged = std.AutoArrayHashMapUnmanaged;

const FrameStack = struct {
    const Tok = usize;

    const Frame = struct {
        v_offset: usize,
        dv_offset: usize,
        e_offset: usize,
        f: ArrayListUnmanaged(*PyObject), // FHyp
        f_labels: AutoHashMapUnmanaged(Tok, void),

        fn deinit(self: *Frame, ally: Allocator) void {
            for (self.f.items) |fhyp| py.Py_DecRef(fhyp);
            self.f.deinit(ally);
            self.f_labels.deinit(ally);
        }
    };

    ally: Allocator,
    arena: ArenaAllocator,
    intern: StringHashMapUnmanaged(Tok),
    constants: AutoHashMapUnmanaged(Tok, void),
    vars: AutoArrayHashMapUnmanaged(Tok, void),
    dvs: AutoArrayHashMapUnmanaged([2]Tok, void),
    es: ArrayListUnmanaged(*PyObject), // EHyp
    frames: ArrayListUnmanaged(Frame),

    const Self = @This();

    fn init(ally: Allocator) Self {
        return .{
            .ally = ally,
            .arena = std.heap.ArenaAllocator.init(ally),
            .intern = .{},
            .constants = .{},
            .vars = .{},
            .dvs = .{},
            .es = .{},
            .frames = .{},
        };
    }

    fn deinit(self: *Self) void {
        const ally = self.ally;
        self.intern.deinit(ally);
        self.constants.deinit(ally);
        self.vars.deinit(ally);
        self.dvs.deinit(ally);
        for (self.es.items) |ehyp| py.Py_DecRef(ehyp);
        self.es.deinit(ally);
        for (self.frames.items) |*fr| fr.deinit(self.ally);
        self.frames.deinit(ally);
        self.arena.deinit();
    }

    fn push(self: *Self) !void {
        try self.frames.append(self.ally, .{
            .v_offset = self.vars.count(),
            .dv_offset = self.dvs.count(),
            .e_offset = self.es.items.len,
            .f = .{},
            .f_labels = .{},
        });
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
        const old_frame = self.frames.pop();
        self.vars.shrinkRetainingCapacity(old_frame.v_offset);
        self.dvs.shrinkRetainingCapacity(old_frame.dv_offset);
        for (self.es.items[old_frame.e_offset..]) |ehyp| py.Py_DecRef(ehyp);
        self.es.shrinkRetainingCapacity(old_frame.e_offset);
    }

    fn tok(self: *Self, name: []const u8) !Tok {
        const ally = self.ally;
        const slot = try self.intern.getOrPut(ally, name);
        if (!slot.found_existing) {
            // we have to make a copy since `name` isn't guaranteed to last
            const owned_name = try self.arena.allocator().dupe(u8, name);
            slot.key_ptr.* = owned_name;
            slot.value_ptr.* = self.intern.count() - 1;
        }
        return slot.value_ptr.*;
    }

    fn lookup_v(self: *Self, v: Tok) !bool {
        if (self.constants.contains(v))
            return error.ConstTreatedAsVar;
        return self.vars.contains(v);
    }

    fn lookup_v_tok(self: *Self, tk: []const u8) !bool {
        return try self.lookup_v(try self.tok(tk));
    }

    fn add_v(self: *Self, tk: []const u8) !void {
        const v = try self.tok(tk);
        if (try self.lookup_v(v))
            return error.DuplicateVar;
        try self.vars.putNoClobber(self.ally, v, {});
    }

    fn lookup_d(self: *Self, tk1: []const u8, tk2: []const u8) !bool {
        const v1 = try self.tok(tk1);
        const v2 = try self.tok(tk2);
        const k = if (v1 < v2) .{ v1, v2 } else .{ v2, v1 };
        // TODO: skip checking if v1 == v2?
        return self.dvs.contains(k);
    }

    fn add_d1(self: *Self, v1: Tok, v2: Tok) !void {
        assert(v1 < v2);
        const k = .{ v1, v2 };
        try self.dvs.put(self.ally, k, {});
    }

    fn add_d(self: *Self, vars: *PyObject) !?void {
        // add a collection of disjointnesses to the most recent frame.
        // we insert all pairs separately - although this is O(N^2) work,
        // the longest $d annotation in set.mm would only create 253
        // entries, many of which are deduplicates.
        // compare with an approach which creates "disjointness groups" for
        // every '$d' statement and checks disjointness of two variables
        // by seeing whether they have a disjointness group in common.
        if (0 == py.PyList_CheckExact(vars)) {
            py.PyErr_SetString(py.PyExc_TypeError, "expected vars to be a list");
            return null;
        }
        const ally = self.ally;
        const vs = try ally.alloc(Tok, @intCast(py.PyList_Size(vars)));
        defer ally.free(vs);
        for (vs, 0..) |*v, i| {
            const var_ = py.PyList_GetItem(vars, @intCast(i));
            if (0 == py.PyUnicode_CheckExact(var_)) {
                py.PyErr_SetString(py.PyExc_TypeError, "expected vars[] to be str");
                return null;
            }
            var size: isize = undefined;
            const ptr = @as(?[*]const u8, py.PyUnicode_AsUTF8AndSize(var_, &size)) orelse return null;
            v.* = try self.tok(ptr[0..@intCast(size)]);
        }
        std.mem.sort(Tok, vs, {}, std.sort.asc(Tok));
        var i: usize = 0;
        while (i < vs.len - 1) : (i += 1) {
            var j = i;
            while (j < vs.len) : (j += 1)
                try self.add_d1(vs[i], vs[j]);
        }
    }

    fn add_e(self: *Self, vars: *PyObject) !void {
        py.Py_IncRef(vars);
        try self.es.append(self.ally, vars);
    }

    fn all_ehyps(self: *Self) !*PyObject {
        const result = py.PyList_New(@intCast(self.es.items.len));
        for (self.es.items, 0..) |e, i| {
            py.Py_IncRef(e);
            _ = py.PyList_SetItem(result, @intCast(i), e);
        }
        return result;
    }

    fn dbg(self: *Self) void {
        const stdout = std.io.getStdOut().writer();
        {
            stdout.writeAll("intern: {") catch {};
            var iter = self.intern.iterator();
            var comma: []const u8 = "";
            while (iter.next()) |entry| {
                stdout.print("{s}{s}={}", .{ comma, entry.key_ptr.*, entry.value_ptr.* }) catch {};
                comma = ", ";
            }
            stdout.writeAll("}\n") catch {};
        }
        {
            stdout.writeAll("frames:\n<TODO: reimplement this>\n") catch {};
        }
    }

    comptime {
        export_FrameStack_method("push", push);
        export_FrameStack_method("pop", pop);
        export_FrameStack_method("lookup_v", lookup_v_tok);
        export_FrameStack_method("add_v", add_v);
        export_FrameStack_method("lookup_d", lookup_d);
        export_FrameStack_method("add_d", add_d);
        export_FrameStack_method("add_e", add_e);
        export_FrameStack_method("all_ehyps", all_ehyps);
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
    assert(switch (receiver_and_params[0].type.?) {
        *FrameStack, *const FrameStack => true,
        else => false,
    });
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
                    .{receiver},
                );
            }
            const param_type = params[0].type.?;
            switch (param_type) {
                *PyObject => {
                    var obj: *PyObject = undefined;
                    return parse_tuple_and_build_args_and_call(
                        params[1..],
                        acc_format_str ++ "O",
                        acc_pointers ++ .{&obj},
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
                else => @compileError(method_name ++ "() has unsupported parameter type: " ++ @typeName(param_type)),
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
                        params[1..],
                        pointers,
                        cursor + 1,
                        acc_converted ++ .{pointers[cursor].*},
                    );
                },
                []const u8 => {
                    const str_ptr = pointers[cursor].*;
                    const str_len = pointers[cursor + 1].*;
                    return build_args_and_call(
                        params[1..],
                        pointers,
                        cursor + 2,
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
                    .Optional => |opt| {
                        if (result) |some| {
                            return convert(opt.child, some);
                        } else return null;
                    },
                    else => @compileError("unsupported return type: " ++ @typeName(ReturnType)),
                },
            }
        }

        fn shim(self: *PyObject, args_tuple: *PyObject) callconv(.C) ?*PyObject {
            const obj: *FrameStack.PythonObject = @ptrCast(self);
            const receiver = obj.payload.?;
            const result = parse_tuple_and_build_args_and_call(all_params, "", .{}, receiver, args_tuple) orelse return null;
            return convert(ReturnType, result);
        }
    };
    @export(helpers.shim, .{ .name = "FrameStack_" ++ method_name });
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
    std.io.getStdOut().writeAll("Initializing libxmm; hello from Zig\n") catch {};
}
