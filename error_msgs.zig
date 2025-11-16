const std = @import("std");

pub const StringContextInfo = struct {
    filename: []const u8,
    line: []const u8,
    line_num: usize,
    range_in_line: Range,
};

pub const Range = struct {
    index: usize,
    len: usize,

    pub fn slice(index: usize, len: usize) Range {
        return .{
            .index = index,
            .len = len,
        };
    }
    pub fn from(start: usize, end: usize) Range {
        return .{
            .index = start,
            .len = end - start,
        };
    }
    pub fn between(from_: usize, to: usize) Range {
        return .{
            .index = from_,
            .len = to - from_ + 1,
        };
    }
    pub fn fromSlice(comptime T: type, original: [*]const T, slice_: []const T) Range {
        return .{
            .index = @intFromPtr(slice_.ptr) - @intFromPtr(original),
            .len = slice_.len,
        };
    }
    pub fn SlicePointerReturnType(comptime PointerType: type) type {
        var info = @typeInfo(PointerType);
        info.pointer.size = .slice;
        return @Type(info);
    }
    pub fn slicePointerBy(range: Range, ptr: anytype) SlicePointerReturnType(@TypeOf(ptr)) {
        return ptr[range.index..][0..range.len];
    }
};

pub const LogLevel = enum(u2) {
    Debug,
    Info,
    Warn,
    Error,
};

pub var tab_width: u8 = 8;
const terminate_ansi = "\x1b[0m";
pub fn printHighlightLineError(
    writer: *std.Io.Writer,
    log_level: LogLevel,
    comptime fmt: []const u8,
    fmt_args: anytype,
    context: StringContextInfo) void {
    if (with_ansi_color) {
        customDataPrintHighlightLineError(writer, &LogLevelData, log_level, fmt, fmt_args, context);
    } else {
        customDataPrintHighlightLineError(writer, &ColorlessLogLevelData, log_level, fmt, fmt_args, context);
    }
}
pub fn customDataPrintHighlightLineError(
    writer: *std.Io.Writer,
    data: *const [4]LogLevelCodes,
    log_level: LogLevel,
    comptime fmt: []const u8,
    fmt_args: anytype,
    context: StringContextInfo) void {
    const file_pos_color_ansi = if (with_ansi_color) "\x1b[38;5;242m" else "";
    const line_num_color_ansi = if (with_ansi_color) "\x1b[38;5;248m" else "";

    printErrorHeader(writer, log_level, fmt, fmt_args);

    writer.print("\n{s} --> {s}:{d};{d}{s}\n", .{
        file_pos_color_ansi,
        context.filename, context.line_num, context.range_in_line.index+1,
        terminate_ansi,
    }) catch return;

    writer.print("{s}{d: >5} | {s}", .{line_num_color_ansi, context.line_num, terminate_ansi}) catch return;
    var cur_column: usize = 0;
    for (context.line[0..context.range_in_line.index]) |c| {
        if (c == '\t') {
            const n_chars = tab_width - cur_column % tab_width;
            for (0..n_chars) |_| {
                writer.writeByte(' ') catch return;
            }
            cur_column += n_chars;
        } else {
            writer.writeByte(c) catch return;
            cur_column += 1;
        }
    }

    const highlight_start_pos = cur_column;
    const log_level_data = data[@intFromEnum(log_level)];
    writer.writeAll(log_level_data.color_ansi) catch return;
    for (context.line[context.range_in_line.index..][0..context.range_in_line.len]) |c| {
        if (c == '\t') {
            const n_chars = tab_width - cur_column % tab_width;
            for (0..n_chars) |_| {
                writer.writeByte(' ') catch return;
            }
            cur_column += n_chars;
        } else {
            cur_column += 1;
            writer.writeByte(c) catch return;
        }
    }
    writer.writeAll(terminate_ansi) catch return;
    for (context.line[context.range_in_line.index + context.range_in_line.len..]) |c| {
        if (c == '\t') {
            const n_chars = tab_width - cur_column % tab_width;
            for (0..n_chars) |_| {
                writer.writeByte(' ') catch return;
            }
            cur_column += n_chars;
        } else {
            cur_column += 1;
            writer.writeByte(c) catch return;
        }
    }
    writer.print("\n{s}      | {s}", .{line_num_color_ansi, terminate_ansi}) catch return;
    writer.print("{0s: <[1]}{2s}{3s:~<[4]}{5s}\n\n", .{"", highlight_start_pos, log_level_data.color_ansi, "^", context.range_in_line.len, terminate_ansi}) catch return;
}

pub fn printErrorHeader(writer: *std.Io.Writer, log_level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    if (with_ansi_color) {
        customDataPrintErrorHeader(writer, &LogLevelData, log_level, fmt, args);
    } else {
        customDataPrintErrorHeader(writer, &ColorlessLogLevelData, log_level, fmt, args);
    }
}
pub fn customDataPrintErrorHeader(writer: *std.Io.Writer, data: *const [4]LogLevelCodes, log_level: LogLevel, comptime fmt: []const u8, args: anytype) void {
    const log_level_data = data[@intFromEnum(log_level)];
    
    writer.writeAll(log_level_data.color_ansi) catch return;
    writer.writeAll(log_level_data.start) catch return;
    writer.print(fmt ++ terminate_ansi, args) catch return;
}

pub const LogLevelCodes = struct {
    color_ansi: []const u8,
    start: []const u8,
};

pub var with_ansi_color = true;

/// index with @intFromEnum(log_level)
pub const LogLevelData: [4]LogLevelCodes = .{
    .{
        .color_ansi = "\x1b[38;5;255m",
        .start = "[DEBUG] ",
    },
    .{
        .color_ansi = "\x1b[38;5;81m",
        .start = "[INFO] ",
    },
    .{
        .color_ansi = "\x1b[38;5;214m",
        .start = "[WARN] ",
    },
    .{
        .color_ansi = "\x1b[38;5;9m",
        .start = "[ERROR] ",
    },
};

/// index with @intFromEnum(log_level)
pub const ColorlessLogLevelData: [4]LogLevelCodes = .{
    .{
        .color_ansi = "",
        .start = LogLevelData[0].start,
    },
    .{
        .color_ansi = "",
        .start = LogLevelData[1].start,
    },
    .{
        .color_ansi = "",
        .start = LogLevelData[2].start,
    },
    .{
        .color_ansi = "",
        .start = LogLevelData[3].start,
    },
};
