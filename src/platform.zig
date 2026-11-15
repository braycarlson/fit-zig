const builtin = @import("builtin");
const std = @import("std");

const assert = std.debug.assert;

pub const stdout_file = switch (builtin.target.os.tag) {
    .windows => stdout_file_windows,
    else => stdout_file_posix,
};

const unexpected_closes_stdout = switch (builtin.target.os.tag) {
    .windows => true,
    else => false,
};

pub fn stdout_closed(writer: *const std.Io.File.Writer) bool {
    assert(writer.interface.buffer.len > 0);

    const err = writer.err orelse return false;

    const result = switch (err) {
        error.BrokenPipe => true,
        error.Unexpected => unexpected_closes_stdout,
        else => false,
    };

    if (result) assert(writer.err != null);

    return result;
}

fn stdout_file_windows() std.Io.File {
    comptime assert(builtin.target.os.tag == .windows);

    var file = std.Io.File.stdout();

    file.flags.nonblocking = handle_is_asynchronous(file.handle);

    assert(file.handle != std.os.windows.INVALID_HANDLE_VALUE);

    return file;
}

fn stdout_file_posix() std.Io.File {
    comptime assert(builtin.target.os.tag != .windows);

    const file = std.Io.File.stdout();

    assert(file.handle >= 0);

    return file;
}

fn handle_is_asynchronous(handle: std.os.windows.HANDLE) bool {
    comptime assert(builtin.target.os.tag == .windows);

    const windows = std.os.windows;

    assert(handle != windows.INVALID_HANDLE_VALUE);

    var status_block: windows.IO_STATUS_BLOCK = undefined;
    var information: windows.FILE.MODE.INFORMATION = undefined;

    const status = windows.ntdll.NtQueryInformationFile(
        handle,
        &status_block,
        &information,
        @sizeOf(windows.FILE.MODE.INFORMATION),
        .Mode,
    );

    if (status != .SUCCESS) return false;
    return information.Mode.IO == .ASYNCHRONOUS;
}
