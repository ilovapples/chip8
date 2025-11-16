const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const mibu = @import("mibu");
const RawTerm = mibu.term.RawTerm;

// terminal manipulation
// (copied w/ some slight modifications from https://github.com/xyaman/mibu (check it out! very useful library))
pub fn enableRawMode(handle: std.fs.File.Handle) !RawTerm {
    return switch (builtin.os.tag) {
        .linux, .macos => enableRawModePosix(handle),
        .windows => enableRawModeWindows(handle),
        else => error.UnsupportedPlatform,
    };
}

fn enableRawModePosix(handle: posix.fd_t) !RawTerm {
    const original_termios = try posix.tcgetattr(handle);

    var termios = original_termios;

    // i needed some of these flags enabled (OPOST and ICRNL), so I had to make a copy

    // https://viewsourcecode.org/snaptoken/kilo/02.enteringRawMode.html
    // TCSETATTR(3)
    // reference: void cfmakeraw(struct termios *t)

    // // the two trues in this list were the entire reason I had to ~~steal~~ copy this code to modify it
    termios.iflag.BRKINT = false;
    termios.iflag.ICRNL = true;
    termios.iflag.INPCK = false;
    termios.iflag.ISTRIP = false;
    termios.iflag.IXON = false;

    termios.oflag.OPOST = true;

    termios.lflag.ECHO = false;
    termios.lflag.ICANON = false;
    termios.lflag.IEXTEN = false;
    termios.lflag.ISIG = false;

    termios.cflag.CSIZE = .CS8;

    termios.cc[@intFromEnum(posix.V.MIN)] = 1;
    termios.cc[@intFromEnum(posix.V.TIME)] = 0;

    // apply changes
    try posix.tcsetattr(handle, .FLUSH, termios);

    return .{
        .context = original_termios,
        .handle = handle,
    };
}



// windows compatibility functions (copied from https://github.com/xyaman/mibu)
const windows = std.os.windows;
const kernel32 = windows.kernel32;

// code copied from `mibu`
pub const ENABLE_PROCESSED_OUTPUT: windows.DWORD = 0x0001;
pub const ENABLE_PROCESSED_INPUT: windows.DWORD = 0x0001;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: windows.DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: windows.DWORD = 0x0008;
pub const ENABLE_MOUSE_INPUT: windows.DWORD = 0x0010;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: windows.DWORD = 0x0200;

pub const DISABLE_NEWLINE_AUTO_RETURN: windows.DWORD = 0x0008;

pub fn enableRawModeWindows(handle: windows.HANDLE) !RawTerm {
    const old_mode = try getConsoleMode(handle);

    const mode: windows.DWORD = ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT | ENABLE_PROCESSED_OUTPUT | ENABLE_PROCESSED_INPUT;
    try setConsoleMode(handle, mode);

    return .{
        .context = old_mode,
        .handle = handle,
    };
}

// https://learn.microsoft.com/en-us/windows/console/getconsolemode
pub fn getConsoleMode(handle: windows.HANDLE) !windows.DWORD {
    var mode: windows.DWORD = 0;

    // nonzero value means success
    if (kernel32.GetConsoleMode(handle, &mode) == 0) {
        const err = kernel32.GetLastError();
        return windows.unexpectedError(err);
    }

    return mode;
}

pub fn setConsoleMode(handle: windows.HANDLE, mode: windows.DWORD) !void {
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


