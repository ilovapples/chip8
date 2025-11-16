const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const posix = std.posix;

const chip8 = @import("chip8.zig");
const Chip8Emu = chip8.Chip8Emu;

const mibu = @import("mibu");

const rawmode_term = @import("term.zig");

pub const Chip8TermIO = struct {
    tty_writer: *std.fs.File.Writer,
    tty_reader: *std.fs.File.Reader,
    rawmode_handle: ?mibu.term.RawTerm = null,

    buffered_keys: std.ArrayList(u8) = .empty,
    alloc: std.mem.Allocator,

    pub const OutputError = Chip8Emu.IoInterface.OutputError;
    pub const InputError = Chip8Emu.IoInterface.InputError;

    pub fn init(tty_out: *std.fs.File.Writer, tty_in: *std.fs.File.Reader, alloc: std.mem.Allocator) Chip8TermIO {
        return .{
            .tty_writer = tty_out,
            .tty_reader = tty_in,
            .alloc = alloc,
        };
    }
    pub fn deinit(tio: *Chip8TermIO) void {
        tio.buffered_keys.deinit(tio.alloc);
    }

    pub fn interface(tio: *Chip8TermIO) Chip8Emu.IoInterface {
        return .{
            .ptr = tio,
            .vtable = &.{
                .startOutput = startOutput,
                .startInput = startInput,
                .endOutput = endOutput,
                .endInput = endInput,
                .drawBuffer = drawBuffer,
                .getKeyBlocking = getKeyBlocking,
                .checkKeyIsPressed = checkKeyIsPressed,
                .shouldTerminate = shouldTerminate,
            },
        };
    }

    fn startOutput(ctx: *anyopaque) OutputError!void {
        const tio: *Chip8TermIO = @ptrCast(@alignCast(ctx));

        assert(posix.isatty(tio.tty_writer.file.handle));
        const w: *std.Io.Writer = &tio.tty_writer.interface;

        try mibu.term.enterAlternateScreen(w);
        try mibu.cursor.hide(w);
        try mibu.cursor.goTo(w, 1, 1);
        try w.flush();
    }

    fn startInput(ctx: *anyopaque) InputError!void {
        const tio: *Chip8TermIO = @ptrCast(@alignCast(ctx));

        tio.rawmode_handle = rawmode_term.enableRawMode(tio.tty_reader.file.handle)
            catch |err| if (err != error.NotATerminal) return InputError.OtherError else null;
 
    }

    fn endOutput(ctx: *anyopaque) void {
        const tio: *Chip8TermIO = @ptrCast(@alignCast(ctx));
        const w = &tio.tty_writer.interface;

        mibu.term.exitAlternateScreen(w) catch return;
        mibu.cursor.show(w) catch return;
        w.flush() catch return;
    }

    fn endInput(ctx: *anyopaque) void {
        const tio: *Chip8TermIO = @ptrCast(@alignCast(ctx));

        if (tio.rawmode_handle) |*rh| rh.disableRawMode() catch return;
    }

    const use_border = true;
    const check_term_size = true;
    fn drawBuffer(ctx: *anyopaque, buf: *const [32]u64) OutputError!void {
        const tio: *Chip8TermIO = @ptrCast(@alignCast(ctx));
        const w = &tio.tty_writer.interface;

        if (check_term_size) {
            const full_width = if (use_border) 64*2 + 2 else 64*2;
            const full_height = if (use_border) 32 + 2 else 32;
            const term_size = mibu.term.getSize(tio.tty_writer.file.handle) catch return OutputError.OtherError;
            const term_size_is_big_enough = term_size.width >= full_width and term_size.height >= full_height;
            if (!term_size_is_big_enough) {
                // terminal too small
                const term_too_small_str = "[ {d}x{d} terminal is too small (need at least 128x32) ]";
                const half_width = term_size.width/2;
                const half_str_len = term_too_small_str.len/2;
                try mibu.cursor.goTo(w, if (half_str_len > half_width) 0 else half_width - half_str_len, term_size.height/2-1);
                try w.print(term_too_small_str, .{term_size.width, term_size.height});
                try mibu.cursor.goTo(w, 1, 1);
                try w.flush();

                return OutputError.RangeError;
            }
        }

        if (use_border) {
            try w.writeAll("┌");
            for (0..64*2) |_| try w.writeAll("─");
            try w.writeAll("┐\n");
        }

        for (buf.*) |row| {
            if (use_border) try w.writeAll("│");
            var mask: u64 = 1<<63;
            while (mask != 0) : (mask >>= 1) {
                try w.writeAll(if ((row & mask) == 0) "  " else "██");
            }
            if (use_border) try w.writeAll("│");
            try w.writeByte('\n');
        }

        if (use_border) {
            try w.writeAll("└");
            for (0..64*2) |_| try w.writeAll("─");
            try w.writeAll("┘");
        }

        try mibu.cursor.goTo(w, 1, 1);
        try w.flush();
    }

    fn getKeyBlocking(ctx: *anyopaque) InputError!u4 {
        const tio: *Chip8TermIO = @ptrCast(@alignCast(ctx));

        if (tio.buffered_keys.pop()) |last| {
            if (Chip8Emu.IoInterface.asciiToChip8Key(last)) |k| return k; 
        }

        return while (true) {
            if (Chip8Emu.IoInterface.asciiToChip8Key(tio.tty_reader.interface.takeByte()
                    catch return InputError.ReadFailed)) |k|
            {
                break k;
            }
        } else unreachable;
    }

    fn checkKeyIsPressed(ctx: *anyopaque, key: u4) InputError!bool {
        const tio: *Chip8TermIO = @ptrCast(@alignCast(ctx));
        const r = &tio.tty_reader.interface;

        if (tio.buffered_keys.pop()) |last| {
            const chip8_key = Chip8Emu.IoInterface.asciiToChip8Key(last);
            return chip8_key != null and chip8_key.? == key;
        }

        if (!(kbhit(tio.tty_reader.file.handle) catch return InputError.ReadFailed)) return false;

        return blk: {
            const ascii_key = r.takeByte() catch return InputError.ReadFailed;
            const chip8_key = Chip8Emu.IoInterface.asciiToChip8Key(ascii_key);
            break :blk chip8_key != null and chip8_key.? == key;
        };
    }

    fn shouldTerminate(ctx: *anyopaque) InputError!bool {
        const tio: *Chip8TermIO = @ptrCast(@alignCast(ctx));

        if (tio.buffered_keys.pop()) |last| {
            return last == Chip8Emu.IoInterface.terminate_key;
        }

        if (!(kbhit(tio.tty_reader.file.handle) catch return InputError.ReadFailed)) return false;
        const c = tio.tty_reader.interface.peekByte() catch unreachable;
        if (c != Chip8Emu.IoInterface.terminate_key) {
            tio.buffered_keys.append(tio.alloc, c) catch @panic("OOM");
            return false;
        }

        tio.tty_reader.interface.toss(1);
        return true;
    }

    // windows <conio.h> _kbhit() func. hopefully will link on windows
    extern fn _kbhit() c_int;
    fn kbhit(handle: std.fs.File.Handle) !bool {
        if (builtin.os.tag == .windows) {
            return _kbhit() != 0;
        }
        var fds: [1]posix.pollfd = .{ .{ .fd = handle, .events = posix.POLL.IN, .revents = 0, } };
        const timeout_ms: i32 = 50;
        if (try posix.poll(&fds, timeout_ms) == 0) {
            return error.Timeout;
        }
        return (fds[0].revents & posix.POLL.IN) != 0;
    }
};


