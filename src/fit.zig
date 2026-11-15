const std = @import("std");

const base_type_module = @import("base_type.zig");
const decoder_module = @import("decoder.zig");
const encoder_module = @import("encoder.zig");
const epoch = @import("epoch.zig");
const parser_module = @import("parser.zig");
const profile = @import("profile.zig");

const assert = std.debug.assert;

pub const BaseType = base_type_module.BaseType;
pub const Capacity = decoder_module.Capacity;
pub const CapacityError = Decoder.CapacityError || Encoder.CapacityError;
pub const ChecksumError = parser_module.ChecksumError;
pub const Decoder = decoder_module.Decoder;
pub const DecoderType = decoder_module.DecoderType;
pub const Diagnostic = parser_module.Diagnostic;
pub const Encoder = encoder_module.Encoder;
pub const Error = CapacityError || ChecksumError || SyntaxError || ValueError;
pub const Parser = parser_module.Parser;
pub const Storage = decoder_module.Storage;
pub const StorageType = decoder_module.StorageType;
pub const SyntaxError = Parser.SyntaxError;
pub const ValueError = Encoder.ValueError;

pub const timestamp_field_number = parser_module.timestamp_field_number;
pub const unix_seconds_of = epoch.unix_seconds_of;
pub const verify_checksum = parser_module.verify_checksum;

pub fn message(err: Error) []const u8 {
    assert(@errorName(err).len > 0);
    assert(limits.field_count_max > 0);

    const result: []const u8 = switch (err) {
        error.AccumulatorsExhausted => "the accumulated fields do not fit the capacity",
        error.BaseTypeUnknown => "a field definition names a base type FIT does not define",
        error.BufferExhausted => "the encoded file does not fit the buffer",
        error.ChainedFileCountExceeded => "more chained files hold no message than the limit",
        error.ChecksumMismatch => "the checksum does not match the file",
        error.DescriptionsExhausted => "the developer field descriptions do not fit the capacity",
        error.FieldCountExceeded => "a message holds more fields than a definition can declare",
        error.FieldsExhausted => "a message decodes to more fields than the capacity",
        error.HeaderSizeInvalid => "the file header is neither 12 nor 14 bytes",
        error.LocalTypeUndefined => "a data message uses a local message type with no definition",
        error.SignatureInvalid => "the file header does not carry the .FIT signature",
        error.StringTooLong => "a string is longer than a field can hold",
        error.TextExhausted => "the developer field names and units do not fit the capacity",
        error.Truncated => "the file ends inside a header, a record, or its checksum",
    };

    assert(result.len > 0);

    return result;
}

pub const limits = struct {
    pub const accumulator_count_max: u32 = profile.accumulator_count_max;
    pub const chained_file_count_max: u32 = parser_module.chained_file_count_max;
    pub const field_bytes_max: u32 = parser_module.field_bytes_max;
    pub const field_count_max: u32 = parser_module.field_count_max;
    pub const message_count_max: u32 = parser_module.message_count_max;
    pub const source_bytes_max: u32 = parser_module.source_bytes_max;
    pub const string_bytes_max: u32 = encoder_module.string_bytes_max;
};

test message {
    const names = @typeInfo(Error).error_set.error_names.?;

    inline for (names) |name| {
        const text = message(@field(Error, name));

        try std.testing.expect(text.len > 0);
        try std.testing.expect(std.mem.findScalar(u8, text, '\n') == null);
    }
}
