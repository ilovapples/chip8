//! implementation of a CHIP-8 Assembly Language (.as8) assembler program.
//! generates "machine code" interpretable by the emulator (Chip8Emu).
//!
//! sample assembly:
//!
//! ```
//! jmp :main ; unnecessary but helpful if you add stuff above main
//! main:
//!     mov v0, #10
//! loop_start:
//!     skne    v0, #0
//!     jmp :loop_end
//!     add v0, #0xff ; subtract 1 (by overflow, which is fine here)
//!     dbgrix    v0 ; debug print register as a hexadecimal integer
//!     jmp :loop_start
//! loop_end:
//!     ret
//! ```
//!
//! If you want, you *can* jump the PC to a specific address with `jmp`,
//! with $202 or some such, but, well, there are labels for a reason.
const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;
const assert = std.debug.assert;

const ArgParser = @import("lite_argparse").ArgParser;

const chip8 = @import("chip8.zig");
const chip8_usize = chip8.Chip8Emu.chip8_usize;
const RomInstruction = chip8.Chip8Emu.RomInstruction;

const error_msgs = @import("error_msgs.zig");

pub const InstructionInfo = struct {
    category: RomInstruction.InstructionCategory,
    format: OperandFormats,
    fill: u16,

    pub const OperandFormats = enum {
        NoOperands,
        End_3NybAddr,
        End_RegImm,
        Middle_TwoReg,
        Nyb1_OneReg,
        Nyb3_OneReg,
        End_TwoRegAndImm,
    };

    pub const OperandKindsByFormat = [_][]OperandKind{
        &.{},
        &.{.Addr},
        &.{ .Reg, .Imm2 },
        &.{ .Reg, .Reg },
        &.{.Reg},
        &.{.Reg},
        &.{ .Reg, .Reg, .Imm1 },
    };

    pub const OperandKind = enum(u2) {
        Addr,
        Imm2,
        Imm1,
        Reg,
    };
};

pub const MnemonicTable = std.StaticStringMap(InstructionInfo).initComptime([_]struct { []const u8, InstructionInfo }{
    // custom instructions
    .{ "dbgrc", .{ .category = .special, .format = .Nyb3_OneReg, .fill = 0x00a0 } },
    .{ "dbgrix", .{ .category = .special, .format = .Nyb3_OneReg, .fill = 0x00b0 } },
    .{ "dbgrid", .{ .category = .special, .format = .Nyb3_OneReg, .fill = 0x01b0 } },

    .{ "cls", .{ .category = .special, .format = .NoOperands, .fill = 0x00e0 } },
    .{ "ret", .{ .category = .special, .format = .NoOperands, .fill = 0x00ee } },
    .{ "exit", .{ .category = .special, .format = .NoOperands, .fill = 0x00fd } },
    .{ "jmp", .{ .category = .jmp, .format = .End_3NybAddr, .fill = 0x1000 } },
    .{ "jsl", .{ .category = .jsl, .format = .End_3NybAddr, .fill = 0x2000 } },
    .{ "skeq", .{ .category = .skeq, .format = .End_RegImm, .fill = 0x3000 } },
    .{ "skne", .{ .category = .skne, .format = .End_RegImm, .fill = 0x4000 } },
    .{ "skeqr", .{ .category = .skeq_reg, .format = .Middle_TwoReg, .fill = 0x5000 } },
    .{ "mov", .{ .category = .mov_imm, .format = .End_RegImm, .fill = 0x6000 } },
    .{ "add", .{ .category = .add_imm, .format = .End_RegImm, .fill = 0x7000 } },
    .{ "movr", .{ .category = .mov_reg, .format = .Middle_TwoReg, .fill = 0x8000 } },
    .{ "orr", .{ .category = .mov_reg, .format = .Middle_TwoReg, .fill = 0x8001 } },
    .{ "andr", .{ .category = .mov_reg, .format = .Middle_TwoReg, .fill = 0x8002 } },
    .{ "xorr", .{ .category = .mov_reg, .format = .Middle_TwoReg, .fill = 0x8003 } },
    .{ "addr", .{ .category = .mov_reg, .format = .Middle_TwoReg, .fill = 0x8004 } },
    .{ "subr", .{ .category = .mov_reg, .format = .Middle_TwoReg, .fill = 0x8005 } },
    .{ "shrr", .{ .category = .mov_reg, .format = .Nyb1_OneReg, .fill = 0x8006 } },
    .{ "rsbr", .{ .category = .mov_reg, .format = .Middle_TwoReg, .fill = 0x8007 } },
    .{ "shlr", .{ .category = .mov_reg, .format = .Nyb1_OneReg, .fill = 0x800e } },
    .{ "skner", .{ .category = .skne_reg, .format = .Middle_TwoReg, .fill = 0x9000 } },
    .{ "mvi", .{ .category = .mvi, .format = .End_3NybAddr, .fill = 0xa000 } },
    .{ "jmi", .{ .category = .jmi, .format = .End_3NybAddr, .fill = 0xb000 } },
    .{ "rand", .{ .category = .rand, .format = .End_RegImm, .fill = 0xc000 } },
    .{ "draw", .{ .category = .sprite, .format = .End_TwoRegAndImm, .fill = 0xd000 } },
    .{ "skpr", .{ .category = .skpr_skup, .format = .Nyb1_OneReg, .fill = 0xe09e } },
    .{ "skup", .{ .category = .skpr_skup, .format = .Nyb1_OneReg, .fill = 0xe0a1 } },
    // 'd' is placeholder here
    .{ "dtld", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf007 } },
    .{ "key", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf00a } },
    .{ "dtst", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf00a } },
    .{ "stst", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf018 } },
    .{ "addi", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf01e } },
    .{ "font", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf029 } },
    .{ "bcd", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf033 } },
    .{ "str", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf055 } },
    .{ "ldr", .{ .category = .extra_media, .format = .Nyb1_OneReg, .fill = 0xf065 } },
});

pub const As8ParserState = struct {
    entries: std.ArrayList(ListEntry),
    labels: std.StringHashMap(chip8_usize),
    uninited_addr_entries: std.ArrayList(EntryIndexWithContext) = .empty,

    reader: *std.Io.Reader,
    alloc: std.mem.Allocator,

    cur_addr: chip8_usize = 0x200,

    err_logger: *std.Io.Writer,
    context: error_msgs.StringContextInfo = .{
        .filename = "<stdin>",
        .line = &.{},
        .line_num = 0,
        .range_in_line = .{ .index = 0, .len = 0 },
    },
    // TODO: add some way to tell if the parser errored. we can't just quit when we find an error,
    // because we want to find multiple errors per execution, if possible. So, we should just make
    // a note when we find an error, so a program using this won't execute a program that's only
    // been half-assembled.

    pub fn init(alloc: std.mem.Allocator, reader: *std.Io.Reader, err_logger: *std.Io.Writer) As8ParserState {
        return .{
            .entries = .empty,
            .labels = .init(alloc),
            .reader = reader,
            .err_logger = err_logger,
            .alloc = alloc,
        };
    }

    pub fn deinit(state: *As8ParserState) void {
        for (state.entries.items) |item| {
            if (item != .data_segment) continue;
            state.alloc.free(item.data_segment);
        }
        state.entries.deinit(state.alloc);

        var labels_iter = state.labels.iterator();
        while (labels_iter.next()) |entry| {
            state.alloc.free(entry.key_ptr.*);
        }
        state.labels.deinit();

        state.uninited_addr_entries.deinit(state.alloc);
    }

    pub fn parse(state: *As8ParserState) !void {
        const saved_tab_width = error_msgs.tab_width;
        defer error_msgs.tab_width = saved_tab_width;
        error_msgs.tab_width = 6;
        while (true) {
            state.parseLine() catch |e| switch (e) {
                error.WhitespaceOnlyLine => continue,
                error.EndOfStream => break,
                else => return e,
            };
            std.log.info("in asm parsing loop", .{});
        }
        std.log.info("escaped asm parsing loop", .{});

        var is_err = false;
        for (state.uninited_addr_entries.items) |uae| {
            const the_entry = &state.entries.items[uae.index];
            const label_name = the_entry.addr_instr.addr.label;
            defer state.alloc.free(label_name);
            defer state.alloc.free(uae.context.line);
            //std.debug.print("retroactively looking for label '{s}'\n", .{label_name});
            if (state.labels.get(label_name)) |a| {
                the_entry.addr_instr.addr = .{ .addr = a };
            } else {
                error_msgs.printHighlightLineError(state.err_logger, .Error, "unknown label '{s}'", .{label_name}, uae.context);
                is_err = true;
            }
        }
        if (is_err) return error.UnknownLabel;
    }

    /// increments cur_addr
    /// the words argument and operand are used in their various forms pretty much interchangeably here
    fn parseLine(state: *As8ParserState) !void {
        const line_too_long_msg = "<line is too long; cannot be shown>";

        state.context.line = state.reader.peekDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                error_msgs.printHighlightLineError(state.err_logger, .Error, "line longer than {d} characters:", .{state.reader.buffer.len}, .{
                    .filename = state.context.filename,
                    .line_num = state.context.line_num,
                    .line = line_too_long_msg,
                    .range_in_line = .slice(0, line_too_long_msg.len),
                });
                return;
            },
            else => return err,
        };
        const original_line_len = state.context.line.len;

        state.context.line = state.context.line[0 .. std.mem.indexOfScalar(u8, state.context.line, ';') orelse state.context.line.len - 1];
        state.context.line_num += 1;
        // std.debug.print("cur line   = '{s}'\n", .{state.context.line});

        std.log.info("tokenizing line", .{});
        var tokens = std.mem.tokenizeAny(u8, state.context.line, &ascii.whitespace);
        const first_token = tokens.next() orelse {
            state.reader.toss(original_line_len);
            return error.WhitespaceOnlyLine;
        };
        const is_label = first_token[first_token.len - 1] == ':';
        if (is_label) std.log.info("  : found label '{s}'", .{first_token});
        const first_ident = if (is_label) first_token[0 .. first_token.len - 1] else first_token;
        if (!state.checkStringIsIdent(first_ident)) {
            state.reader.toss(original_line_len);
            return error.InvalidIdent;
        }
        // std.debug.print("ident      = '{s}'\n", .{first_token});

        const second_token = tokens.peek();
        if (std.mem.eql(u8, first_token, "data") and second_token != null and std.mem.eql(u8, second_token.?, "{")) {
            std.log.info("  parsing data segment", .{});
            _ = tokens.next();
            state.reader.toss(@intFromPtr(second_token.?.ptr) - @intFromPtr(state.context.line.ptr) + 1);
            state.context.line_num -= 1;
            try state.entries.append(state.alloc, .{ .data_segment = state.readDataSegment(.{
                .filename = state.context.filename,
                .line_num = state.context.line_num,
                .line = state.context.line,
                .range_in_line = .fromSlice(u8, state.context.line.ptr, first_token),
            }) orelse return error.InvalidDataSegment });
            std.log.info("  successfully parsed data segment", .{});
            return;
        }
        defer state.reader.toss(original_line_len);
        if (!is_label) outer: { // parse instruction
            std.log.info("  parsing mnemonic", .{});
            const instr_info = MnemonicTable.get(first_token) orelse {
                error_msgs.printHighlightLineError(state.err_logger, .Error, "found unknown mnemonic '{s}'", .{first_token}, .{
                    .filename = state.context.filename,
                    .line_num = state.context.line_num,
                    .line = state.context.line,
                    .range_in_line = .fromSlice(u8, state.context.line.ptr, first_token),
                });
                break :outer;
            };
            if (instr_info.format == .NoOperands) {
                try state.entries.append(state.alloc, .{ .other_instr = .{ .instr = instr_info } });
                state.cur_addr += 2;
                break :outer;
            }
            if (instr_info.format == .End_3NybAddr) {
                try state.entries.append(state.alloc, .{
                    .addr_instr = .{
                        .kind = instr_info.category,
                        .addr = state.readAddrOperand(state.nextOperand(&tokens, true) orelse break :outer) orelse break :outer,
                    },
                });
            } else {
                var opers: RomInstruction.Operands = @bitCast(@as(u12, 0));
                var cur_arg: []const u8 = undefined;
                switch (instr_info.format) {
                    .End_RegImm => {
                        cur_arg = state.nextOperand(&tokens, false) orelse break :outer;
                        opers.reg_imm.regR = state.readRegOperand(cur_arg) orelse break :outer;
                        cur_arg = state.nextOperand(&tokens, true) orelse break :outer;
                        opers.reg_imm.imm = state.readImm2Operand(cur_arg) orelse break :outer;
                    },
                    .Middle_TwoReg => {
                        cur_arg = state.nextOperand(&tokens, false) orelse break :outer;
                        opers.reg_reg_unused.regR = state.readRegOperand(cur_arg) orelse break :outer;
                        cur_arg = state.nextOperand(&tokens, true) orelse break :outer;
                        opers.reg_reg_unused.regY = state.readRegOperand(cur_arg) orelse break :outer;
                    },
                    .End_TwoRegAndImm => {
                        cur_arg = state.nextOperand(&tokens, false) orelse break :outer;
                        opers.reg_reg_imm.regR = state.readRegOperand(cur_arg) orelse break :outer;
                        cur_arg = state.nextOperand(&tokens, false) orelse break :outer;
                        opers.reg_reg_imm.regY = state.readRegOperand(cur_arg) orelse break :outer;
                        cur_arg = state.nextOperand(&tokens, true) orelse break :outer;
                        opers.reg_reg_imm.imm = state.readImm1Operand(cur_arg) orelse break :outer;
                    },
                    .Nyb1_OneReg => {
                        cur_arg = state.nextOperand(&tokens, true) orelse break :outer;
                        opers.nybble_byte.nybble = state.readRegOperand(cur_arg) orelse break :outer;
                    },
                    .Nyb3_OneReg => {
                        cur_arg = state.nextOperand(&tokens, true) orelse break :outer;
                        opers.byte_nybble.nybble = state.readRegOperand(cur_arg) orelse break :outer;
                    },
                    else => {},
                }
                try state.entries.append(state.alloc, .{
                    .other_instr = .{
                        .instr = instr_info,
                        .args = opers,
                    },
                });
                //std.debug.print("{any}\n", .{state.entries.items[state.entries.items.len-1]});
            }
            state.cur_addr += 2;
        } else { // store label info
            // std.debug.print("found label '{s}' marking address ${x:0>3}\n", .{first_ident, state.cur_addr});
            try state.labels.put(state.alloc.dupe(u8, first_ident) catch @panic("OOM"), state.cur_addr);
        }
    }

    fn checkStringIsIdent(state: *As8ParserState, str: []const u8) bool {
        const valid_ident_first_char = "_" ++ ascii.letters;
        const valid_ident_chars = valid_ident_first_char ++ "0123456789";

        const context: error_msgs.StringContextInfo = .{
            .filename = state.context.filename,
            .line_num = state.context.line_num,
            .line = state.context.line,
            .range_in_line = .slice(@intFromPtr(str.ptr) - @intFromPtr(state.context.line.ptr), str.len),
        };

        if (std.mem.indexOfScalar(u8, valid_ident_first_char, str[0]) == null) {
            error_msgs.printHighlightLineError(state.err_logger, .Error, "found invalid identifier '{s}'", .{str}, context);
            return false;
        }
        if (std.mem.indexOfNone(u8, str[1..], valid_ident_chars) != null) {
            error_msgs.printHighlightLineError(state.err_logger, .Error, "found invalid identifier '{s}'", .{str}, context);
            return false;
        }
        return true;
    }

    fn nextOperand(state: *As8ParserState, tokens: *std.mem.TokenIterator(u8, .any), comptime is_last_operand: bool) ?[]const u8 {
        const comma_required = "a comma (',') separator is required to follow this mnemonic operand:";
        const comma_illegal = "a comma separator may not appear after the last mnemonic operand";

        const token = tokens.next() orelse return null;
        if (is_last_operand ^ (token[token.len - 1] != ',')) {
            if (is_last_operand) {
                error_msgs.printHighlightLineError(state.err_logger, .Error, comma_illegal, .{}, .{
                    .filename = state.context.filename,
                    .line_num = state.context.line_num,
                    .line = state.context.line,
                    .range_in_line = .{ .index = @intFromPtr(token.ptr) - @intFromPtr(state.context.line.ptr) + token.len - 1, .len = 1 },
                });
            } else {
                error_msgs.printHighlightLineError(state.err_logger, .Error, comma_required, .{}, .{
                    .filename = state.context.filename,
                    .line_num = state.context.line_num,
                    .line = state.context.line,
                    .range_in_line = .fromSlice(u8, state.context.line.ptr, token),
                });
            }
            return null;
        }

        //std.debug.print("got arg slice '{s}'\n", .{state.current_context.line[new_start..new_end]});
        return if (is_last_operand) token else token[0 .. token.len - 1];
    }

    fn readAddrOperand(state: *As8ParserState, arg: []const u8) ?AddressValue {
        // std.debug.print("reading address operand from '{s}'\n", .{arg});
        const context: error_msgs.StringContextInfo = .{
            .filename = state.context.filename,
            .line_num = state.context.line_num,
            .line = state.context.line,
            .range_in_line = .slice(@intFromPtr(arg.ptr) - @intFromPtr(state.context.line.ptr), arg.len),
        };

        if (arg[0] == '$' and ascii.isHex(arg[1]) and ascii.isHex(arg[2]) and ascii.isHex(arg[3])) {
            return .{ .addr = std.fmt.parseInt(chip8_usize, arg[1..4], 16) catch unreachable };
        } else if (arg[0] == ':') {
            if (state.labels.get(arg[1..])) |a| {
                return .{ .addr = a };
            } else {
                state.uninited_addr_entries.append(state.alloc, .{ .index = state.entries.items.len, .context = .{
                    .filename = context.filename,
                    .line_num = context.line_num,
                    .line = state.alloc.dupe(u8, context.line) catch @panic("OOM"),
                    .range_in_line = context.range_in_line,
                } }) catch @panic("OOM");
                return .{ .label = state.alloc.dupe(u8, arg[1..]) catch @panic("OOM") };
            }
        } else {
            error_msgs.printHighlightLineError(state.err_logger, .Error, "found invalid address specifier '{s}'", .{arg}, context);
            return null;
        }
    }
    fn readImm2Operand(state: *As8ParserState, arg: []const u8) ?u8 {
        const invalid_msg = "found invalid immediate value specifier '{s}'";
        const context: error_msgs.StringContextInfo = .{
            .filename = state.context.filename,
            .line_num = state.context.line_num,
            .line = state.context.line,
            .range_in_line = .slice(@intFromPtr(arg.ptr) - @intFromPtr(state.context.line.ptr), arg.len),
        };

        if (arg[0] != '#' or arg.len < 2) {
            error_msgs.printHighlightLineError(state.err_logger, .Error, invalid_msg, .{arg}, context);
            return null;
        }
        return std.fmt.parseInt(u8, arg[1..], 0) catch {
            error_msgs.printHighlightLineError(state.err_logger, .Error, invalid_msg, .{arg}, context);
            return null;
        };
    }
    fn readImm1Operand(state: *As8ParserState, arg: []const u8) ?u4 {
        const invalid_msg = "found invalid immediate value specifier '{s}'";
        const context: error_msgs.StringContextInfo = .{
            .filename = state.context.filename,
            .line_num = state.context.line_num,
            .line = state.context.line,
            .range_in_line = .slice(@intFromPtr(arg.ptr) - @intFromPtr(state.context.line.ptr), arg.len),
        };

        if (arg[0] != '#' or arg.len < 2) {
            error_msgs.printHighlightLineError(state.err_logger, .Error, invalid_msg, .{arg}, context);
            return null;
        }
        return std.fmt.parseInt(u4, arg[1..], 0) catch {
            error_msgs.printHighlightLineError(state.err_logger, .Error, invalid_msg, .{arg}, context);
            return null;
        };
    }
    fn readRegOperand(state: *As8ParserState, arg: []const u8) ?u4 {
        const invalid_msg = "found invalid register specifier '{s}'";

        if (!(arg[0] == 'v' or arg[0] == 'V') or arg.len != 2) {
            error_msgs.printHighlightLineError(state.err_logger, .Error, invalid_msg, .{arg}, .{
                .filename = state.context.filename,
                .line_num = state.context.line_num,
                .line = state.context.line,
                .range_in_line = .slice(@intFromPtr(arg.ptr) - @intFromPtr(state.context.line.ptr), arg.len),
            });
            return null;
        }
        return hexCharToHexNybble(arg[1]);
    }

    fn hexCharToHexNybble(byte: u8) ?u4 {
        return switch (byte) {
            '0'...'9' => @intCast(byte - '0'),
            'a'...'f' => @intCast(0xa + byte - 'a'),
            'A'...'F' => @intCast(0xA + byte - 'A'),
            else => null,
        };
    }

    fn readDataSegment(state: *As8ParserState, segment_start_context: error_msgs.StringContextInfo) ?[]const u8 {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(state.alloc); // only important if exiting early
        while (true) {
            std.log.info("  - reading data segment line", .{});
            state.context.line = state.reader.takeDelimiterExclusive('\n') catch {
                error_msgs.printHighlightLineError(state.err_logger, .Error, "unterminated data segment block starts here:", .{}, segment_start_context);
                return null;
            };
            std.log.info("  - DONE", .{});
            const line = state.context.line[0 .. std.mem.indexOfScalar(u8, state.context.line, ';') orelse state.context.line.len];
            var tokens = std.mem.tokenizeAny(u8, line, &ascii.whitespace);
            std.log.info("  - beginning token loop. line = '{s}'", .{line});
            while (tokens.next()) |tok| {
                std.log.info("    * reading data segment token '{s}'", .{tok});
                // std.debug.print("token in data segment  =  '{s}'\n", .{tok});
                // std.debug.print("len of token           =  {d}\n", .{tok.len});
                if (std.mem.eql(u8, tok, "}")) {
                    // std.debug.print("found end of data segment\n", .{});
                    state.context.line_num += 1;
                    return data.toOwnedSlice(state.alloc) catch @panic("OOM");
                }
                if (std.fmt.parseInt(u8, tok, 0) catch null) |byte| {
                    data.append(state.alloc, byte) catch @panic("OOM");
                } else {
                    error_msgs.printHighlightLineError(state.err_logger, .Error, "invalid byte literal '{s}'", .{tok}, .{
                        .filename = state.context.filename,
                        .line_num = state.context.line_num,
                        .line = state.context.line,
                        .range_in_line = .fromSlice(u8, state.context.line.ptr, tok),
                    });
                }
                state.cur_addr += 1;
            }

            state.context.line_num += 1;

            std.log.info("  - on finished reading line {d}", .{state.context.line_num});
        }

        return null;
    }

    pub const EntryIndexWithContext = struct {
        index: usize,
        context: error_msgs.StringContextInfo,
    };

    pub const LabelOrMnemonic = union(enum) {
        label: []const u8,
        mnemonic: []const u8,
    };

    pub const ListEntry = union(enum) {
        addr_instr: struct {
            kind: RomInstruction.InstructionCategory,
            addr: AddressValue,
        },
        other_instr: struct {
            instr: InstructionInfo,
            args: RomInstruction.Operands = @bitCast(@as(u12, 0)),
        },
        data_segment: []const u8,

        pub fn serialize(self: @This(), state: ?As8ParserState, writer: *std.Io.Writer) !void {
            switch (self) {
                .addr_instr => |ai| try writer.writeInt(u16, (@as(u16, @intFromEnum(ai.kind)) << 12) | switch (ai.addr) {
                    .label => |l| state.?.labels.get(l) orelse return error.UnknownLabel,
                    .addr => |a| a,
                }, .big),
                .other_instr => |oi| try writer.writeInt(u16, switch (oi.instr.format) {
                    .End_RegImm, .End_TwoRegAndImm => oi.instr.fill | @as(u16, @intCast(@as(u12, @bitCast(oi.args)))),
                    .Middle_TwoReg => oi.instr.fill | @as(u16, @intCast(@as(u12, @bitCast(oi.args)) & 0xFF0)),
                    .Nyb1_OneReg => oi.instr.fill | @as(u16, @intCast(@as(u12, @bitCast(oi.args)) & 0xF00)),
                    .Nyb3_OneReg => oi.instr.fill | @as(u16, @intCast(@as(u12, @bitCast(oi.args)) & 0x00F)),
                    .NoOperands => oi.instr.fill,
                    else => unreachable,
                }, .big),
                .data_segment => |ds| try writer.writeAll(ds),
            }
        }
        test serialize {
            const expected_pairs = [_]struct { u16, ListEntry }{
                .{ 0x1202, ListEntry{ .addr_instr = .{ .kind = .jmp, .addr = .{ .addr = 0x202 } } } },
                .{ 0xd019, ListEntry{ .other_instr = .{ .instr = MnemonicTable.get("draw").?, .args = .{ .reg_reg_imm = .{ .regR = 0x0, .regY = 0x1, .imm = 9 } } } } },
                .{ 0x83f3, ListEntry{ .other_instr = .{ .instr = MnemonicTable.get("xorr").?, .args = .{ .reg_reg_unused = .{ .regR = 0x3, .regY = 0xf, .unused = 0 } } } } },
                .{ 0x22ac, ListEntry{ .addr_instr = .{ .kind = .jsl, .addr = .{ .addr = 0x2ac } } } },
                .{ 0x00ee, ListEntry{ .other_instr = .{ .instr = MnemonicTable.get("ret").? } } },
                .{ 0x00e0, ListEntry{ .other_instr = .{ .instr = MnemonicTable.get("cls").? } } },
                .{ 0xe9a1, ListEntry{ .other_instr = .{ .instr = MnemonicTable.get("skup").?, .args = .{ .nybble_byte = .{ .nybble = 0x9, .byte = 0 } } } } },
                .{ 0x01b3, ListEntry{ .other_instr = .{ .instr = MnemonicTable.get("dbgrid").?, .args = .{ .byte_nybble = .{ .byte = 0, .nybble = 0x3 } } } } },
            };

            for (expected_pairs) |pair| {
                try testing.expectEqual(pair.@"0", pair.@"1".serialize(null));
            }
        }
    };

    pub const AddressValue = union(enum) {
        label: []const u8,
        addr: chip8_usize,
    };
};

test {
    _ = MnemonicTable;
    _ = As8ParserState;
}

pub fn main() !u8 {
    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    var ap: ArgParser = try .init(alloc, args);
    defer ap.deinit();

    const filename = try ap.longShortOption([]const u8, "in", 'i', "in file");
    const help_option = try ap.longShortOption(bool, "help", 'h', "display this help message") orelse false;
    if (help_option or filename == null) {
        if (filename == null and !help_option) {
            std.log.err("{s}: a path to an input file must be passed (with '--in')", .{args[0]});
        }
        ap.printUsage(stderr);
        return 1;
    }

    var file_read_buf: [512]u8 = undefined;
    var file = std.fs.cwd().openFile(filename.?, .{ .mode = .read_only }) catch {
        std.log.err("{s}: failed to open file '{s}'", .{ args[0], filename.? });
        return 2;
    };
    var file_reader = file.reader(&file_read_buf);

    var as8_state: As8ParserState = .init(alloc, &file_reader.interface, stderr);
    defer as8_state.deinit();
    as8_state.context.filename = filename.?;
    as8_state.parse() catch {
        error_msgs.printErrorHeader(stderr, .Warn, "as8 parsing failed\n", .{});
        return 3;
    };

    if (as8_state.entries.items.len == 0) {
        error_msgs.printErrorHeader(stderr, .Warn, "generated zero entries\n", .{});
    } else {
        error_msgs.printErrorHeader(stderr, .Info, "generated {d} entries\n", .{as8_state.entries.items.len});
    }
    try stderr.flush();

    for (as8_state.entries.items) |item| {
        //try stderr.print("{any}\n", .{item});
        try item.serialize(as8_state, stdout);
    }

    try stdout.flush();

    return 0;
}
