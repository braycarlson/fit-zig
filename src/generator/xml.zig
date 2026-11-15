const std = @import("std");

const assert = std.debug.assert;

pub const DecodeError = error{
    EntityUnsupported,
};

pub const Error = error{
    MarkupUnsupported,
    XMLMalformed,
};

pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

pub const Attributes = struct {
    index: u32,
    malformed: bool,
    remaining: u32,
    source: []const u8,

    pub fn init(source: []const u8) Attributes {
        assert(source.len <= source_bytes_max);

        return .{
            .index = 0,
            .malformed = false,
            .remaining = @intCast(source.len),
            .source = source,
        };
    }

    pub fn next(iterator: *Attributes) ?Attribute {
        assert(iterator.index <= iterator.source.len);
        assert(iterator.remaining <= iterator.source.len);

        if (iterator.malformed) return null;
        if (iterator.remaining == 0) return null;

        iterator.index = space_skip(iterator.source, iterator.index);

        if (iterator.index >= iterator.source.len) {
            iterator.remaining = 0;

            return null;
        }

        const parsed = attribute_parse(iterator.source, iterator.index) catch {
            iterator.malformed = true;

            return null;
        };

        assert(parsed.end > iterator.index);
        assert(parsed.end <= iterator.source.len);

        iterator.index = parsed.end;
        iterator.remaining = @intCast(iterator.source.len - parsed.end);

        return parsed.attribute;
    }
};

pub const AttributeSet = struct {
    source: []const u8,

    pub fn value(set: *const AttributeSet, name: []const u8) ?[]const u8 {
        assert(name.len > 0);
        assert(set.source.len <= source_bytes_max);

        var attributes: Attributes = .init(set.source);

        for (0..set.source.len + 1) |_| {
            const found = attributes.next() orelse break;

            if (std.mem.eql(u8, found.name, name)) return found.value;
        }

        assert(!attributes.malformed);

        return null;
    }

    pub fn value_local(set: *const AttributeSet, name: []const u8) ?[]const u8 {
        assert(name.len > 0);
        assert(std.mem.findScalar(u8, name, ':') == null);

        var attributes: Attributes = .init(set.source);

        for (0..set.source.len + 1) |_| {
            const found = attributes.next() orelse break;

            if (std.mem.eql(u8, local(found.name), name)) return found.value;
        }

        assert(!attributes.malformed);

        return null;
    }
};

pub const Element = struct {
    attributes: []const u8,
    name: []const u8,
    self_closing: bool,

    pub fn local_name(element: *const Element) []const u8 {
        assert(element.name.len > 0);
        assert(element.attributes.len <= source_bytes_max);

        return local(element.name);
    }

    pub fn attribute_set(element: *const Element) Error!AttributeSet {
        assert(element.name.len > 0);
        assert(element.attributes.len <= source_bytes_max);

        var attributes: Attributes = .init(element.attributes);

        for (0..element.attributes.len + 1) |_| {
            _ = attributes.next() orelse break;
        }

        if (attributes.malformed) return error.XMLMalformed;

        return .{ .source = element.attributes };
    }
};

pub const ElementIterator = struct {
    name: []const u8,
    parser: Parser,

    pub const Next = union(enum) {
        element: Element,
        end,
    };

    pub fn next(iterator: *ElementIterator) Error!Next {
        assert(iterator.name.len > 0);
        assert(iterator.parser.index <= iterator.parser.source.len);

        for (0..iterator.parser.source.len + 1) |_| {
            const element = switch (try iterator.parser.next()) {
                .close, .text => continue,
                .end => return .end,
                .open => |open| open,
            };

            if (std.mem.eql(u8, element.local_name(), iterator.name)) {
                return .{ .element = element };
            }
        }

        unreachable;
    }
};

pub const Event = union(enum) {
    close: []const u8,
    end,
    open: Element,
    text: []const u8,
};

pub const Parser = struct {
    index: u32,
    source: []const u8,

    pub fn init(source: []const u8) Parser {
        assert(source.len <= source_bytes_max);

        return .{ .index = 0, .source = source };
    }

    pub fn next(parser: *Parser) Error!Event {
        assert(parser.index <= parser.source.len);
        assert(parser.source.len <= source_bytes_max);

        for (0..parser.source.len + 1) |_| {
            if (parser.index == parser.source.len) return .end;

            const before = parser.index;

            if (parser.source[parser.index] != '<') return parser.text_take();
            if (parser.starts_with("</")) return try parser.close_take();
            if (parser.starts_with("<![CDATA[")) return error.MarkupUnsupported;

            if (parser.starts_with("<?")) {
                try parser.past_skip("?>");
            } else if (parser.starts_with("<!--")) {
                try parser.past_skip("-->");
            } else if (parser.starts_with("<!")) {
                try parser.past_skip(">");
            } else {
                return try parser.open_take();
            }

            assert(parser.index > before);
        }

        unreachable;
    }

    fn open_take(parser: *Parser) Error!Event {
        assert(parser.source[parser.index] == '<');

        const end = tag_end_find(parser.source, parser.index) orelse return error.XMLMalformed;
        const body = parser.source[parser.index + 1 .. end];

        parser.index = end + 1;

        if (body.len == 0) return error.XMLMalformed;

        const self_closing = body[body.len - 1] == '/';
        const inner = if (self_closing) body[0 .. body.len - 1] else body;
        const name_end = space_find(inner) orelse @as(u32, @intCast(inner.len));
        const name = inner[0..name_end];

        if (name.len == 0) return error.XMLMalformed;

        assert(parser.index <= parser.source.len);

        return .{ .open = .{
            .attributes = inner[name_end..],
            .name = name,
            .self_closing = self_closing,
        } };
    }

    fn close_take(parser: *Parser) Error!Event {
        assert(parser.starts_with("</"));

        const end = tag_end_find(parser.source, parser.index) orelse return error.XMLMalformed;
        const name = std.mem.trim(u8, parser.source[parser.index + 2 .. end], space_bytes);

        parser.index = end + 1;

        if (name.len == 0) return error.XMLMalformed;

        assert(parser.index <= parser.source.len);

        return .{ .close = name };
    }

    fn text_take(parser: *Parser) Event {
        assert(parser.source[parser.index] != '<');

        const start = parser.index;
        const found = std.mem.findScalarPos(u8, parser.source, start, '<');
        const end: u32 = if (found) |position| @intCast(position) else @intCast(parser.source.len);

        parser.index = end;

        assert(parser.index > start);

        return .{ .text = parser.source[start..end] };
    }

    fn past_skip(parser: *Parser, terminator: []const u8) Error!void {
        assert(terminator.len > 0);

        const before = parser.index;

        const found = std.mem.findPos(u8, parser.source, parser.index, terminator) orelse
            return error.XMLMalformed;

        parser.index = @intCast(found + terminator.len);

        assert(parser.index > before);
        assert(parser.index <= parser.source.len);
    }

    fn starts_with(parser: *const Parser, prefix: []const u8) bool {
        assert(prefix.len > 0);
        assert(parser.index <= parser.source.len);

        if (parser.index + prefix.len > parser.source.len) return false;
        return std.mem.eql(u8, parser.source[parser.index..][0..prefix.len], prefix);
    }
};

const Parsed = struct {
    attribute: Attribute,
    end: u32,
};

pub const source_bytes_max: u32 = 16 * 1024 * 1024;

const space_bytes = " \t\n\r";
const spaces = spaces_build();
const utf8_bytes_max: u32 = 4;

comptime {
    assert(source_bytes_max <= std.math.maxInt(u32));
    assert(space_bytes.len == 4);
}

pub fn decode(raw: []const u8, target: []u8) DecodeError![]const u8 {
    assert(target.len >= raw.len);
    assert(raw.len <= source_bytes_max);

    var count: u32 = 0;
    var index: u32 = 0;

    for (0..raw.len + 1) |_| {
        if (index == raw.len) break;

        if (raw[index] != '&') {
            target[count] = raw[index];
            count += 1;
            index += 1;

            continue;
        }

        const end = std.mem.findScalarPos(u8, raw, index, ';') orelse
            return error.EntityUnsupported;

        const written = try entity_decode(raw[index + 1 .. end], target[count..]);

        count += written;
        index = @intCast(end + 1);
    }

    assert(index == raw.len);
    assert(count <= raw.len);

    return target[0..count];
}

pub fn local(name: []const u8) []const u8 {
    assert(name.len > 0);
    assert(name.len <= source_bytes_max);

    const colon = std.mem.findScalar(u8, name, ':') orelse return name;

    return name[colon + 1 ..];
}

fn entity_decode(name: []const u8, target: []u8) DecodeError!u32 {
    assert(target.len >= name.len + 2);
    assert(name.len <= source_bytes_max);

    if (name.len == 0) return error.EntityUnsupported;

    const predefined = [_]struct { []const u8, u8 }{
        .{ "amp", '&' },
        .{ "apos", '\'' },
        .{ "gt", '>' },
        .{ "lt", '<' },
        .{ "quot", '"' },
    };

    for (predefined) |entry| {
        if (std.mem.eql(u8, name, entry[0])) {
            target[0] = entry[1];

            return 1;
        }
    }

    if (name[0] != '#') return error.EntityUnsupported;

    const hexadecimal = name.len > 1 and (name[1] == 'x' or name[1] == 'X');
    const digits = if (hexadecimal) name[2..] else name[1..];
    const base: u8 = if (hexadecimal) 16 else 10;

    if (digits.len == 0) return error.EntityUnsupported;

    const point = std.fmt.parseInt(u21, digits, base) catch return error.EntityUnsupported;

    const length = std.unicode.utf8Encode(point, target[0..utf8_bytes_max]) catch
        return error.EntityUnsupported;

    assert(length >= 1);
    assert(length <= name.len + 2);

    return length;
}

fn attribute_parse(source: []const u8, start: u32) Error!Parsed {
    assert(start < source.len);
    assert(!spaces.isSet(source[start]));

    var index = start;

    for (source[start..]) |byte| {
        if (spaces.isSet(byte)) break;
        if (byte == '=') break;

        index += 1;
    }

    const name = source[start..index];

    if (name.len == 0) return error.XMLMalformed;

    index = space_skip(source, index);

    if (index >= source.len) return error.XMLMalformed;
    if (source[index] != '=') return error.XMLMalformed;

    index = space_skip(source, index + 1);

    if (index >= source.len) return error.XMLMalformed;

    const quote = source[index];

    if (quote != '"') {
        if (quote != '\'') return error.XMLMalformed;
    }

    const value_start = index + 1;

    const value_end = std.mem.findScalarPos(u8, source, value_start, quote) orelse
        return error.XMLMalformed;

    assert(value_start <= value_end);
    assert(source[value_end] == quote);

    return .{
        .attribute = .{ .name = name, .value = source[value_start..value_end] },
        .end = @intCast(value_end + 1),
    };
}

fn tag_end_find(source: []const u8, start: u32) ?u32 {
    assert(start < source.len);
    assert(source[start] == '<');

    var quote: u8 = 0;

    for (source[start..], start..) |byte, index| {
        if (quote != 0) {
            if (byte == quote) quote = 0;

            continue;
        }

        if (byte == '>') {
            const result: u32 = @intCast(index);

            assert(source[result] == '>');

            return result;
        }

        if (byte == '"') quote = byte;
        if (byte == '\'') quote = byte;
    }

    return null;
}

fn spaces_build() std.StaticBitSet(256) {
    assert(space_bytes.len == 4);

    var result: std.StaticBitSet(256) = .empty;

    for (space_bytes) |byte| result.set(byte);

    assert(result.count() == space_bytes.len);

    return result;
}

fn space_skip(source: []const u8, start: u32) u32 {
    assert(start <= source.len);

    var result = start;

    for (source[start..]) |byte| {
        if (!spaces.isSet(byte)) break;

        result += 1;
    }

    if (result < source.len) assert(!spaces.isSet(source[result]));

    return result;
}

fn space_find(source: []const u8) ?u32 {
    assert(source.len <= source_bytes_max);

    for (source, 0..) |byte, index| {
        if (spaces.isSet(byte)) {
            const result: u32 = @intCast(index);

            assert(result < source.len);

            return result;
        }
    }

    return null;
}

test Parser {
    var parser: Parser = .init("<x:row r=\"1\">hello</x:row>");

    const open = (try parser.next()).open;
    const attributes = try open.attribute_set();

    try std.testing.expectEqualStrings("x:row", open.name);
    try std.testing.expectEqualStrings("row", open.local_name());
    try std.testing.expectEqualStrings("1", attributes.value("r").?);
    try std.testing.expect(!open.self_closing);

    const text = (try parser.next()).text;
    const close = (try parser.next()).close;
    const end = try parser.next();

    try std.testing.expectEqualStrings("hello", text);
    try std.testing.expectEqualStrings("x:row", close);
    try std.testing.expect(end == .end);
}

test "the parser marks a self-closing element and reports no close" {
    var parser: Parser = .init("<c r=\"A1\" />");

    const open = (try parser.next()).open;
    const attributes = try open.attribute_set();
    const end = try parser.next();

    try std.testing.expect(open.self_closing);
    try std.testing.expectEqualStrings("A1", attributes.value("r").?);
    try std.testing.expect(end == .end);
}

test "the parser skips the declaration, comments, and the doctype" {
    var parser: Parser = .init("<?xml version=\"1.0\"?><!-- <fake> --><!DOCTYPE x><a/>");

    const open = (try parser.next()).open;
    const end = try parser.next();

    try std.testing.expectEqualStrings("a", open.name);
    try std.testing.expect(end == .end);
}

test "the parser keeps an unescaped angle bracket inside an attribute value" {
    var parser: Parser = .init("<a b=\"x>y\" c='1'>t</a>");

    const open = (try parser.next()).open;
    const attributes = try open.attribute_set();
    const text = (try parser.next()).text;

    try std.testing.expectEqualStrings("x>y", attributes.value("b").?);
    try std.testing.expectEqualStrings("1", attributes.value("c").?);
    try std.testing.expectEqualStrings("t", text);
}

test "an attribute lookup by local name ignores the namespace prefix" {
    var parser: Parser = .init("<sheet name=\"Types\" sheetId=\"1\" r:id=\"rId2\"/>");

    const open = (try parser.next()).open;
    const attributes = try open.attribute_set();

    try std.testing.expectEqualStrings("rId2", attributes.value_local("id").?);
    try std.testing.expectEqualStrings("Types", attributes.value_local("name").?);
    try std.testing.expect(attributes.value("id") == null);
    try std.testing.expect(attributes.value("missing") == null);
}

test Attributes {
    var parser: Parser = .init("<a one=\"1\" two=\"2\"/>");

    const open = (try parser.next()).open;

    var attributes: Attributes = .init(open.attributes);

    const first = attributes.next() orelse return error.TestUnexpectedResult;
    const second = attributes.next() orelse return error.TestUnexpectedResult;
    const third = attributes.next();

    try std.testing.expectEqualStrings("one", first.name);
    try std.testing.expectEqualStrings("1", first.value);
    try std.testing.expectEqualStrings("two", second.name);
    try std.testing.expectEqualStrings("2", second.value);
    try std.testing.expect(third == null);
    try std.testing.expect(!attributes.malformed);
}

test ElementIterator {
    const source =
        \\<?xml version="1.0"?><x:root><x:sheet name="Types" /><x:other />
        \\<x:sheet name="Messages" />text</x:root>
    ;

    var sheets: ElementIterator = .{ .name = "sheet", .parser = .init(source) };

    const first = try (try sheets.next()).element.attribute_set();
    const second = try (try sheets.next()).element.attribute_set();
    const end = try sheets.next();

    try std.testing.expectEqualStrings("Types", first.value_local("name").?);
    try std.testing.expectEqualStrings("Messages", second.value_local("name").?);
    try std.testing.expect(end == .end);
}

test decode {
    var target: [64]u8 = undefined;

    const predefined = try decode("a&amp;b&lt;c&gt;d&quot;e&apos;f", &target);

    try std.testing.expectEqualStrings("a&b<c>d\"e'f", predefined);
    try std.testing.expectEqualStrings("A", try decode("&#65;", &target));
    try std.testing.expectEqualStrings("A", try decode("&#x41;", &target));
    try std.testing.expectEqualStrings("\u{00e9}", try decode("&#xe9;", &target));
    try std.testing.expectEqualStrings("no entities here", try decode("no entities here", &target));
}

test "decode rejects an entity it does not know" {
    var target: [16]u8 = undefined;

    try std.testing.expectError(error.EntityUnsupported, decode("&nbsp;", &target));
    try std.testing.expectError(error.EntityUnsupported, decode("&amp", &target));
    try std.testing.expectError(error.EntityUnsupported, decode("&#zz;", &target));
}

test "the parser rejects markup outside the supported subset" {
    var cdata: Parser = .init("<a><![CDATA[x]]></a>");

    _ = try cdata.next();

    const cdata_event = cdata.next();

    try std.testing.expectError(error.MarkupUnsupported, cdata_event);

    var unterminated: Parser = .init("<a");
    var empty_tag: Parser = .init("<>");
    var empty_close: Parser = .init("</>");

    const unterminated_event = unterminated.next();
    const empty_tag_event = empty_tag.next();
    const empty_close_event = empty_close.next();

    try std.testing.expectError(error.XMLMalformed, unterminated_event);
    try std.testing.expectError(error.XMLMalformed, empty_tag_event);
    try std.testing.expectError(error.XMLMalformed, empty_close_event);
}

test "attribute parsing rejects a malformed attribute list" {
    var missing_value: Parser = .init("<a b/>");
    var unquoted: Parser = .init("<a b=1/>");

    const open = (try missing_value.next()).open;
    const bare = (try unquoted.next()).open;

    try std.testing.expectError(error.XMLMalformed, open.attribute_set());
    try std.testing.expectError(error.XMLMalformed, bare.attribute_set());
}
