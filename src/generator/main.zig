const std = @import("std");

const emit = @import("emit.zig");
const model_module = @import("model.zig");
const sheets_module = @import("sheets.zig");
const xlsx = @import("xlsx.zig");

const assert = std.debug.assert;

const Model = model_module.Model;
const Sheets = sheets_module.Sheets;

const Generator = struct {
    existing: [output_bytes_max + 1]u8,
    messages: [output_bytes_max]u8,
    model: Model,
    scratch: xlsx.Scratch,
    sheets: Sheets,
    sort: [sheets_module.value_count_max]sheets_module.NamedValue,
    text: xlsx.Text,
    types: [output_bytes_max]u8,
    workbook: xlsx.Workbook,
    workbook_bytes: [workbook_bytes_max + 1]u8,
};

const Mode = enum {
    check,
    write,
};

const Outputs = struct {
    messages: []const u8,
    types: []const u8,
};

const Paths = struct {
    messages: []const u8,
    types: []const u8,
    workbook: []const u8,
};

const Error = emit.Error || model_module.Error || sheets_module.Error || xlsx.SheetError;

const exit_failure: u8 = 1;
const exit_stale: u8 = 2;
const exit_success: u8 = 0;
const messages_sheet = "Messages";
const output_bytes_max: u32 = 2 * 1024 * 1024;
const types_sheet = "Types";
const usage = "usage: generator <check|write> <Profile.xlsx> <types.zig> <messages.zig>";
const workbook_bytes_max: u32 = 4 * 1024 * 1024;

comptime {
    assert(exit_failure != exit_success);
    assert(exit_stale != exit_failure);
    assert(!std.mem.eql(u8, types_sheet, messages_sheet));
}

pub fn main(init: std.process.Init) u8 {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(output_bytes_max > 0);

    const arguments = init.minimal.args.toSlice(init.arena.allocator()) catch {
        return failed("the arguments could not be read", .{});
    };

    if (arguments.len != 5) return failed(usage, .{});

    const mode = std.meta.stringToEnum(Mode, arguments[1]) orelse {
        return failed("the mode {s} is neither check nor write", .{arguments[1]});
    };

    const paths: Paths = .{
        .messages = arguments[4],
        .types = arguments[3],
        .workbook = arguments[2],
    };

    const generator = init.gpa.create(Generator) catch {
        return failed("the generator state could not be allocated", .{});
    };

    defer init.gpa.destroy(generator);

    return run(generator, init.io, mode, &paths);
}

fn run(generator: *Generator, io: std.Io, mode: Mode, paths: *const Paths) u8 {
    assert(paths.workbook.len > 0);
    assert(generator.workbook_bytes.len == workbook_bytes_max + 1);

    const cwd = std.Io.Dir.cwd();

    const workbook = cwd.readFile(io, paths.workbook, &generator.workbook_bytes) catch |err| {
        return failed("{s} could not be read: {t}", .{ paths.workbook, err });
    };

    if (workbook.len > workbook_bytes_max) return failed("{s} is too large", .{paths.workbook});

    const outputs = generate(generator, workbook) catch |err| {
        return failed("{s} could not be converted: {t}", .{ paths.workbook, err });
    };

    report(&generator.model);

    return switch (mode) {
        .check => check(generator, io, paths, &outputs),
        .write => write(io, paths, &outputs),
    };
}

fn generate(generator: *Generator, workbook: []const u8) Error!Outputs {
    assert(workbook.len > 0);
    assert(workbook.len <= workbook_bytes_max);

    generator.text = .empty;
    generator.sheets.init();

    try generator.workbook.open(workbook, &generator.scratch, &generator.text);

    var type_rows = try generator.workbook.rows(&generator.scratch, &generator.text, types_sheet);

    try rows_take(&type_rows, &generator.sheets, Sheets.type_row_take);

    var message_rows = try generator.workbook.rows(
        &generator.scratch,
        &generator.text,
        messages_sheet,
    );

    try rows_take(&message_rows, &generator.sheets, Sheets.message_row_take);
    try generator.sheets.messages_finish();
    try generator.model.resolve(&generator.sheets);

    var types: std.Io.Writer = .fixed(&generator.types);
    var messages: std.Io.Writer = .fixed(&generator.messages);

    try emit.types_write(&types, &generator.model, &generator.sort);
    try emit.messages_write(&messages, &generator.model);

    const result: Outputs = .{ .messages = messages.buffered(), .types = types.buffered() };

    assert(result.types.len > 0);
    assert(result.messages.len > 0);

    return result;
}

fn rows_take(
    rows: *xlsx.Rows,
    sheets: *Sheets,
    comptime take: fn (*Sheets, xlsx.Row) sheets_module.Error!void,
) Error!void {
    assert(rows.parser.source.len > 0);
    assert(sheets.types.count <= sheets_module.type_count_max);

    const header = try rows.next();

    if (header == .end) return;

    for (0..rows.parser.source.len) |_| {
        const row = switch (try rows.next()) {
            .end => return,
            .row => |row| row,
        };

        try take(sheets, row);
    }

    unreachable;
}

fn write(io: std.Io, paths: *const Paths, outputs: *const Outputs) u8 {
    assert(outputs.types.len > 0);
    assert(outputs.messages.len > 0);

    const cwd = std.Io.Dir.cwd();

    const files = [_]struct { []const u8, []const u8 }{
        .{ paths.types, outputs.types },
        .{ paths.messages, outputs.messages },
    };

    for (files) |file| {
        cwd.writeFile(io, .{ .sub_path = file[0], .data = file[1], .flags = .{} }) catch |err| {
            return failed("{s} could not be written: {t}", .{ file[0], err });
        };
    }

    return exit_success;
}

fn check(generator: *Generator, io: std.Io, paths: *const Paths, outputs: *const Outputs) u8 {
    assert(outputs.types.len > 0);
    assert(outputs.messages.len > 0);

    const files = [_]struct { []const u8, []const u8 }{
        .{ paths.types, outputs.types },
        .{ paths.messages, outputs.messages },
    };

    var stale = false;

    for (files) |file| {
        const existing = std.Io.Dir.cwd().readFile(io, file[0], &generator.existing) catch {
            std.debug.print("{s}: missing\n", .{file[0]});

            stale = true;

            continue;
        };

        if (std.mem.eql(u8, existing, file[1])) continue;

        std.debug.print("{s}: {d} bytes committed, {d} bytes generated\n", .{
            file[0],
            existing.len,
            file[1].len,
        });

        stale = true;
    }

    if (!stale) return exit_success;

    std.debug.print("run `zig build generate` to regenerate\n", .{});

    return exit_stale;
}

fn report(model: *const Model) void {
    assert(model.types.count > 0);
    assert(model.messages.count > 0);

    var values: u32 = 0;

    for (model.types.slice()) |table| values += @intCast(table.values.len);

    std.debug.print("types:    {d} ({d} named values)\n", .{ model.types.count, values });
    std.debug.print("messages: {d}\n", .{model.messages.count});
    std.debug.print("fields:   {d}\n", .{model.fields.count});
}

fn failed(comptime format: []const u8, arguments: anytype) u8 {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");
    assert(exit_failure != exit_success);

    std.debug.print("generator: " ++ format ++ "\n", arguments);

    return exit_failure;
}
