const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const posix = std.posix;

pub const escape_code = struct {
    pub const static = struct {
        pub const hide_cursor = "\x1b[?25l";
        pub const show_cursor = "\x1b[?25h";
        pub const clear_line_to_end = "\x1b[0K";
        pub const inverted_percent_sign = "\x1b[7m%\x1b[0m";
    };

    pub const Direction = enum(u2) {
        up,
        down,
        right,
        left,
    };

    pub fn move(dir: Direction, n: usize, w: *std.Io.Writer) !void {
        if (n == 0) return;

        try w.print("\x1b[{d}{c}", .{ n, @as(u8, 'A') + @intFromEnum(dir) });
    }
};

pub const CursorShape = enum(u3) {
    blinking_block = 1,
    steady_block,
    blinking_underline,
    steady_underline,
    blinking_bar,
    steady_bar,

    pub const base_fmt = "\x1b[{d} q";
    pub fn seq(comptime shape: CursorShape) *const ["\x1b[0 q".len]u8 {
        return "\x1b[" ++ &[_]u8{@as(u8, @intFromEnum(shape)) + '0'} ++ " q";
    }

    pub const format = write;
    pub fn write(shape: CursorShape, w: *std.Io.Writer) !void {
        try w.print(base_fmt, .{@intFromEnum(shape)});
    }
};

/// NOT MINE: copied from https://github.com/xyaman/mibu
// terminal manipulation
pub fn enableRawMode(handle: Io.File.Handle) !RawTerm {
    return switch (builtin.os.tag) {
        .linux, .macos => enableRawModePosix(handle),
        .windows => enableRawModeWindows(handle),
        else => error.UnsupportedPlatform,
    };
}

/// NOT MINE: copied from https://github.com/xyaman/mibu
pub const RawTerm = struct {
    context: switch (builtin.os.tag) {
        .windows => windows.DWORD,
        else => posix.termios,
    },

    /// The OS-specific file descriptor or file handle.
    handle: Io.File.Handle,

    const Self = @This();

    /// Returns to the previous terminal state
    pub fn disableRawMode(self: *Self) !void {
        switch (builtin.os.tag) {
            .linux, .macos => try self.disableRawModePosix(),
            .windows => try self.disableRawModeWindows(),
            else => return error.UnsupportedPlatform,
        }
    }

    fn disableRawModePosix(self: *Self) !void {
        try posix.tcsetattr(self.handle, .FLUSH, self.context);
    }

    fn disableRawModeWindows(self: *Self) !void {
        try setConsoleMode(self.handle, self.context);
    }
};

/// NOT MINE: copied from https://github.com/xyaman/mibu
fn enableRawModePosix(handle: posix.fd_t) !RawTerm {
    const original_termios = try posix.tcgetattr(handle);

    var termios = original_termios;

    // i needed some of these flags enabled (OPOST and ICRNL), so I had to make a copy

    // https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
    // TCSETATTR(3)
    // reference: void cfmakeraw(struct termios *t)

    // the three trues in this list were the entire reason I had to ~~steal~~ copy this code to modify it
    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = true;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;

    termios.oflag.OPOST = true;

    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = true;

    termios.cflag.CSIZE = .CS8;

    termios.cc[@intFromEnum(posix.V.MIN)] = 1;
    termios.cc[@intFromEnum(posix.V.TIME)] = 0;
    termios.cc[@intFromEnum(posix.V.INTR)] = 3;

    // apply changes
    try posix.tcsetattr(handle, .FLUSH, termios);

    return .{
        .context = original_termios,
        .handle = handle,
    };
}

// NOT MINE: copied from https://github.com/xyaman/mibu

// windows compatibility functions (copied from https://github.com/xyaman/mibu)
const windows = std.os.windows;
const kernel32 = windows.kernel32;

// code copied from `mibu`
const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x0001;
const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
const ENABLE_WINDOW_INPUT: windows.DWORD = 0x0008;
const ENABLE_MOUSE_INPUT: windows.DWORD = 0x0010;
const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;

const DISABLE_NEWLINE_AUTO_RETURN: windows.DWORD = 0x0008;

fn enableRawModeWindows(handle: windows.HANDLE) !RawTerm {
    const old_mode = try getConsoleMode(handle);

    const mode: windows.DWORD = ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT | ENABLE_PROCESSED_OUTPUT | ENABLE_PROCESSED_INPUT;
    try setConsoleMode(handle, mode);

    return .{
        .context = old_mode,
        .handle = handle,
    };
}

// https://learn.microsoft.com/en-us/windows/console/getconsolemode
fn getConsoleMode(handle: windows.HANDLE) !windows.DWORD {
    var mode: windows.DWORD = 0;

    // nonzero value means success
    if (kernel32.GetConsoleMode(handle, &mode) == 0) {
        const err = kernel32.GetLastError();
        return windows.unexpectedError(err);
    }

    return mode;
}

fn setConsoleMode(handle: windows.HANDLE, mode: windows.DWORD) !void {
    // nonzero value means success
    if (kernel32.SetConsoleMode(handle, mode) == 0) {
        const err = kernel32.GetLastError();
        return windows.unexpectedError(err);
    }
}

pub fn getConsoleScreenBufferInfo(handle: windows.HANDLE) !windows.CONSOLE_SCREEN_BUFFER_INFO {
    var csbi: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    if (kernel32.GetConsoleScreenBufferInfo(handle, &csbi) == 0) {
        const err = kernel32.GetLastError();
        return windows.unexpectedError(err);
    }
    return csbi;
}
