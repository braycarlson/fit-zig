const std = @import("std");

const fit = @import("fit");

const assert = std.debug.assert;

const Decoder = fit.DecoderType(.{
    .accumulator_count_max = fit.limits.accumulator_count_max,
    .developer_field_count_max = 16,
    .field_count_max = 256,
    .text_bytes_max = 4096,
});

pub fn main() !void {
    assert(fit.limits.accumulator_count_max > 0);
    assert(fit.limits.field_count_max > 0);

    var buffer: [256]u8 = undefined;
    var encoder: fit.Encoder = undefined;

    encoder.init(&buffer);

    try encoder.write_message(&.{
        .fields = &.{
            .{ .number = 0, .value = .{ .enum_value = 4 } },
            .{ .number = 4, .value = .{ .uint32 = 1_000_000_000 } },
        },
        .global_number = 0,
    });

    try encoder.write_message(&.{
        .fields = &.{
            .{ .number = 253, .value = .{ .uint32 = 1_000_000_060 } },
            .{ .number = 3, .value = .{ .uint8 = 142 } },
            .{ .number = 6, .value = .{ .uint16 = 3050 } },
        },
        .global_number = 20,
    });

    const bytes = encoder.close();

    try fit.verify_checksum(bytes);

    var decoder: Decoder = undefined;

    decoder.init(bytes) catch |err| {
        const offset = decoder.diagnostic().offset;

        std.debug.print("{s} at byte {d}\n", .{ fit.message(err), offset });

        return err;
    };

    for (0..fit.limits.message_count_max) |_| {
        const found = decoder.next() catch |err| {
            const offset = decoder.diagnostic().offset;

            std.debug.print("{s} at byte {d}\n", .{ fit.message(err), offset });

            return err;
        };

        const message = switch (found) {
            .end => break,
            .message => |message| message,
        };

        std.debug.print("{s}\n", .{message.name});

        for (message.fields) |*field| field_print(field);
    }
}

fn field_print(field: *const fit.Decoder.Field) void {
    assert(field.name.len > 0);
    assert(field.units.len <= fit.limits.field_bytes_max);

    switch (field.value) {
        .enumeration => |name| std.debug.print("  {s} = {s}\n", .{ field.name, name }),
        .real => |number| std.debug.print("  {s} = {d} {s}\n", .{
            field.name,
            number,
            field.units,
        }),
        .unsigned => |number| std.debug.print("  {s} = {d}\n", .{ field.name, number }),
        .none, .integer, .string, .bytes, .integer_array, .real_array => {},
    }
}
