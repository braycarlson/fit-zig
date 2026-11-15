const std = @import("std");

const assert = std.debug.assert;

comptime {
    _ = @import("base_type.zig");
    _ = @import("corpus_tests.zig");
    _ = @import("crc.zig");
    _ = @import("decoder.zig");
    _ = @import("decoder_fuzz.zig");
    _ = @import("encoder.zig");
    _ = @import("epoch.zig");
    _ = @import("exporter.zig");
    _ = @import("fit.zig");
    _ = @import("fuzz_tests.zig");
    _ = @import("garmin.zig");
    _ = @import("generator/emit.zig");
    _ = @import("generator/main.zig");
    _ = @import("generator/model.zig");
    _ = @import("generator/render.zig");
    _ = @import("generator/sheets.zig");
    _ = @import("generator/xlsx.zig");
    _ = @import("generator/xml.zig");
    _ = @import("main.zig");
    _ = @import("parser.zig");
    _ = @import("platform.zig");
    _ = @import("profile.zig");
    _ = @import("round_trip_fuzz.zig");
    _ = @import("round_trip_tests.zig");
    _ = @import("testing/fuzz.zig");
    _ = @import("tidy.zig");
    _ = @import("value.zig");
}

test "every public declaration compiles" {
    const fit = @import("fit.zig");

    const Decoder = fit.DecoderType(.{
        .accumulator_count_max = 1,
        .developer_field_count_max = 1,
        .field_count_max = 1,
        .text_bytes_max = 1,
    });

    comptime assert(@hasDecl(fit, "DecoderType"));
    comptime assert(@hasDecl(fit, "Encoder"));
    comptime assert(@hasDecl(fit, "Parser"));
    comptime assert(@hasDecl(fit, "message"));

    std.testing.refAllDecls(fit);
    std.testing.refAllDecls(fit.limits);
    std.testing.refAllDecls(fit.Decoder);
    std.testing.refAllDecls(fit.Decoder.Value.Array);
    std.testing.refAllDecls(fit.Encoder);
    std.testing.refAllDecls(fit.Parser);
    std.testing.refAllDecls(fit.Parser.DataMessage);
    std.testing.refAllDecls(fit.Parser.DeveloperFields);
    std.testing.refAllDecls(fit.Parser.Fields);
    std.testing.refAllDecls(Decoder);

    std.testing.refAllDecls(fit.StorageType(.{
        .accumulator_count_max = 1,
        .developer_field_count_max = 1,
        .field_count_max = 1,
        .text_bytes_max = 1,
    }));
}

test "the generator model mirrors the runtime profile structs field for field" {
    const model = @import("generator/model.zig");
    const profile = @import("profile.zig");

    try same_shape_expect(model.Component, profile.Component);
    try same_shape_expect(model.Field, profile.Field);
    try same_shape_expect(model.Subfield, profile.Subfield);
}

fn same_shape_expect(comptime Generated: type, comptime Runtime: type) !void {
    const generated = @typeInfo(Generated).@"struct".field_names;
    const runtime = @typeInfo(Runtime).@"struct".field_names;

    try std.testing.expectEqual(runtime.len, generated.len);

    inline for (generated, runtime) |left, right| {
        try std.testing.expectEqualStrings(right, left);
    }
}
