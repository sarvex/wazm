const std = @import("std");
const builtin = @import("builtin");

pub const StackChange = enum {
    Void,
    I32,
    I64,
    F32,
    F64,

    fn from(comptime T: type) StackChange {
        return switch (T) {
            void => .Void,
            i32 => .I32,
            i64 => .I64,
            f32 => .F32,
            f64 => .F64,
            else => @compileError("Unsupported type:" ++ @typeName(T)),
        };
    }
};

pub const Arg = packed union {
    b1: u8,
    b4: [4]u8,
    b5: [5]u8,
    b8: [8]u8,
    _pad: u64,

    pub const None = packed union {
        const bytes = 0;
        _pad: u64,
    };
    // TODO: this only works in LittleEndian
    pub const Type = enum(u64) {
        const bytes = 1;
        Void = 0x40,
        I32 = 0x7F,
        I64 = 0x7E,
        F32 = 0x7D,
        F64 = 0x7C,
    };
    pub const I32 = packed union {
        const bytes = 4;
        data: u32,
        _pad: u64,
    };
    pub const I32z = packed union {
        const bytes = 5;
        data: u32,
        _pad: u64,
    };
    pub const Mem = packed struct {
        const bytes = 8;
        offset: u32,
        align_: u32,
    };
};
pub const ArgKind = enum {
    None,
    Type,
    I32,
    I32z,
    Mem,

    fn from(comptime T: type) ArgKind {
        return switch (T) {
            Arg.None => .None,
            Arg.Type => .Type,
            Arg.I32 => .I32,
            Arg.I32z => .I32z,
            Arg.Mem => .Mem,
            else => @compileError("Unsupported type: " ++ @typeName(T)),
        };
    }
};

test "Arg smoke" {
    const size = @sizeOf(Arg);
    inline for (std.meta.declarations(Arg)) |decl| {
        if (decl.data == .Type) {
            _ = decl.data.Type.bytes;
            std.testing.expectEqual(size, @sizeOf(decl.data.Type));
        }
    }
}

const Meta = struct {
    code: u8,
    name: []const u8,
    arg: struct {
        kind: ArgKind,
        bytes: u8,
    },
    push: StackChange,
    pop: [2]StackChange,

    fn lessThan(lhs: Meta, rhs: Meta) bool {
        return std.mem.lessThan(u8, lhs.name, rhs.name);
    }

    pub fn format(
        self: Meta,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        context: var,
        comptime Errors: type,
        output: fn (@TypeOf(context), []const u8) Errors!void,
    ) Errors!void {
        return std.fmt.format(
            context,
            Errors,
            output,
            "Op( 0x{x} \"{}\" {{{} {}b}} [{},{}]->[{}] )",
            .{ self.code, self.name, @tagName(self.arg.kind), self.arg.bytes, @tagName(self.pop[0]), @tagName(self.pop[1]), @tagName(self.push) },
        );
    }
};

pub const sparse = blk: {
    const decls = publicFunctions(Impl);
    var result: [decls.len]Meta = undefined;
    for (decls) |decl, i| {
        std.debug.assert(decl.name[0] == '0');
        std.debug.assert(decl.name[1] == 'x');
        std.debug.assert(decl.name[4] == ' ');

        const args = @typeInfo(decl.data.Fn.fn_type).Fn.args;
        const ctx_type = args[0].arg_type.?;
        const arg_type = args[1].arg_type.?;
        const pop_type = args[2].arg_type.?;

        result[i] = .{
            .code = std.fmt.parseInt(u8, decl.name[2..4], 16) catch unreachable,
            .name = decl.name[5..],
            .arg = .{ .bytes = arg_type.bytes, .kind = ArgKind.from(arg_type) },
            .push = StackChange.from(decl.data.Fn.return_type),
            .pop = switch (@typeInfo(pop_type)) {
                .Void, .Int, .Float => .{ StackChange.from(pop_type), .Void },
                else => @compileError("Unsupported pop type: " ++ @typeName(pop_type)),
            },
        };
    }

    std.sort.sort(Meta, &result, Meta.lessThan);

    break :blk result;
};

pub const all = blk: {
    const uninit = Meta{
        .code = 0xAA,
        .name = "ILLEGAL",
        .arg = .{ .bytes = 0, .kind = .Void },
        .pop = .{ .Void, .Void },
        .push = .Void,
    };
    var result = [_]Meta{uninit} ** 256;
    for (result) |*meta, i| {
        meta.code = i;
    }

    for (sparse) |meta| {
        result[meta.code] = meta;
    }
    break :blk result;
};

pub fn byName(needle: []const u8) !Meta {
    var curr: usize = 0;
    var size = sparse.len;
    while (size > 0) {
        const offset = size % 2;

        size /= 2;
        const meta = sparse[curr + size];
        switch (std.mem.order(u8, needle, meta.name)) {
            .lt => {},
            .eq => return meta,
            .gt => curr += size + offset,
        }
    }
    return error.OpNotFound;
}

fn publicFunctions(comptime T: type) []builtin.TypeInfo.Declaration {
    const decls = std.meta.declarations(T);
    var result: [decls.len]builtin.TypeInfo.Declaration = undefined;
    var cursor: usize = 0;
    for (decls) |decl| {
        if (decl.is_pub and decl.data == .Fn) {
            result[cursor] = decl;
            cursor += 1;
        }
    }

    return result[0..cursor];
}

test "ops" {
    const nop = try byName("nop");
    std.testing.expectEqual(nop.arg.bytes, 0);
    std.testing.expectEqual(nop.push, .Void);
    std.testing.expectEqual(nop.pop[0], .Void);
    std.testing.expectEqual(nop.pop[1], .Void);

    const i32_load = try byName("i32.load");
    std.testing.expectEqual(i32_load.arg.bytes, 8);
    std.testing.expectEqual(i32_load.push, .I32);
    std.testing.expectEqual(i32_load.pop[0], .I32);
    std.testing.expectEqual(i32_load.pop[1], .Void);
}

const Impl = struct {
    const Context = struct {};

    pub fn @"0x00 unreachable"(ctx: Context, arg: Arg.None, pop: void) void {}

    pub fn @"0x01 nop"(ctx: Context, arg: Arg.None, pop: void) void {}

    pub fn @"0x02 block"(ctx: Context, arg: Arg.Type, pop: void) void {}

    pub fn @"0x03 loop"(ctx: Context, arg: Arg.Type, pop: void) void {}

    pub fn @"0x04 if"(ctx: Context, arg: Arg.Type, pop: i32) void {}

    pub fn @"0x05 else"(ctx: Context, arg: Arg.None, pop: void) void {}

    pub fn @"0x0B end"(ctx: Context, arg: Arg.None, pop: void) void {}

    pub fn @"0x0C br"(ctx: Context, arg: Arg.None, pop: void) void {}

    pub fn @"0x0D br_if"(ctx: Context, arg: Arg.I32, pop: void) void {}

    pub fn @"0x0E br_table"(ctx: Context, arg: Arg.Mem, pop: void) void {}

    pub fn @"0x0F return"(ctx: Context, arg: Arg.None, pop: void) void {}

    pub fn @"0x20 local.get"(ctx: Context, arg: Arg.I32, pop: i32) i32 {
        return 0;
    }

    pub fn @"0x28 i32.load"(ctx: Context, arg: Arg.Mem, pop: i32) i32 {
        return 0;
    }
};