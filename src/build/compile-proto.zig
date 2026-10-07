const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const process = std.process;
const assert = std.debug.assert;

const supported_syntax_literal = "\"proto3\"";
const input_file_size_max: usize = 2048 * 1024; // 2MB

pub fn main(init: process.Init) !void {
    const arena = init.arena.allocator();
    const args_slice = try init.minimal.args.toSlice(arena);
    assert(args_slice.len != 0);

    const file_paths = args_slice[1..];
    if (file_paths.len == 0) process.fatal("no input files", .{});

    const input_buffer = try arena.alloc(u8, input_file_size_max + 1); // +1 for sentinel

    const io = init.io;
    var output_buffer: [4096]u8 = undefined;
    var output_writer: Io.File.Writer = .initStreaming(.stdout(), io, &output_buffer);

    output_writer.interface.writeAll(
        \\//! Generated with grace-compile-proto. 2026, ReversedRooms. All bytes reversed.
        \\
        \\pub const ProtobufOptions = struct {
        \\    Encoding: type,
        \\    Iterator: fn (comptime T: type) type,
        \\    KeyValue: fn (comptime K: type, comptime V: type) type,
        \\};
        \\
        \\pub fn makeNamespace(comptime protobuf: ProtobufOptions) type {
        \\    const Iterator = protobuf.Iterator;
        \\    const KeyValue = protobuf.KeyValue;
        \\    const Encoding = protobuf.Encoding;
        \\
        \\    return struct {
        \\
    ) catch return output_writer.err.?;

    const scope_indent = Indentation.top_level.increment().increment();

    for (file_paths) |file_path| {
        const input = try Io.Dir.cwd().readFile(
            io,
            file_path,
            input_buffer[0..input_file_size_max],
        );
        assert(input.len < input_buffer.len);
        input_buffer[input.len] = 0;
        const source: [:0]const u8 = @ptrCast(input_buffer[0..input.len]);

        compileFile(source, scope_indent, &output_writer.interface) catch |err| switch (err) {
            error.WriteFailed => return output_writer.err.?,
            else => |e| return e,
        };
    }

    try output_writer.interface.writeAll(
        \\    };
        \\}
        \\
    );
    try output_writer.interface.flush();
}

fn compileFile(source: [:0]const u8, scope: Indentation, output: *Io.Writer) !void {
    var file_decl_iter: Declaration.Iterator = .{ .tokenizer = .{
        .buffer = source,
        .index = 0,
    } };

    while (file_decl_iter.next()) |file_decl| switch (file_decl) {
        .syntax => |syntax_literal| {
            if (!mem.eql(u8, syntax_literal, supported_syntax_literal))
                process.fatal("Unsupported syntax: {s}", .{syntax_literal});
        },
        .package => {},
        .@"enum" => |@"enum"| {
            try printEnum(&@"enum", scope, output);
        },
        .message => |message| {
            try printMessage(&message, scope, output);
        },
    };
}

fn printEnum(e: *const Enum, outer_indent: Indentation, writer: *Io.Writer) !void {
    try writer.print("{f}pub const {s} = enum(i32) {{\n", .{ outer_indent, e.name });

    const inner_indent = outer_indent.increment();
    try writer.print("{f}pub const init: @This() = @fromBackingInt(0);\n", .{inner_indent});
    try writer.print("{f}pub const Decoded = @This();\n", .{inner_indent});

    var enum_fields = e.iterateFields();
    while (enum_fields.next()) |enum_field| {
        try writer.print(
            "{f}{s} = {s},\n",
            .{ inner_indent, enum_field.name, enum_field.value },
        );
    }

    try writer.print("{f}}};\n", .{outer_indent});
}

fn printMessage(
    message: *const Message,
    outer_indent: Indentation,
    writer: *Io.Writer,
) !void {
    try writer.print("{f}pub const {s} = struct {{\n", .{ outer_indent, message.name });

    const encodeable_indent = outer_indent.increment();
    try writer.print("{f}pub const message_name = {q};\n", .{ encodeable_indent, message.name });

    try printCmdIdDeclaration(message, encodeable_indent, writer);
    try printEncodeableFieldsOf(message, encodeable_indent, writer);
    try printXorMapping(message, encodeable_indent, writer);
    try printOneofMapping(message, encodeable_indent, writer);
    try printFieldNumberEnum(message, encodeable_indent, writer);
    try printDecodeableStructOf(message, encodeable_indent, writer);
    try printEncodingMapping(message, encodeable_indent, writer);

    try writer.print("{f}}};\n", .{outer_indent});
}

fn printCmdIdDeclaration(
    message: *const Message,
    message_field_indent: Indentation,
    writer: *Io.Writer,
) !void {
    var seen_once: bool = false;
    var options = message.iterateOptions();

    while (options.next()) |option| {
        if (!mem.eql(u8, option.name, "cmd_id")) continue;

        if (seen_once) process.fatal(
            "duplicated option {q} in message {q}",
            .{ option.name, message.name },
        );

        seen_once = true;

        try writer.print(
            "{f}pub const cmd_id: u16 = {s};\n",
            .{ message_field_indent, option.value },
        );
    }
}

fn printXorMapping(
    message: *const Message,
    message_indent: Indentation,
    writer: *Io.Writer,
) !void {
    try writer.print("{f}pub const xor_by_field = struct {{\n", .{message_indent});

    const field_indent = message_indent.increment();
    var fields = message.iterateFields();
    while (fields.next()) |field| {
        const xor = field.xor orelse continue;
        try writer.print(
            "{f}pub const @{q}: u31 = {s};\n",
            .{ field_indent, field.name, xor },
        );
    }

    try writer.print("{f}}};\n", .{message_indent});
}

fn printEncodeableFieldsOf(
    message: *const Message,
    message_field_indent: Indentation,
    writer: *Io.Writer,
) !void {
    var message_fields = message.iterateFields();
    while (message_fields.next()) |field| {
        try writer.print("{f}@{q}: ", .{ message_field_indent, field.name });

        switch (field.type) {
            .singular => |singular| {
                if (singular.isPrimitive())
                    try writer.print("{f}", .{singular})
                else
                    try writer.print("?{s}", .{singular.ident});

                try writer.print(" = {s},\n", .{singular.defaultValue()});
            },
            .repeated => |repeated| {
                try writer.print("[]const {f} = &.{{}},\n", .{repeated});
            },
            .map => |map| {
                try writer.print("[]const KeyValue({f}, {f}) = &.{{}},\n", .{ map.key, map.value });
            },
        }
    }

    var message_oneofs = message.iterateOneofs();
    while (message_oneofs.next()) |oneof| {
        try writer.print(
            "{f}@{q}: ?union(enum) {{\n",
            .{ message_field_indent, oneof.name },
        );

        const oneof_field_indent = message_field_indent.increment();
        var oneof_fields = oneof.iterateFields();
        while (oneof_fields.next()) |oneof_field| {
            try writer.print("{f}@{q}: ", .{ oneof_field_indent, oneof_field.name });

            if (oneof_field.type_name.isPrimitive())
                try writer.print("{f},\n", .{oneof_field.type_name})
            else
                try writer.print("{s},\n", .{oneof_field.type_name.ident});
        }

        try writer.print("{f}}} = null,\n", .{message_field_indent});
    }
}

fn printOneofMapping(
    message: *const Message,
    message_field_indent: Indentation,
    writer: *Io.Writer,
) !void {
    try writer.print("{f}pub const oneof_by_field = struct {{\n", .{message_field_indent});

    var message_oneofs = message.iterateOneofs();
    while (message_oneofs.next()) |oneof| {
        const decl_indent = message_field_indent.increment();
        var oneof_fields = oneof.iterateFields();

        while (oneof_fields.next()) |field| {
            try writer.print(
                "{f}pub const @{q} = {q};\n",
                .{ decl_indent, field.name, oneof.name },
            );
        }
    }

    try writer.print("{f}}};\n", .{message_field_indent});
}

fn printFieldNumberEnum(
    message: *const Message,
    message_field_indent: Indentation,
    writer: *Io.Writer,
) !void {
    try writer.print("{f}pub const FieldNumber = enum(u29) {{\n", .{message_field_indent});

    const enum_field_indent = message_field_indent.increment();
    var message_fields = message.iterateFields();
    while (message_fields.next()) |field| {
        try writer.print(
            "{f}@{q} = {s},\n",
            .{ enum_field_indent, field.name, field.number },
        );
    }

    var message_oneofs = message.iterateOneofs();
    while (message_oneofs.next()) |oneof| {
        var oneof_fields = oneof.iterateFields();

        while (oneof_fields.next()) |field| {
            try writer.print(
                "{f}@{q} = {s},\n",
                .{ enum_field_indent, field.name, field.number },
            );
        }
    }

    try writer.print("{f}_,\n", .{enum_field_indent});
    try writer.print("{f}}};\n", .{message_field_indent});
}

fn printDecodeableStructOf(
    message: *const Message,
    encodeable_indent: Indentation,
    writer: *Io.Writer,
) !void {
    try writer.print("{f}pub const Decoded = struct {{\n", .{encodeable_indent});

    const decodeable_indent = encodeable_indent.increment();
    try writer.print("{f}pub const Parent = {s};\n", .{ decodeable_indent, message.name });
    try writer.print("{f}pub const init: @This() = .{{}};\n", .{decodeable_indent});

    var message_fields = message.iterateFields();
    while (message_fields.next()) |field| {
        try writer.print("{f}@{q}: ", .{ decodeable_indent, field.name });

        switch (field.type) {
            .singular => |singular| {
                if (singular.isPrimitive())
                    try writer.print("{f}", .{singular})
                else
                    try writer.print("?{s}.Decoded", .{singular.ident});

                try writer.print(" = {s},\n", .{singular.defaultValue()});
            },
            .repeated => |repeated| {
                if (repeated.isPrimitive())
                    try writer.print("Iterator({f}) = .empty,\n", .{repeated})
                else
                    try writer.print("Iterator({s}.Decoded) = .empty,\n", .{repeated.ident});
            },
            .map => |map| {
                if (map.value.isPrimitive())
                    try writer.print(
                        "Iterator(KeyValue({f}, {f}).Decoded) = .empty,\n",
                        .{ map.key, map.value },
                    )
                else
                    try writer.print(
                        "Iterator(KeyValue({f}, ?{s}.Decoded).Decoded) = .empty,\n",
                        .{ map.key, map.value.ident },
                    );
            },
        }
    }

    var message_oneofs = message.iterateOneofs();
    while (message_oneofs.next()) |oneof| {
        try writer.print(
            "{f}@{q}: ?union(enum) {{\n",
            .{ decodeable_indent, oneof.name },
        );

        const oneof_field_indent = decodeable_indent.increment();
        var oneof_fields = oneof.iterateFields();
        while (oneof_fields.next()) |oneof_field| {
            try writer.print("{f}@{q}: ", .{ oneof_field_indent, oneof_field.name });

            if (oneof_field.type_name.isPrimitive())
                try writer.print("{f},\n", .{oneof_field.type_name})
            else
                try writer.print("{s}.Decoded,\n", .{oneof_field.type_name.ident});
        }

        try writer.print("{f}}} = null,\n", .{decodeable_indent});
    }

    try writer.print("{f}}};\n", .{encodeable_indent});
}

fn printEncodingMapping(
    message: *const Message,
    message_field_indent: Indentation,
    writer: *Io.Writer,
) !void {
    try writer.print("{f}pub const encoding_by_field = struct {{\n", .{message_field_indent});

    const decl_indent = message_field_indent.increment();
    var message_fields = message.iterateFields();
    while (message_fields.next()) |field| {
        const encoding = switch (field.type) {
            .singular => |singular| if (singular.isZigZagEncoded())
                "zig_zag"
            else
                "normal",
            .repeated, .map => "normal",
        };

        try writer.print(
            "{f}pub const @{q}: Encoding = .{s};\n",
            .{ decl_indent, field.name, encoding },
        );
    }

    var message_oneofs = message.iterateOneofs();
    while (message_oneofs.next()) |oneof| {
        var oneof_fields = oneof.iterateFields();

        while (oneof_fields.next()) |field| {
            const encoding = if (field.type_name.isZigZagEncoded()) "zig_zag" else "normal";

            try writer.print(
                "{f}pub const @{q}: Encoding = .{s};\n",
                .{ decl_indent, field.name, encoding },
            );
        }
    }

    try writer.print("{f}}};\n", .{message_field_indent});
}

const Indentation = enum(u16) {
    top_level = 0,
    _,

    const spaces = 4;

    fn increment(i: Indentation) Indentation {
        return @fromBackingInt(@backingInt(i) + 1);
    }

    pub fn format(i: Indentation, writer: *Io.Writer) !void {
        try writer.splatByteAll(' ', @backingInt(i) * spaces);
    }
};

const Declaration = union(enum) {
    syntax: []const u8,
    package: []const u8,
    @"enum": Enum,
    message: Message,

    const Iterator = struct {
        tokenizer: Tokenizer,

        pub fn next(it: *Iterator) ?Declaration {
            const t = &it.tokenizer;
            const first = t.next();

            switch (first.kind) {
                .eof => return null,
                .keyword_syntax => {
                    _ = expect(t, .equals);
                    const quoted = expect(t, .quoted);
                    _ = expect(t, .semi);

                    return .{ .syntax = quoted.get(t.buffer) };
                },
                .keyword_package => {
                    const ident = expect(t, .ident);
                    _ = expect(t, .semi);

                    return .{ .package = ident.get(t.buffer) };
                },
                .keyword_enum => {
                    const name = expect(t, .ident).get(t.buffer);
                    _ = expect(t, .l_brace);

                    defer skipBraced(t);
                    return .{ .@"enum" = .{ .name = name, .contents = t.* } };
                },
                .keyword_message => {
                    const name = expect(t, .ident).get(t.buffer);
                    _ = expect(t, .l_brace);

                    defer skipBraced(t);
                    return .{ .message = .{ .name = name, .contents = t.* } };
                },
                else => unexpectedToken(first, t),
            }
        }
    };
};

const Enum = struct {
    name: []const u8,
    /// Tokenizer state at the beginning of the enum, right after opening l_brace.
    contents: Tokenizer,

    const Field = struct {
        name: []const u8,
        value: []const u8,

        const Iterator = struct {
            tokenizer: Tokenizer,

            pub fn next(it: *Enum.Field.Iterator) ?Field {
                const t = &it.tokenizer;
                const name_or_end = t.next();

                switch (name_or_end.kind) {
                    .r_brace => return null,
                    .ident => {
                        _ = expect(t, .equals);
                        const value = expect(t, .number);
                        _ = expect(t, .semi);

                        return .{
                            .name = name_or_end.get(t.buffer),
                            .value = value.get(t.buffer),
                        };
                    },
                    else => unexpectedToken(name_or_end, t),
                }
            }
        };
    };

    pub fn iterateFields(@"enum": *const Enum) Enum.Field.Iterator {
        return .{ .tokenizer = @"enum".contents };
    }
};

const Message = struct {
    name: []const u8,
    /// Tokenizer state at the beginning of the message, right after opening l_brace.
    contents: Tokenizer,

    const Field = struct {
        type: Type,
        name: []const u8,
        number: []const u8,
        xor: ?[]const u8,

        pub const Iterator = struct {
            tokenizer: Tokenizer,

            pub fn next(it: *Iterator) ?Message.Field {
                const t = &it.tokenizer;
                const field_type = Type.next(t) orelse return null;

                const name = expect(t, .ident);
                _ = expect(t, .equals);
                const number = expect(t, .number);

                const semi_or_option_start = t.next();
                const xor: ?[]const u8 = switch (semi_or_option_start.kind) {
                    .semi => null,
                    .l_bracket => option: {
                        const option_name = expect(t, .ident).get(t.buffer);
                        if (!mem.eql(u8, option_name, "xor"))
                            process.fatal("unsupported field option {q}", .{option_name});

                        _ = expect(t, .equals);
                        const value = expect(t, .number).get(t.buffer);

                        _ = expect(t, .r_bracket);
                        _ = expect(t, .semi);

                        break :option value;
                    },
                    else => unexpectedToken(semi_or_option_start, t),
                };

                return .{
                    .type = field_type,
                    .name = name.get(t.buffer),
                    .number = number.get(t.buffer),
                    .xor = xor,
                };
            }
        };
    };

    const Oneof = struct {
        name: []const u8,
        contents: Tokenizer,

        const Field = struct {
            /// All oneof fields are singular
            type_name: Type.Name,
            name: []const u8,
            number: []const u8,

            pub const Iterator = struct {
                tokenizer: Tokenizer,

                pub fn next(it: *Message.Oneof.Field.Iterator) ?Message.Oneof.Field {
                    const t = &it.tokenizer;
                    const type_name_or_end = t.next();

                    switch (type_name_or_end.kind) {
                        .r_brace => return null,
                        .ident => {
                            const type_name = type_name_or_end.get(t.buffer);
                            const name = expect(t, .ident).get(t.buffer);
                            _ = expect(t, .equals);
                            const number = expect(t, .number).get(t.buffer);
                            _ = expect(t, .semi);

                            return .{
                                .type_name = .{ .ident = type_name },
                                .name = name,
                                .number = number,
                            };
                        },
                        else => unexpectedToken(type_name_or_end, t),
                    }
                }
            };
        };

        const Iterator = struct {
            tokenizer: Tokenizer,

            pub fn next(it: *Message.Oneof.Iterator) ?Message.Oneof {
                const t = &it.tokenizer;
                var first = t.next();

                first: switch (first.kind) {
                    .r_brace => return null,
                    .keyword_option => {
                        _ = expect(t, .ident);
                        _ = expect(t, .equals);
                        const value = t.next();
                        switch (value.kind) {
                            .number, .ident, .quoted => {},
                            else => unexpectedToken(value, t),
                        }
                        _ = expect(t, .semi);

                        first = t.next();
                        continue :first first.kind;
                    },
                    .ident, .keyword_repeated, .keyword_map => {
                        // A regular field. Skip to the next semicolon.
                        var skipped = t.next();
                        skip: switch (skipped.kind) {
                            .semi => {},
                            .eof, .invalid => unexpectedToken(skipped, t),
                            else => {
                                skipped = t.next();
                                continue :skip skipped.kind;
                            },
                        }

                        first = t.next();
                        continue :first first.kind;
                    },
                    .keyword_oneof => {
                        const name = expect(t, .ident).get(t.buffer);
                        _ = expect(t, .l_brace);

                        defer skipBraced(t);
                        return .{ .name = name, .contents = t.* };
                    },
                    else => unexpectedToken(first, t),
                }
            }
        };

        pub fn iterateFields(oneof: *const Oneof) Message.Oneof.Field.Iterator {
            return .{ .tokenizer = oneof.contents };
        }
    };

    pub const Option = struct {
        name: []const u8,
        value: []const u8,

        pub const Iterator = struct {
            tokenizer: Tokenizer,

            pub fn next(it: *Iterator) ?Option {
                const t = &it.tokenizer;
                var first = t.next();

                first: switch (first.kind) {
                    .r_brace => return null,
                    .keyword_option => {
                        const name = expect(t, .ident).get(t.buffer);
                        _ = expect(t, .equals);
                        const value = expect(t, .number).get(t.buffer);
                        _ = expect(t, .semi);

                        return .{ .name = name, .value = value };
                    },
                    .ident, .keyword_repeated, .keyword_map => {
                        // A regular field. Skip to the next semicolon.
                        var skipped = t.next();
                        skip: switch (skipped.kind) {
                            .semi => {},
                            .eof, .invalid => unexpectedToken(skipped, t),
                            else => {
                                skipped = t.next();
                                continue :skip skipped.kind;
                            },
                        }

                        first = t.next();
                        continue :first first.kind;
                    },
                    .keyword_oneof => {
                        _ = expect(t, .ident);
                        _ = expect(t, .l_brace);

                        skipBraced(t);
                        first = t.next();
                        continue :first first.kind;
                    },
                    else => unexpectedToken(first, t),
                }
            }
        };
    };

    pub fn iterateFields(message: *const Message) Message.Field.Iterator {
        return .{ .tokenizer = message.contents };
    }

    pub fn iterateOneofs(message: *const Message) Message.Oneof.Iterator {
        return .{ .tokenizer = message.contents };
    }

    pub fn iterateOptions(message: *const Message) Message.Option.Iterator {
        return .{ .tokenizer = message.contents };
    }
};

const Type = union(enum) {
    singular: Name,
    repeated: Name,
    map: struct {
        key: Name,
        value: Name,
    },

    const Name = struct {
        ident: []const u8,

        const primitives: std.StaticStringMap([]const u8) = .initComptime(&.{
            .{ "bool", "bool" },
            .{ "int32", "i32" },
            .{ "uint32", "u32" },
            .{ "int64", "i64" },
            .{ "uint64", "u64" },
            .{ "sint32", "i32" },
            .{ "sint64", "i64" },
            .{ "float", "f32" },
            .{ "double", "f64" },
            .{ "bytes", "[]const u8" },
            .{ "string", "[]const u8" },
        });

        const default_values: std.StaticStringMap([]const u8) = .initComptime(&.{
            .{ "bool", "false" },
            .{ "int32", "0" },
            .{ "uint32", "0" },
            .{ "int64", "0" },
            .{ "uint64", "0" },
            .{ "sint32", "0" },
            .{ "sint64", "0" },
            .{ "float", "0" },
            .{ "double", "0" },
            .{ "bytes", "&.{}" },
            .{ "string", "&.{}" },
        });

        const zig_zag_encoded: std.StaticStringMap(void) = .initComptime(&.{
            .{"sint32"}, .{"sint64"},
        });

        fn isPrimitive(name: Name) bool {
            return primitives.get(name.ident) != null;
        }

        fn isZigZagEncoded(name: Name) bool {
            return zig_zag_encoded.get(name.ident) != null;
        }

        fn defaultValue(name: Name) []const u8 {
            return default_values.get(name.ident) orelse "null";
        }

        /// Formats as a zig type.
        pub fn format(name: Name, writer: *Io.Writer) !void {
            try writer.writeAll(primitives.get(name.ident) orelse name.ident);
        }
    };

    /// Skips any oneofs.
    fn next(t: *Tokenizer) ?Type {
        var first = t.next();

        first: switch (first.kind) {
            .ident => return .{ .singular = .{
                .ident = first.get(t.buffer),
            } },
            .keyword_repeated => {
                const name = expect(t, .ident);
                return .{ .repeated = .{ .ident = name.get(t.buffer) } };
            },
            .keyword_map => {
                _ = expect(t, .l_triangle);
                const key = expect(t, .ident);
                _ = expect(t, .comma);
                const value = expect(t, .ident);
                _ = expect(t, .r_triangle);

                return .{ .map = .{
                    .key = .{ .ident = key.get(t.buffer) },
                    .value = .{ .ident = value.get(t.buffer) },
                } };
            },
            .keyword_oneof, .keyword_enum, .keyword_message => {
                _ = expect(t, .ident);
                _ = expect(t, .l_brace);
                skipBraced(t);

                first = t.next();
                continue :first first.kind;
            },
            .keyword_option => {
                _ = expect(t, .ident);
                _ = expect(t, .equals);
                const value = t.next();
                switch (value.kind) {
                    .number, .ident, .quoted => {},
                    else => unexpectedToken(value, t),
                }
                _ = expect(t, .semi);

                first = t.next();
                continue :first first.kind;
            },
            .r_brace => return null,
            else => unexpectedToken(first, t),
        }
    }
};

/// Skip all of the contents inside of braces. Assuming opening brace already consumed.
fn skipBraced(t: *Tokenizer) void {
    var depth: u32 = 1;

    while (depth != 0) {
        const token = t.next();
        switch (token.kind) {
            .l_brace => depth += 1,
            .r_brace => depth -= 1,
            .eof, .invalid => unexpectedToken(token, t),
            else => {},
        }
    }
}

fn expect(tokenizer: *Tokenizer, kind: Token.Kind) Token {
    const token = tokenizer.next();
    if (token.kind != kind) unexpectedToken(token, tokenizer);

    return token;
}

fn unexpectedToken(token: Token, tokenizer: *const Tokenizer) noreturn {
    const displacement: Displacement = .of(token, tokenizer.buffer);
    process.fatal("{f}: unexpected token {t}", .{ displacement, token.kind });
}

const Displacement = struct {
    line: usize,
    char: usize,

    pub fn of(token: Token, buffer: [:0]const u8) Displacement {
        const line = mem.countScalar(u8, buffer[0..token.start], '\n') + 1;
        const last_newline_index = mem.findScalarLast(u8, buffer[0..token.start], '\n') orelse 0;
        const char = token.start - last_newline_index;

        return .{ .line = line, .char = char };
    }

    pub fn format(displacement: *const Displacement, writer: *Io.Writer) !void {
        try writer.print("{d}:{d}", .{ displacement.line, displacement.char });
    }
};

const Token = struct {
    start: u32,
    end: u32,
    kind: Kind,

    const Kind = enum {
        invalid,
        eof,

        keyword_syntax,
        keyword_package,
        keyword_enum,
        keyword_message,
        keyword_oneof,
        keyword_repeated,
        keyword_map,
        keyword_option,

        semi,
        comma,
        equals,
        l_brace,
        r_brace,
        l_triangle,
        r_triangle,
        l_bracket,
        r_bracket,

        quoted,
        ident,
        number,
    };

    const keywords: std.StaticStringMap(Kind) = .initComptime(&.{
        .{ "syntax", .keyword_syntax },
        .{ "package", .keyword_package },
        .{ "enum", .keyword_enum },
        .{ "message", .keyword_message },
        .{ "oneof", .keyword_oneof },
        .{ "repeated", .keyword_repeated },
        .{ "map", .keyword_map },
        .{ "option", .keyword_option },
    });

    fn get(token: *const Token, buffer: [:0]const u8) []const u8 {
        return buffer[token.start..token.end];
    }
};

const Tokenizer = struct {
    buffer: [:0]const u8,
    index: u32,

    pub fn next(t: *Tokenizer) Token {
        var result: Token = .{
            .start = t.index,
            .end = t.index,
            .kind = .invalid,
        };

        const State = enum {
            start,
            saw_one_slash,
            comment_line,
            word,
            number,
            quoted,
        };

        state: switch (State.start) {
            .start => switch (t.buffer[t.index]) {
                0 => {
                    result.kind = .eof;
                },
                ' ', '\r', '\n', '\t' => {
                    t.index += 1;
                    result.start = t.index;
                    continue :state .start;
                },
                '/' => {
                    t.index += 1;
                    continue :state .saw_one_slash;
                },
                ';' => {
                    t.index += 1;
                    result.kind = .semi;
                },
                ',' => {
                    t.index += 1;
                    result.kind = .comma;
                },
                '=' => {
                    t.index += 1;
                    result.kind = .equals;
                },
                '{' => {
                    t.index += 1;
                    result.kind = .l_brace;
                },
                '}' => {
                    t.index += 1;
                    result.kind = .r_brace;
                },
                '<' => {
                    t.index += 1;
                    result.kind = .l_triangle;
                },
                '>' => {
                    t.index += 1;
                    result.kind = .r_triangle;
                },
                '[' => {
                    t.index += 1;
                    result.kind = .l_bracket;
                },
                ']' => {
                    t.index += 1;
                    result.kind = .r_bracket;
                },
                'A'...'Z', 'a'...'z', '_', '.' => {
                    t.index += 1;
                    continue :state .word;
                },
                '-', '0'...'9' => {
                    t.index += 1;
                    continue :state .number;
                },
                '"' => {
                    t.index += 1;
                    continue :state .quoted;
                },
                else => {
                    result.kind = .invalid;
                },
            },
            .saw_one_slash => switch (t.buffer[t.index]) {
                '/' => {
                    t.index += 1;
                    result.start = t.index;
                    continue :state .comment_line;
                },
                else => {
                    t.index += 1;
                    result.kind = .invalid;
                },
            },
            .comment_line => switch (t.buffer[t.index]) {
                0 => result.kind = .invalid,
                '\n' => {
                    t.index += 1;
                    result.start = t.index;
                    continue :state .start;
                },
                else => {
                    t.index += 1;
                    result.start = t.index;
                    continue :state .comment_line;
                },
            },
            .word => switch (t.buffer[t.index]) {
                'A'...'Z', 'a'...'z', '0'...'9', '_', '.' => {
                    t.index += 1;
                    continue :state .word;
                },
                else => {
                    result.end = t.index;

                    const string = t.buffer[result.start..result.end];
                    result.kind = Token.keywords.get(string) orelse .ident;
                },
            },
            .number => switch (t.buffer[t.index]) {
                '0'...'9' => {
                    t.index += 1;
                    continue :state .number;
                },
                else => {
                    result.kind = .number;
                },
            },
            .quoted => switch (t.buffer[t.index]) {
                0 => result.kind = .invalid,
                '"' => {
                    result.kind = .quoted;
                    t.index += 1;
                },
                else => {
                    t.index += 1;
                    continue :state .quoted;
                },
            },
        }

        result.end = t.index;
        return result;
    }
};
