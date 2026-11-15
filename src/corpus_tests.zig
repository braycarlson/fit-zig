const std = @import("std");

const fit = @import("fit.zig");
const profile = @import("profile.zig");

const assert = std.debug.assert;

const Decoder = fit.DecoderType(.{
    .accumulator_count_max = profile.accumulator_count_max,
    .developer_field_count_max = 256,
    .field_count_max = 1024,
    .text_bytes_max = 64 * 1024,
});

const State = struct {
    bytes: [file_bytes_max + 1]u8,
    decoder: Decoder,
};

const corpus_directory = ".data";
const file_bytes_max: u32 = 64 * 1024 * 1024;
const file_bytes_min: u32 = 14;
const file_count_max: u32 = 4096;

fn decode_all(decoder: *Decoder, bytes: []const u8) !u32 {
    assert(bytes.len <= file_bytes_max);
    assert(bytes.len >= file_bytes_min);

    try decoder.init(bytes);

    var result: u32 = 0;

    for (0..fit.limits.message_count_max) |_| {
        const message = switch (try decoder.next()) {
            .end => break,
            .message => |message| message,
        };

        assert(message.name.len > 0);

        result += 1;
    }

    assert(result <= bytes.len);

    return result;
}

test "every corpus file passes its checksum and decodes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var directory = std.Io.Dir.cwd().openDir(io, corpus_directory, .{
        .access_sub_paths = true,
        .follow_symlinks = true,
        .iterate = true,
    }) catch return error.SkipZigTest;

    defer directory.close(io);

    const state = try gpa.create(State);
    defer gpa.destroy(state);

    var walker = try directory.walk(gpa);
    defer walker.deinit();

    var checked: u32 = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.basename, ".fit")) continue;
        if (checked == file_count_max) break;

        const bytes = try entry.dir.readFile(io, entry.basename, &state.bytes);

        try std.testing.expect(bytes.len <= file_bytes_max);
        try fit.verify_checksum(bytes);
        try std.testing.expect(try decode_all(&state.decoder, bytes) > 0);

        checked += 1;
    }

    try std.testing.expect(checked > 0);
}
