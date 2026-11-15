const std = @import("std");

const bounded = @import("bounded");

const xml = @import("xml.zig");

const CentralDirectoryFileHeader = std.zip.CentralDirectoryFileHeader;
const CompressionMethod = std.zip.CompressionMethod;
const EndRecord = std.zip.EndRecord;
const LocalFileHeader = std.zip.LocalFileHeader;
const Reader = std.Io.Reader;
const assert = std.debug.assert;

pub const ArchiveError = error{
    ArchiveMalformed,
    ArchiveUnsupported,
    ChecksumMismatch,
    MemberMissing,
};

pub const CapacityError = error{
    CellsExhausted,
    MembersExhausted,
    SheetsExhausted,
    StringsExhausted,
    TextExhausted,
};

pub const SheetError = ArchiveError || CapacityError || xml.DecodeError || xml.Error || error{
    SheetMalformed,
    SheetMissing,
};

pub const Row = []const []const u8;

pub const Text = bounded.BufferType(text_bytes_max);

pub const Scratch = struct {
    window: [std.compress.flate.max_window_len]u8,
    xml: [member_bytes_max]u8,
};

pub const Member = struct {
    compressed_size: u32,
    compression_method: CompressionMethod,
    crc32: u32,
    local_header_offset: u32,
    name: []const u8,
    uncompressed_size: u32,
};

pub const Archive = struct {
    bytes: []const u8,
    members: bounded.ArrayType(Member, member_count_max),

    pub fn open(archive: *Archive, bytes: []const u8) (ArchiveError || CapacityError)!void {
        assert(bytes.len <= std.math.maxInt(u32));

        const end_record = try end_record_find(bytes);
        if (end_record.need_zip64()) return error.ArchiveUnsupported;
        if (end_record.record_count_total > member_count_max) return error.MembersExhausted;

        archive.bytes = bytes;
        archive.members = .empty;

        var offset: u32 = end_record.central_directory_offset;

        for (0..end_record.record_count_total) |_| {
            const member = archive.members.push_slot_assume_capacity();

            offset = try member_read(bytes, offset, member);
        }

        assert(archive.members.count == end_record.record_count_total);
        assert(offset <= bytes.len);
    }

    pub fn member_find(archive: *const Archive, name: []const u8) ?*const Member {
        assert(name.len > 0);
        assert(archive.members.count <= member_count_max);

        for (archive.members.slice()) |*member| {
            if (std.mem.eql(u8, member.name, name)) return member;
        }

        return null;
    }

    pub fn read(
        archive: *const Archive,
        scratch: *Scratch,
        name: []const u8,
    ) ArchiveError![]const u8 {
        assert(name.len > 0);
        assert(archive.members.count > 0);

        const member = archive.member_find(name) orelse return error.MemberMissing;
        if (member.uncompressed_size > scratch.xml.len) return error.ArchiveUnsupported;

        const compressed = try archive.member_bytes(member);
        const target = scratch.xml[0..member.uncompressed_size];

        switch (member.compression_method) {
            .store => {
                if (compressed.len != target.len) return error.ArchiveMalformed;

                @memcpy(target, compressed);
            },
            .deflate => {
                var input = Reader.fixed(compressed);
                var decompress = std.compress.flate.Decompress.init(&input, .raw, &scratch.window);

                decompress.reader.readSliceAll(target) catch return error.ArchiveMalformed;
            },
            else => return error.ArchiveUnsupported,
        }

        if (std.hash.Crc32.hash(target) != member.crc32) return error.ChecksumMismatch;

        return target;
    }

    fn member_bytes(archive: *const Archive, member: *const Member) ArchiveError![]const u8 {
        assert(member.name.len > 0);
        assert(archive.bytes.len <= std.math.maxInt(u32));

        const offset = member.local_header_offset;
        const header = try header_read(LocalFileHeader, archive.bytes, offset);

        if (!std.mem.eql(u8, &header.signature, &std.zip.local_file_header_sig)) {
            return error.ArchiveMalformed;
        }

        const start = offset + @sizeOf(LocalFileHeader) + header.filename_len + header.extra_len;
        const end = start + member.compressed_size;

        if (end > archive.bytes.len) return error.ArchiveMalformed;

        return archive.bytes[start..end];
    }
};

pub const Location = struct {
    name: []const u8,
    path: []const u8,
};

pub const Workbook = struct {
    archive: Archive,
    shared_strings: bounded.ArrayType([]const u8, shared_string_count_max),
    sheets: bounded.ArrayType(Location, sheet_count_max),

    pub fn open(
        workbook: *Workbook,
        bytes: []const u8,
        scratch: *Scratch,
        text: *Text,
    ) SheetError!void {
        assert(bytes.len > 0);
        assert(text.count() <= text_bytes_max);

        try workbook.archive.open(bytes);

        workbook.shared_strings = .empty;
        workbook.sheets = .empty;

        try workbook.shared_strings_load(scratch, text);
        try workbook.sheets_load(scratch, text);

        assert(workbook.sheets.count > 0);
    }

    pub fn sheet_path(workbook: *const Workbook, name: []const u8) ?[]const u8 {
        assert(name.len > 0);
        assert(workbook.sheets.count > 0);

        for (workbook.sheets.slice()) |location| {
            if (std.mem.eql(u8, location.name, name)) return location.path;
        }

        return null;
    }

    pub fn rows(
        workbook: *const Workbook,
        scratch: *Scratch,
        text: *Text,
        name: []const u8,
    ) SheetError!Rows {
        assert(name.len > 0);
        assert(text.count() <= text_bytes_max);

        const path = workbook.sheet_path(name) orelse return error.SheetMissing;
        const source = try workbook.archive.read(scratch, path);

        return .{
            .cell = .empty,
            .cells = undefined,
            .column = 0,
            .kind = .literal,
            .parser = .init(source),
            .shared_strings = workbook.shared_strings.slice(),
            .state = .outside_cell,
            .text = text,
            .width = 0,
        };
    }

    fn shared_strings_load(workbook: *Workbook, scratch: *Scratch, text: *Text) SheetError!void {
        assert(workbook.shared_strings.count == 0);
        assert(workbook.archive.members.count > 0);

        const read = workbook.archive.read(scratch, shared_strings_path);

        const source = read catch |err| switch (err) {
            error.MemberMissing => return,
            else => return err,
        };

        var parser: xml.Parser = .init(source);
        var item_start: ?u32 = null;
        var capturing = false;

        for (0..source.len + 1) |_| {
            switch (try parser.next()) {
                .end => break,
                .open => |element| {
                    const name = element.local_name();

                    if (std.mem.eql(u8, name, "si")) {
                        item_start = text.count();

                        if (element.self_closing) {
                            try workbook.shared_string_push(text, &item_start);
                        }
                    } else if (std.mem.eql(u8, name, "t")) {
                        capturing = item_start != null and !element.self_closing;
                    } else {}
                },
                .close => |raw| {
                    const name = xml.local(raw);

                    if (std.mem.eql(u8, name, "t")) capturing = false;

                    if (std.mem.eql(u8, name, "si")) {
                        try workbook.shared_string_push(text, &item_start);
                    }
                },
                .text => |raw| if (capturing) try text_decode(text, raw),
            }
        }

        assert(item_start == null);
    }

    fn shared_string_push(workbook: *Workbook, text: *Text, item_start: *?u32) CapacityError!void {
        assert(text.count() <= text_bytes_max);

        const start = item_start.* orelse return;

        item_start.* = null;

        if (workbook.shared_strings.full()) return error.StringsExhausted;

        workbook.shared_strings.push_slot_assume_capacity().* = text.slice()[start..];
    }

    fn sheets_load(workbook: *Workbook, scratch: *Scratch, text: *Text) SheetError!void {
        assert(workbook.sheets.count == 0);
        assert(text.count() <= text_bytes_max);

        var relationships: bounded.ArrayType(Location, sheet_count_max) = .empty;

        const relationships_source = try workbook.archive.read(scratch, relationships_path);

        var elements: xml.ElementIterator = .{
            .name = "Relationship",
            .parser = .init(relationships_source),
        };

        for (0..relationships_source.len + 1) |_| {
            const element = switch (try elements.next()) {
                .element => |element| element,
                .end => break,
            };

            const attributes = try element.attribute_set();
            const id = attributes.value_local("Id") orelse return error.ArchiveMalformed;
            const target = attributes.value_local("Target") orelse return error.ArchiveMalformed;

            if (relationships.full()) return error.SheetsExhausted;

            relationships.push_slot_assume_capacity().* = .{
                .name = try text_store(text, id),
                .path = try target_normalize(text, try text_store(text, target)),
            };
        }

        const source = try workbook.archive.read(scratch, workbook_path);

        var sheets: xml.ElementIterator = .{ .name = "sheet", .parser = .init(source) };

        for (0..source.len + 1) |_| {
            const element = switch (try sheets.next()) {
                .element => |element| element,
                .end => break,
            };

            const attributes = try element.attribute_set();
            const name = attributes.value_local("name") orelse return error.ArchiveMalformed;
            const id = attributes.value_local("id") orelse return error.ArchiveMalformed;

            const path = location_find(relationships.slice(), id) orelse
                return error.ArchiveMalformed;

            if (workbook.sheets.full()) return error.SheetsExhausted;

            workbook.sheets.push_slot_assume_capacity().* = .{
                .name = try text_store(text, name),
                .path = path,
            };
        }

        if (workbook.sheets.count == 0) return error.ArchiveMalformed;
    }
};

pub const Rows = struct {
    cell: bounded.BufferType(cell_bytes_max),
    cells: [row_cells_max][]const u8,
    column: u32,
    kind: Kind,
    parser: xml.Parser,
    shared_strings: []const []const u8,
    state: State,
    text: *Text,
    width: u32,

    const Kind = enum {
        inline_string,
        literal,
        shared,
    };

    pub const Next = union(enum) {
        end,
        row: Row,
    };

    const State = enum {
        capturing,
        in_cell,
        outside_cell,
    };

    pub fn next(rows: *Rows) SheetError!Next {
        assert(rows.width <= row_cells_max);
        assert(rows.parser.index <= rows.parser.source.len);

        for (0..rows.parser.source.len + 1) |_| {
            const finished = switch (try rows.parser.next()) {
                .end => {
                    assert(rows.state == .outside_cell);

                    return .end;
                },
                .open => |element| try rows.open(&element),
                .close => |raw| try rows.close(xml.local(raw)),
                .text => |raw| finished: {
                    if (rows.state == .capturing) try text_decode(&rows.cell, raw);

                    break :finished false;
                },
            };

            if (finished) return .{ .row = rows.cells[0..rows.width] };
        }

        unreachable;
    }

    fn open(rows: *Rows, element: *const xml.Element) SheetError!bool {
        const name = element.local_name();

        assert(name.len > 0);

        if (std.mem.eql(u8, name, "row")) {
            rows.width = 0;

            return element.self_closing;
        }

        if (std.mem.eql(u8, name, "c")) {
            try rows.cell_start(element);

            return false;
        }

        if (element.self_closing) return false;
        if (rows.state != .in_cell) return false;
        if (std.mem.eql(u8, name, "v")) rows.state = .capturing;
        if (std.mem.eql(u8, name, "t")) rows.state = .capturing;

        return false;
    }

    fn close(rows: *Rows, name: []const u8) SheetError!bool {
        assert(name.len > 0);

        if (text_element_is(name)) {
            if (rows.state == .capturing) rows.state = .in_cell;

            return false;
        }

        if (std.mem.eql(u8, name, "c")) {
            try rows.cell_finish();

            return false;
        }

        assert(rows.state != .capturing);

        return std.mem.eql(u8, name, "row");
    }

    fn cell_start(rows: *Rows, element: *const xml.Element) SheetError!void {
        assert(element.name.len > 0);

        const attributes = try element.attribute_set();
        const reference = attributes.value_local("r") orelse return error.SheetMalformed;
        const kind = attributes.value_local("t") orelse "";

        rows.column = try column_of(reference);
        rows.cell.clear();
        rows.state = .in_cell;

        rows.kind = if (std.mem.eql(u8, kind, "s"))
            .shared
        else if (std.mem.eql(u8, kind, "inlineStr"))
            .inline_string
        else
            .literal;

        if (rows.column >= row_cells_max) return error.CellsExhausted;
        if (element.self_closing) try rows.cell_finish();
    }

    fn cell_finish(rows: *Rows) SheetError!void {
        assert(rows.column < row_cells_max);

        if (rows.state == .outside_cell) return;

        const raw = std.mem.trim(u8, rows.cell.slice(), whitespace_bytes);

        const resolved = switch (rows.kind) {
            .shared => try rows.shared_string(raw),
            .inline_string, .literal => try text_copy(rows.text, raw),
        };

        for (rows.width..rows.column) |gap| rows.cells[gap] = "";

        rows.cells[rows.column] = resolved;
        rows.width = @max(rows.width, rows.column + 1);
        rows.state = .outside_cell;

        assert(rows.width <= row_cells_max);
    }

    fn shared_string(rows: *const Rows, raw: []const u8) SheetError![]const u8 {
        assert(raw.len <= cell_bytes_max);

        if (raw.len == 0) return "";

        const index = std.fmt.parseInt(u32, raw, 10) catch return error.SheetMalformed;
        if (index >= rows.shared_strings.len) return error.SheetMalformed;

        return std.mem.trim(u8, rows.shared_strings[index], whitespace_bytes);
    }
};

pub const cell_bytes_max: u32 = 4096;
pub const member_bytes_max: u32 = 4 * 1024 * 1024;
pub const member_count_max: u32 = 64;
pub const row_cells_max: u32 = 64;
pub const shared_string_count_max: u32 = 16 * 1024;
pub const sheet_count_max: u32 = 16;
pub const text_bytes_max: u32 = 2 * 1024 * 1024;

const column_letters_max: u32 = 3;
const comment_bytes_max: u32 = std.math.maxInt(u16);
const package_prefix = "xl/";
const relationships_path = "xl/_rels/workbook.xml.rels";
const shared_strings_path = "xl/sharedStrings.xml";
const whitespace_bytes = " \t\n\r\x0b\x0c";
const workbook_path = "xl/workbook.xml";

comptime {
    assert(std.mem.startsWith(u8, shared_strings_path, package_prefix));
    assert(std.mem.startsWith(u8, workbook_path, package_prefix));
    assert(std.mem.startsWith(u8, relationships_path, package_prefix));
}

fn text_decode(text: anytype, raw: []const u8) (CapacityError || xml.DecodeError)!void {
    comptime assert(@typeInfo(@TypeOf(text)) == .pointer);
    assert(raw.len <= xml.source_bytes_max);

    const unused = text.array.slice_unused();

    if (unused.len < raw.len) return error.TextExhausted;

    const decoded = try xml.decode(raw, unused);

    text.array.resize_assume_capacity(text.array.count + @as(u32, @intCast(decoded.len)));

    assert(decoded.len <= raw.len);
}

fn text_store(text: *Text, raw: []const u8) (CapacityError || xml.DecodeError)![]const u8 {
    assert(raw.len <= xml.source_bytes_max);

    const start = text.count();

    try text_decode(text, raw);

    const result = text.slice()[start..];

    assert(result.len <= raw.len);

    return result;
}

fn text_copy(text: *Text, bytes: []const u8) CapacityError![]const u8 {
    assert(bytes.len <= cell_bytes_max);

    const start = text.count();

    text.push(bytes) catch return error.TextExhausted;

    const result = text.slice()[start..];

    assert(std.mem.eql(u8, result, bytes));

    return result;
}

fn target_normalize(text: *Text, target: []const u8) SheetError![]const u8 {
    assert(text.count() >= target.len);

    if (target.len == 0) return error.ArchiveMalformed;
    if (target[0] == '/') return std.mem.trimStart(u8, target, "/");
    if (std.mem.startsWith(u8, target, package_prefix)) return target;

    const start = text.count();

    text.print(package_prefix ++ "{s}", .{target}) catch return error.TextExhausted;

    const result = text.slice()[start..];

    assert(result.len == target.len + package_prefix.len);

    return result;
}

fn location_find(locations: []const Location, id: []const u8) ?[]const u8 {
    assert(id.len > 0);
    assert(locations.len <= sheet_count_max);

    for (locations) |location| {
        if (std.mem.eql(u8, location.name, id)) return location.path;
    }

    return null;
}

fn column_of(reference: []const u8) SheetError!u32 {
    assert(reference.len <= cell_bytes_max);

    if (reference.len == 0) return error.SheetMalformed;

    var index: u32 = 0;
    var letters: u32 = 0;

    for (reference) |byte| {
        const value: u32 = switch (byte) {
            'A'...'Z' => byte - 'A' + 1,
            'a'...'z' => byte - 'a' + 1,
            else => break,
        };

        index = index * 26 + value;
        letters += 1;

        if (letters > column_letters_max) return error.SheetMalformed;
    }

    if (letters == 0) return error.SheetMalformed;

    assert(index >= 1);

    return index - 1;
}

fn member_read(bytes: []const u8, offset: u32, member: *Member) ArchiveError!u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    if (offset > bytes.len) return error.ArchiveMalformed;

    const header = try header_read(CentralDirectoryFileHeader, bytes, offset);

    if (!std.mem.eql(u8, &header.signature, &std.zip.central_file_header_sig)) {
        return error.ArchiveMalformed;
    }

    const name_start = offset + @sizeOf(CentralDirectoryFileHeader);
    const name_end = name_start + header.filename_len;

    if (name_end > bytes.len) return error.ArchiveMalformed;

    member.* = .{
        .compressed_size = header.compressed_size,
        .compression_method = header.compression_method,
        .crc32 = header.crc32,
        .local_header_offset = header.local_file_header_offset,
        .name = bytes[name_start..name_end],
        .uncompressed_size = header.uncompressed_size,
    };

    const result = name_end + header.extra_len + header.comment_len;

    if (result > bytes.len) return error.ArchiveMalformed;

    assert(result > offset);

    return result;
}

fn header_read(comptime Header: type, bytes: []const u8, offset: u32) ArchiveError!Header {
    comptime assert(@typeInfo(Header).@"struct".layout == .@"extern");
    assert(bytes.len <= std.math.maxInt(u32));

    if (offset > bytes.len) return error.ArchiveMalformed;
    if (offset + @sizeOf(Header) > bytes.len) return error.ArchiveMalformed;

    var reader = Reader.fixed(bytes[offset..]);

    return reader.takeStruct(Header, .little) catch error.ArchiveMalformed;
}

fn end_record_find(bytes: []const u8) ArchiveError!EndRecord {
    assert(bytes.len <= std.math.maxInt(u32));

    const size = @sizeOf(EndRecord);

    if (bytes.len < size) return error.ArchiveMalformed;

    const start: u32 = @intCast(bytes.len - size);
    const span: u32 = @min(start, comment_bytes_max);

    for (0..span + 1) |back| {
        const offset: u32 = start - @as(u32, @intCast(back));
        const signature = bytes[offset..][0..std.zip.end_record_sig.len];

        if (!std.mem.eql(u8, signature, &std.zip.end_record_sig)) continue;

        const record = try header_read(EndRecord, bytes, offset);

        if (offset + size + record.comment_len == bytes.len) return record;
    }

    return error.ArchiveMalformed;
}

fn text_element_is(name: []const u8) bool {
    assert(name.len > 0);
    assert(name.len <= xml.source_bytes_max);

    if (std.mem.eql(u8, name, "v")) return true;
    return std.mem.eql(u8, name, "t");
}
