const std = @import("std");

const bounded = @import("bounded");

const exporter = @import("exporter.zig");
const fit = @import("fit.zig");
const platform = @import("platform.zig");

const Writer = std.Io.Writer;
const assert = std.debug.assert;

const Field = fit.Decoder.Field;
const Message = fit.Decoder.Message;
const Value = fit.Decoder.Value;

const Command = struct {
    global_number: u16,
    mode: Mode,
    path: []const u8,
};

const Mode = enum {
    channels,
    csv,
    dump,
    json,
};

const State = struct {
    bytes: [file_bytes_max + 1]u8,
    columns: exporter.Columns,
    decoder: exporter.Decoder,
    stdout: [stdout_buffer_bytes]u8,
    tally: Tally,
};

const Tally = bounded.ArrayType(TallyEntry, tally_entry_count_max);

const TallyEntry = struct {
    count: u32,
    global_number: u16,
    name: []const u8,
};

const array_print_max: u32 = 8;
const file_bytes_max: u32 = 64 * 1024 * 1024;
const global_number_default: u16 = 20;
const global_number_invalid: u16 = 0xFFFF;
const hex_print_max: u32 = 16;
const stdout_buffer_bytes: u32 = 8192;
const tally_entry_count_max: u32 = 256;
const usage = "usage: fit <file.fit> [--json | --csv [global] | --ch233]\n";

comptime {
    assert(file_bytes_max <= fit.limits.source_bytes_max);
    assert(global_number_default != global_number_invalid);
}

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len < std.math.maxInt(u32));
    assert(file_bytes_max > 0);

    const arguments = try init.minimal.args.toSlice(init.arena.allocator());

    const state = try init.gpa.create(State);
    defer init.gpa.destroy(state);

    var stdout_writer: std.Io.File.Writer = .initStreaming(
        platform.stdout_file(),
        init.io,
        &state.stdout,
    );

    const out = &stdout_writer.interface;

    const command = command_parse(arguments) orelse {
        try out.writeAll(usage);
        try out.flush();

        return error.ArgumentsInvalid;
    };

    const bytes = try std.Io.Dir.cwd().readFile(init.io, command.path, &state.bytes);
    if (bytes.len > file_bytes_max) return error.FileTooLarge;

    run(state, &command, bytes, out) catch |err| switch (err) {
        error.WriteFailed => if (!platform.stdout_closed(&stdout_writer)) return err,
        else => return err,
    };
}

fn command_parse(arguments: []const []const u8) ?Command {
    assert(arguments.len < std.math.maxInt(u32));
    assert(usage.len > 0);

    if (arguments.len < 2) return null;
    if (arguments.len > 4) return null;
    if (arguments[1].len == 0) return null;

    const flag = if (arguments.len > 2) arguments[2] else "";
    const mode = mode_parse(flag) orelse return null;

    var result: Command = .{
        .global_number = global_number_default,
        .mode = mode,
        .path = arguments[1],
    };

    if (arguments.len == 4) {
        if (mode != .csv) return null;

        const global_number = std.fmt.parseInt(u16, arguments[3], 10) catch return null;
        if (global_number == global_number_invalid) return null;

        result.global_number = global_number;
    }

    assert(result.path.len > 0);

    return result;
}

fn mode_parse(flag: []const u8) ?Mode {
    assert(flag.len < std.math.maxInt(u32));

    if (flag.len == 0) return .dump;
    if (std.mem.eql(u8, flag, "--json")) return .json;
    if (std.mem.eql(u8, flag, "--csv")) return .csv;
    if (std.mem.eql(u8, flag, "--ch233")) return .channels;
    return null;
}

fn run(state: *State, command: *const Command, bytes: []const u8, out: *Writer) !void {
    assert(bytes.len <= file_bytes_max);
    assert(command.path.len > 0);

    switch (command.mode) {
        .channels => try exporter.write_channels(&state.decoder, bytes, out),
        .csv => {
            state.columns.init();

            try exporter.write_csv(
                &state.decoder,
                &state.columns,
                bytes,
                out,
                command.global_number,
            );
        },
        .dump => try dump(state, command, bytes, out),
        .json => try exporter.write_json(&state.decoder, bytes, out),
    }

    try out.flush();
}

fn dump(state: *State, command: *const Command, bytes: []const u8, out: *Writer) !void {
    assert(command.path.len > 0);
    assert(bytes.len <= file_bytes_max);

    try state.decoder.init(bytes);
    try summary_print(out, command, bytes, state.decoder.header());

    state.tally = .empty;

    var message_count: u32 = 0;

    for (0..fit.limits.message_count_max) |_| {
        const message = switch (try state.decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        const seen_first = tally_add(&state.tally, &message);

        message_count += 1;

        if (seen_first) try message_print(out, &message);
    }

    try histogram_print(out, &state.tally);

    try out.print("\ntotal: {d} messages across {d} types\n", .{
        message_count,
        state.tally.count,
    });

    assert(message_count >= state.tally.count);
}

fn tally_add(tally: *Tally, message: *const Message) bool {
    assert(message.name.len > 0);
    assert(tally.count <= tally_entry_count_max);

    for (tally.slice_mutable()) |*entry| {
        if (entry.global_number == message.global_number) {
            entry.count += 1;

            assert(entry.count >= 2);

            return false;
        }
    }

    if (tally.full()) return false;

    tally.push_slot_assume_capacity().* = .{
        .count = 1,
        .global_number = message.global_number,
        .name = message.name,
    };

    assert(tally.count <= tally_entry_count_max);

    return true;
}

fn summary_print(
    out: *Writer,
    command: *const Command,
    bytes: []const u8,
    header: fit.Parser.Header,
) !void {
    assert(command.path.len > 0);
    assert(bytes.len >= header.size_bytes);

    const protocol_major = header.protocol_version >> 4;
    const protocol_minor = header.protocol_version & 0x0F;
    const checksum_valid = if (fit.verify_checksum(bytes)) |_| true else |_| false;

    try out.print("file:     {s}\n", .{command.path});
    try out.print("size:     {d} bytes\n", .{bytes.len});
    try out.print("protocol: {d}.{d}\n", .{ protocol_major, protocol_minor });
    try out.print("profile:  {d}\n", .{header.profile_version});
    try out.print("crc:      {s}\n\n", .{if (checksum_valid) "ok" else "MISMATCH"});
}

fn message_print(out: *Writer, message: *const Message) !void {
    assert(message.name.len > 0);
    assert(out.buffer.len > 0);

    try out.print("[{s}]  global {d}", .{ message.name, message.global_number });

    if (message.timestamp) |timestamp| {
        try out.writeAll("  @ ");
        try datetime_print(out, timestamp);
    }

    try out.writeAll("\n");

    for (message.fields) |*field| try field_print(out, field);

    try out.writeAll("\n");
}

fn field_print(out: *Writer, field: *const Field) !void {
    assert(field.name.len > 0);
    assert(out.buffer.len > 0);

    try out.print("  {s:<26} = ", .{field.name});

    if (date_value(field)) |seconds| {
        try datetime_print(out, seconds);
    } else {
        try value_print(out, &field.value, field.units);
    }

    try out.writeAll("\n");
}

fn date_value(field: *const Field) ?u32 {
    assert(field.name.len > 0);

    const date = std.mem.eql(u8, field.type_name, "date_time") or
        std.mem.eql(u8, field.type_name, "local_date_time");

    if (!date) return null;
    if (field.value != .unsigned) return null;
    if (field.value.unsigned >= fit_timestamp_invalid) return null;

    const result: u32 = @intCast(field.value.unsigned);

    assert(result != fit_timestamp_invalid);

    return result;
}

fn value_print(out: *Writer, value: *const Value, units: []const u8) !void {
    assert(out.buffer.len > 0);
    assert(units.len <= fit.limits.field_count_max);

    switch (value.*) {
        .none => try out.writeAll("(invalid)"),
        .integer => |number| try out.print("{d}", .{number}),
        .unsigned => |number| try out.print("{d}", .{number}),
        .real => |number| try out.print("{d:.3}", .{number}),
        .string => |text| try out.print("\"{s}\"", .{text}),
        .enumeration => |name| try out.writeAll(name),
        .bytes => |bytes| try hex_print(out, bytes),
        .integer_array, .real_array => |*array| try array_print(out, value.*, array),
    }

    switch (value.*) {
        .integer, .unsigned, .real, .integer_array, .real_array => {
            if (units.len > 0) try out.print(" {s}", .{units});
        },
        .none, .string, .enumeration, .bytes => {},
    }
}

fn array_print(out: *Writer, value: Value, array: *const Value.Array) !void {
    assert(value == .integer_array or value == .real_array);
    assert(array.count() <= fit.limits.field_count_max);

    const count = array.count();
    const shown = @min(count, array_print_max);

    try out.writeAll("[");

    for (0..shown) |position| {
        const index: u32 = @intCast(position);

        if (index > 0) try out.writeAll(", ");

        switch (value) {
            .integer_array => try out.print("{d}", .{array.integer_of(index)}),
            .real_array => try out.print("{d:.3}", .{array.real_of(index)}),
            .none, .integer, .unsigned, .real, .string, .enumeration, .bytes => unreachable,
        }
    }

    if (count > shown) try out.writeAll(", ...");

    try out.writeAll("]");
}

fn hex_print(out: *Writer, bytes: []const u8) !void {
    assert(bytes.len <= fit.limits.field_count_max);
    assert(out.buffer.len > 0);

    const shown = @min(bytes.len, hex_print_max);

    for (bytes[0..shown]) |byte| try out.print("{x:0>2}", .{byte});

    if (bytes.len > shown) try out.writeAll("...");
}

fn datetime_print(out: *Writer, timestamp: u32) !void {
    assert(timestamp != fit_timestamp_invalid);
    assert(out.buffer.len > 0);

    const unix = fit.unix_seconds_of(timestamp) orelse unreachable;
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(unix) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    try out.print("{d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u16, month_day.day_index) + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    });
}

fn histogram_print(out: *Writer, tally: *Tally) !void {
    assert(tally.count <= tally_entry_count_max);
    assert(out.buffer.len > 0);

    try out.writeAll("messages by type (desc):\n");

    const entries = tally.slice_mutable();

    std.mem.sort(TallyEntry, entries, {}, count_greater);

    for (entries) |entry| {
        assert(entry.count >= 1);

        try out.print("  {s:<26} {d:>6}  (global {d})\n", .{
            entry.name,
            entry.count,
            entry.global_number,
        });
    }
}

fn count_greater(_: void, left: TallyEntry, right: TallyEntry) bool {
    assert(left.count >= 1);
    assert(right.count >= 1);

    return left.count > right.count;
}

const fit_timestamp_invalid: u32 = 0xFFFFFFFF;

test command_parse {
    const csv = command_parse(&.{ "fit", "a.fit", "--csv", "19" }) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(Mode.csv, csv.mode);
    try std.testing.expectEqual(@as(u16, 19), csv.global_number);
    try std.testing.expectEqualStrings("a.fit", csv.path);

    const dumped = command_parse(&.{ "fit", "a.fit" }) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(Mode.dump, dumped.mode);
    try std.testing.expectEqual(global_number_default, dumped.global_number);
    try std.testing.expect(command_parse(&.{"fit"}) == null);
    try std.testing.expect(command_parse(&.{ "fit", "a.fit", "--yaml" }) == null);
    try std.testing.expect(command_parse(&.{ "fit", "a.fit", "--json", "19" }) == null);
    try std.testing.expect(command_parse(&.{ "fit", "a.fit", "--csv", "65535" }) == null);
}
