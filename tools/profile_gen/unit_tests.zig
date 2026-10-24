const std = @import("std");

const fit = @import("fit");
const model = @import("model.zig");

fn expect_same_shape(comptime Generated: type, comptime Runtime: type) !void {
    const generated = @typeInfo(Generated).@"struct".field_names;
    const runtime = @typeInfo(Runtime).@"struct".field_names;

    try std.testing.expectEqual(runtime.len, generated.len);

    inline for (generated, runtime) |left, right| {
        try std.testing.expectEqualStrings(right, left);
    }
}

test {
    _ = @import("model.zig");
    _ = @import("render.zig");
    _ = @import("sheets.zig");
    _ = @import("xlsx.zig");
    _ = @import("xml.zig");
}

test "the model mirrors the runtime profile structs field for field" {
    try expect_same_shape(model.FieldInfo, fit.profile.FieldInfo);
    try expect_same_shape(model.SubField, fit.profile.SubField);
    try expect_same_shape(model.Component, fit.profile.Component);
}
