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
//! Specific addresses can be indicated for instructions that use them
//! with '$addr', like '$202' for the start of main in the example. For
//! addresses within code, you should probably use labels, but for any
//! address before $200, you can't use labels, so that syntax is
//! necessary.

const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const ascii = std.ascii;
const testing = std.testing;
const assert = std.debug.assert;

const ArgParser = @import("jitargs").ArgParser;

const chip = @import("chip8.zig");
const rom = @import("rom.zig");

const error_msgs = @import("error_msgs.zig");

var debug_log = false;
pub const std_options: std.Options = .{
    .logFn = customLog,
};
fn customLog(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (level == .debug and !debug_log) return;
    std.log.defaultLog(level, scope, format, args);
}

const usage_msg =
    \\usage: {s} [-hd] [options] [filename]
    \\
    \\one of `filename` and the '--stdin' flag must be passed.
    \\
    \\options:
    \\  --help, -h          display this help message
    \\  --debug, -d         enable debug logging
    \\  --stdin             read as8 from stdin
    \\
;

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var io_threaded: Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    const args = try init.args.toSlice(arena.allocator());
    var ap: ArgParser = try .init(gpa, args);
    defer ap.deinit();

    const help_option = ap.longShortOption(bool, "help", 'h') orelse false;
    debug_log = ap.longShortOption(bool, "debug", 'd') orelse false;
    const read_stdin = ap.longOption(bool, "stdin") orelse false;
    const filename = ap.positionalOption([]const u8);
    const no_file_provided = (filename == null and !read_stdin);
    const finalize_succeeded = ap.handleFinalize();

    if (help_option or no_file_provided or !finalize_succeeded) {
        if (no_file_provided and !help_option) {
            std.log.err("{s}: a path to an input file must be passed", .{args[0]});
        }
        try stderr.print(usage_msg, .{args[0]});
        return 1;
    }

    var file_read_buf: [512]u8 = undefined;
    var file: Io.File = if (read_stdin)
        .stdin()
    else
        Io.Dir.cwd().openFile(io, filename.?, .{ .mode = .read_only }) catch {
            std.log.err("{s}: failed to open file '{s}'", .{ args[0], filename.? });
            return 2;
        };
    defer if (!read_stdin) file.close(io);
    var file_reader = file.reader(io, &file_read_buf);

    var as8_state: As8ParserState = .init(gpa, &file_reader.interface, stderr);
    defer as8_state.deinit();
    as8_state.context.filename = if (read_stdin) "<stdin>" else filename.?;
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

pub const InstructionInfo = struct {
    category: rom.Instruction.Category,
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

    pub const OperandKindsByFormat = [_][]const OperandKind{
        &.{},
        &.{.addr},
        &.{ .reg, .imm2 },
        &.{ .reg, .reg, .unused },
        &.{ .reg, .unused, .unused },
        &.{ .unused, .unused, .reg },
        &.{ .reg, .reg, .imm1 },
    };

    pub const OperandKind = enum(u3) {
        /// 4-bit placeholder.
        unused,
        /// 12 bits
        addr,
        /// 8 bits
        imm2,
        /// 4 bits
        imm1,
        /// 4 bits
        reg,

        pub fn bitSize(kind: OperandKind) u4 {
            return switch (kind) {
                .reg, .imm1, .unused => 4,
                .imm2 => 8,
                .addr => 12,
            };
        }

        /// returned union will have the tag `kind`.
        pub fn readFromState(kind: OperandKind, state: *As8ParserState, s: []const u8) ?Operand {
            return switch (kind) {
                .unused => .{ .unused = {} },
                .addr => .{ .addr = state.readAddrOperand(s) orelse return null },
                .imm2 => .{ .imm2 = state.readImmOperand(s, u8) orelse return null },
                .imm1 => .{ .imm1 = state.readImmOperand(s, u4) orelse return null },
                .reg => .{ .reg = state.readRegOperand(s) orelse return null },
            };
        }
    };

    pub const Operand = union(OperandKind) {
        unused: void,
        addr: As8ParserState.AddressValue,
        imm2: u8,
        imm1: u4,
        reg: u4,
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
    entries: std.ArrayList(ParsedEntry),
    labels: std.StringHashMap(chip.Addr),
    uninited_addr_entries: std.ArrayList(EntryIndexWithContext) = .empty,

    reader: *std.Io.Reader,
    alloc: mem.Allocator,

    cur_addr: chip.Addr = chip.Ram.offsets.program_data,

    err_logger: *std.Io.Writer,
    context: error_msgs.StringContextInfo = .{
        .filename = "<stdin>",
        .line = &.{},
        .line_num = 0,
        .range = .{ .index = 0, .len = 0 },
    },

    data_segment_buffer: [0x1000]u8 = undefined,
    in_progress_data_segment: ?std.ArrayList(u8) = null,

    pub const errors = struct {
        pub const line_too_long_line = "<line is too long; cannot be shown>";
        pub const line_too_long_msg = "line longer than {d} characters";
        pub const data_too_long = "data segment length exceeds 4096 bytes with this extra byte";
        pub const lonely_data_ident = "lonely 'data' identifier is not allowed; data segments are entered with 'data {{' on one line";
        pub const trailing_after_data_entry = "found trailing token '{s}' following start of data segment";
        pub const char_lit_out_of_range = "character literal {s} is out of range; must be one byte";
        pub const invalid_char_lit_quoted = "invalid character literal '{s}' in data segment";
        pub const invalid_char_lit = "invalid character literal {s} in data segment";
        pub const invalid_byte_lit = "invalid byte literal '{s}' in data segment";
        pub const invalid_ident = "found invalid identifier '{s}'";
        pub const comma_required_after_arg = "a comma (',') separator is required to follow non-final operands to instructions";
        pub const comma_illegal_after_arg = "illegal trailing comma after last operand to instruction";
        pub const invalid_addr_spec = "found invalid address specifier '{s}'";
        pub const invalid_imm_spec = "found invalid immediate value specifier '{s}'";
        pub const invalid_reg_spec = "found invalid register specifier '{s}'";
        pub const unknown_mnemonic = "unknown mnemonic '{s}'";
        pub const unknown_label = "unknown label '{s}'";
    };

    // TODO: add some way to tell if the parser errored. we can't just quit when we find an error,
    // because we want to find multiple errors per execution, if possible. So, we should just make
    // a note when we find an error, so a program using this won't execute a program that's only
    // been half-assembled.

    const logger = std.log.scoped(.@"asm-parse");

    pub fn init(alloc: mem.Allocator, reader: *std.Io.Reader, err_logger: *std.Io.Writer) As8ParserState {
        return .{
            .entries = .empty,
            .labels = .init(alloc),
            .reader = reader,
            .err_logger = err_logger,
            .alloc = alloc,
        };
    }

    pub fn deinit(state: *As8ParserState) void {
        for (state.uninited_addr_entries.items) |uae_entry| {
            const the_entry = &state.entries.items[uae_entry.index];
            if (the_entry.addr_instr.addr == .label) {
                // uninited label was not cleaned up
                state.alloc.free(the_entry.addr_instr.addr.label);
                state.alloc.free(uae_entry.context.line);
            }
        }
        state.uninited_addr_entries.deinit(state.alloc);

        for (state.entries.items) |item| {
            if (item == .data_segment) state.alloc.free(item.data_segment);
        }
        state.entries.deinit(state.alloc);

        var labels_iter = state.labels.iterator();
        while (labels_iter.next()) |entry| {
            state.alloc.free(entry.key_ptr.*);
        }
        state.labels.deinit();
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
        }

        var is_err = false;
        for (state.uninited_addr_entries.items) |uae| {
            const the_entry = &state.entries.items[uae.index];
            const label_name = the_entry.addr_instr.addr.label;
            //std.debug.print("retroactively looking for label '{s}'\n", .{label_name});
            if (state.labels.get(label_name)) |a| {
                state.alloc.free(the_entry.addr_instr.addr.label);
                state.alloc.free(uae.context.line);
                the_entry.addr_instr.addr = .{ .addr = a };
            } else {
                state.printError(.Error, errors.unknown_label, .{label_name}, .{
                    .line = uae.context.line,
                    .range = .{ .range = uae.context.range },
                });
                is_err = true;
            }
        }
        if (is_err) return error.UnknownLabel;
    }

    pub fn parseLine(state: *As8ParserState) !void {
        state.context.line = state.reader.peekDelimiterInclusive('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                state.printError(.Error, errors.line_too_long_msg, .{state.reader.buffer.len}, .{
                    .line = errors.line_too_long_line,
                    .range = .{ .range = .from(0, errors.line_too_long_line.len) },
                });
                return;
            },
            else => return err,
        };
        const original_line_len = state.context.line.len;
        const semicolon_idx = mem.indexOfScalar(u8, state.context.line, ';');
        state.context.line = state.context.line[0 .. semicolon_idx orelse state.context.line.len - 1]; // -1 to skip newline
        state.context.line_num += 1;
        errdefer state.reader.toss(original_line_len);

        var tokenizer = mem.tokenizeAny(u8, state.context.line, &ascii.whitespace);
        if (tokenizer.peek() == null) {
            // empty line
            return error.WhitespaceOnlyLine;
        }

        if (state.in_progress_data_segment) |*data_segment| {
            // continue data segment
            while (tokenizer.next()) |s| {
                if (mem.eql(u8, s, "}")) {
                    // end of data segment
                    state.cur_addr += @intCast(data_segment.items.len);

                    logger.debug("exiting data segment. next addr is 0x{x:0>3}", .{state.cur_addr});

                    try state.entries.append(state.alloc, .{
                        .data_segment = try state.alloc.dupe(u8, data_segment.items),
                    });

                    state.in_progress_data_segment = null;

                    break;
                }

                logger.debug("  found byte token '{s}' in data segment", .{s});

                const byte: u8 = state.parseByteOrCharLiteral(s, state.context.line) orelse return error.InvalidDataSegment;

                data_segment.appendBounded(byte) catch {
                    state.printError(.Error, errors.data_too_long, .{}, .{ .range = .{ .in_line = s } });
                    return error.InvalidDataSegment;
                };
            }
            state.reader.toss(original_line_len);
            return;
        }

        // not in data block
        const first_token = tokenizer.next().?;

        const first_is_label = first_token[first_token.len - 1] == ':';
        const first_ident = if (first_is_label) first_token[0 .. first_token.len - 1] else first_token;
        if (!state.checkStringIsIdent(first_ident)) return error.InvalidIdent;

        if (first_is_label) {
            logger.debug("label ':{s}' set at address 0x{x:0>3}", .{ first_ident, state.cur_addr });

            try state.labels.put(try state.alloc.dupe(u8, first_ident), state.cur_addr);
            // don't toss whole line, so label can start a line
            state.reader.toss(tokenizer.index);
            return;
        }

        if (mem.eql(u8, first_ident, "data")) {
            const second_token = tokenizer.peek();
            if (second_token == null) {
                state.printError(.Error, errors.lonely_data_ident, .{}, .{ .range = .{ .in_line = first_ident } });
                return error.InvalidSyntax;
            }
            // beginning of data segment, followed by a newline

            logger.debug("entering data segment at address 0x{x:0>3}", .{state.cur_addr});

            _ = tokenizer.next(); // consume second ('{') token
            if (tokenizer.peek()) |tok| {
                // line must end immediately after
                state.printError(.Error, errors.trailing_after_data_entry, .{tok}, .{ .range = .{ .in_line = tok } });
                return error.InvalidDataSegment;
            }
            state.reader.toss(original_line_len);

            assert(state.in_progress_data_segment == null);

            state.in_progress_data_segment = .initBuffer(&state.data_segment_buffer);

            return;
        }

        // first_ident is an instruction
        {
            const instr_info = MnemonicTable.get(first_ident) orelse {
                state.printError(.Error, errors.unknown_mnemonic, .{first_ident}, .{ .range = .{ .in_line = first_ident } });
                return error.UnknownMnemonic;
            };

            defer {
                logger.debug("cur addr = 0x{x:0>3}", .{state.cur_addr});
                state.cur_addr += @sizeOf(rom.Instruction);
            }

            const operand_kinds = InstructionInfo.OperandKindsByFormat[@intFromEnum(instr_info.format)];
            const entry: ParsedEntry = switch (instr_info.format) {
                .End_3NybAddr => .{ .addr_instr = .{
                    .kind = instr_info.category,
                    .addr = state.readAddrOperand(state.nextOperand(&tokenizer, true) orelse
                        return error.InvalidSyntax) orelse return error.InvalidSyntax,
                } },
                else => blk: {
                    var opers: u12 = 0;
                    var bit_offset: u4 = 0;
                    for (0.., operand_kinds) |i, oper| {
                        bit_offset += oper.bitSize();
                        if (oper == .unused) continue;
                        const is_last = (i >= operand_kinds.len - 1) or
                            mem.findNonePos(InstructionInfo.OperandKind, operand_kinds, i + 1, &.{.unused}) == null;
                        const oper_str = state.nextOperand(&tokenizer, is_last) orelse return error.InvalidSyntax;

                        const operand = oper.readFromState(state, oper_str) orelse return error.InvalidSyntax;
                        opers |= @as(u12, switch (operand) {
                            .unused, .addr => unreachable,
                            inline else => |v| v,
                        }) << @intCast(12 - bit_offset);
                    }
                    break :blk .{ .other_instr = .{ .instr = instr_info, .args = @bitCast(opers) } };
                },
            };

            try state.entries.append(state.alloc, entry);
            state.reader.toss(original_line_len);
        }
    }

    const OptionalStringContext = struct {
        filename: ?[]const u8 = null,
        line: ?[]const u8 = null,
        line_num: ?usize = null,
        range: ?union(enum) {
            in_line: []const u8,
            range: error_msgs.Range,
        } = null,
    };

    fn printError(
        state: *const As8ParserState,
        severity: error_msgs.LogLevel,
        comptime format: []const u8,
        args: anytype,
        context_overrides: OptionalStringContext,
    ) void {
        const line = context_overrides.line orelse state.context.line;

        error_msgs.printHighlightLineError(state.err_logger, severity, format, args, .{
            .filename = context_overrides.filename orelse state.context.filename,
            .line = context_overrides.line orelse state.context.line,
            .line_num = context_overrides.line_num orelse state.context.line_num,
            .range = if (context_overrides.range) |cor| switch (cor) {
                .in_line => |s| .fromSlice(u8, line.ptr, s),
                .range => |r| r,
            } else state.context.range,
        });
    }

    fn parseByteOrCharLiteral(state: *const As8ParserState, s: []const u8, line: []const u8) ?u8 {
        const err_context: OptionalStringContext = .{ .range = .{ .range = .fromSlice(u8, line.ptr, s) } };

        if (s[0] != '\'') {
            return std.fmt.parseUnsigned(u8, s, 0) catch blk: {
                state.printError(.Error, errors.invalid_byte_lit, .{s}, err_context);
                break :blk null;
            };
        }

        if (s[s.len - 1] != '\'') {
            state.printError(.Error, errors.invalid_char_lit_quoted, .{s}, .{ .range = .{ .in_line = s } });
            return null;
        }
        const res = std.zig.parseCharLiteral(s);

        return switch (res) {
            .success => |c| blk: {
                if (c > 0xff) {
                    state.printError(.Error, errors.char_lit_out_of_range, .{s}, err_context);
                    return null;
                }
                break :blk @intCast(c);
            },
            .failure => |err| blk: {
                state.printError(.Error, errors.invalid_char_lit ++ ": {f}", .{ s, err.fmt(s) }, err_context);
                break :blk null;
            },
        };
    }

    fn checkStringIsIdent(state: *As8ParserState, str: []const u8) bool {
        const valid_ident_first_char = "_" ++ ascii.letters;
        const valid_ident_chars = valid_ident_first_char ++ "0123456789";

        const first_char_is_valid = mem.findScalar(u8, valid_ident_first_char, str[0]) != null;
        const next_chars_are_valid = mem.findNone(u8, str[1..], valid_ident_chars) == null;

        if (!first_char_is_valid or !next_chars_are_valid) {
            state.printError(.Error, errors.invalid_ident, .{str}, .{ .range = .{ .in_line = str } });
            return false;
        }

        return true;
    }

    fn nextOperand(state: *As8ParserState, tokens: *mem.TokenIterator(u8, .any), is_last_operand: bool) ?[]const u8 {
        const token = tokens.next() orelse return null;
        if (is_last_operand and token[token.len - 1] == ',') {
            state.printError(.Error, errors.comma_illegal_after_arg, .{}, .{ .range = .{ .in_line = token[token.len - 1 .. token.len] } });
            return null;
        } else if (!is_last_operand and token[token.len - 1] != ',') {
            state.printError(.Error, errors.comma_required_after_arg, .{}, .{ .range = .{ .in_line = token } });
            return null;
        }

        //std.debug.print("got arg slice '{s}'\n", .{state.current_context.line[new_start..new_end]});
        return if (is_last_operand) token else token[0 .. token.len - 1];
    }

    /// ':label_name' or '$XXX'
    fn readAddrOperand(state: *As8ParserState, s: []const u8) ?AddressValue {
        // std.debug.print("reading address operand from '{s}'\n", .{arg});
        const context: error_msgs.StringContextInfo = .{
            .filename = state.context.filename,
            .line_num = state.context.line_num,
            .line = state.context.line,
            .range = .fromSlice(u8, state.context.line.ptr, s),
        };

        // '$XXX' immediate address
        if (s[0] == '$' and ascii.isHex(s[1]) and ascii.isHex(s[2]) and ascii.isHex(s[3])) {
            return .{ .addr = std.fmt.parseInt(chip.Addr, s[1..4], 16) catch unreachable };
        }

        // must be a label name otherwise
        if (s[0] != ':') {
            state.printError(.Error, errors.invalid_addr_spec, .{s}, .{ .range = .{ .in_line = s } });
            return null;
        }
        if (!state.checkStringIsIdent(s[1..])) return null;

        // label is resolved
        if (state.labels.get(s[1..])) |a| {
            return .{ .addr = a };
        }

        // label not yet resolved
        logger.debug("unresolved label '{s}'", .{s});
        state.uninited_addr_entries.append(state.alloc, .{ .index = state.entries.items.len, .context = .{
            .line = state.alloc.dupe(u8, context.line) catch @panic("OOM"),
            .range = .fromSlice(u8, state.context.line.ptr, s),
        } }) catch @panic("OOM");

        return .{ .label = state.alloc.dupe(u8, s[1..]) catch @panic("OOM") };
    }

    /// '#num', num is 8 bits
    fn readImmOperand(state: *As8ParserState, arg: []const u8, comptime RetType: type) ?RetType {
        comptime assert(RetType == u8 or RetType == u4);

        if (arg[0] != '#' or arg.len < 2) {
            state.printError(.Error, errors.invalid_imm_spec, .{arg}, .{ .range = .{ .in_line = arg } });
            return null;
        }

        return std.fmt.parseInt(RetType, arg[1..], 0) catch {
            state.printError(.Error, errors.invalid_imm_spec, .{arg}, .{ .range = .{ .in_line = arg } });
            return null;
        };
    }

    fn readRegOperand(state: *As8ParserState, arg: []const u8) ?u4 {
        if (!(arg[0] == 'v' or arg[0] == 'V') or arg.len != 2) {
            state.printError(.Error, errors.invalid_reg_spec, .{arg}, .{ .range = .{ .in_line = arg } });
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

    pub const EntryIndexWithContext = struct {
        index: usize,
        /// the `line` field of `context` is heap-allocated
        context: struct {
            line: []const u8,
            range: error_msgs.Range,
        },
    };

    pub const ParsedEntry = union(enum) {
        addr_instr: struct {
            kind: rom.Instruction.Category,
            addr: AddressValue,
        },
        other_instr: struct {
            instr: InstructionInfo,
            args: rom.Instruction.Operands = @bitCast(@as(u12, 0)),
        },
        data_segment: []const u8,

        pub fn serialize(self: @This(), state: ?As8ParserState, writer: *std.Io.Writer) !void {
            return switch (self) {
                .addr_instr => |ai| writer.writeInt(u16, (@as(u16, @intFromEnum(ai.kind)) << 12) | switch (ai.addr) {
                    .label => |l| state.?.labels.get(l) orelse return error.UnknownLabel,
                    .addr => |a| a,
                }, .big),
                .other_instr => |oi| writer.writeInt(u16, switch (oi.instr.format) {
                    .End_RegImm, .End_TwoRegAndImm => oi.instr.fill | @as(u16, @intCast(@as(u12, @bitCast(oi.args)))),
                    .Middle_TwoReg => oi.instr.fill | @as(u16, @intCast(@as(u12, @bitCast(oi.args)) & 0xFF0)),
                    .Nyb1_OneReg => oi.instr.fill | @as(u16, @intCast(@as(u12, @bitCast(oi.args)) & 0xF00)),
                    .Nyb3_OneReg => oi.instr.fill | @as(u16, @intCast(@as(u12, @bitCast(oi.args)) & 0x00F)),
                    .NoOperands => oi.instr.fill,
                    else => unreachable,
                }, .big),
                .data_segment => |ds| writer.writeAll(ds),
            };
        }
        test serialize {
            const expected_pairs = [_]struct { u16, ParsedEntry }{
                .{ 0x1202, ParsedEntry{ .addr_instr = .{ .kind = .jmp, .addr = .{ .addr = 0x202 } } } },
                .{ 0xd019, ParsedEntry{ .other_instr = .{ .instr = MnemonicTable.get("draw").?, .args = .{ .reg_reg_imm = .{ .regR = 0x0, .regY = 0x1, .imm = 9 } } } } },
                .{ 0x83f3, ParsedEntry{ .other_instr = .{ .instr = MnemonicTable.get("xorr").?, .args = .{ .reg_reg_unused = .{ .regR = 0x3, .regY = 0xf, .unused = 0 } } } } },
                .{ 0x22ac, ParsedEntry{ .addr_instr = .{ .kind = .jsl, .addr = .{ .addr = 0x2ac } } } },
                .{ 0x00ee, ParsedEntry{ .other_instr = .{ .instr = MnemonicTable.get("ret").? } } },
                .{ 0x00e0, ParsedEntry{ .other_instr = .{ .instr = MnemonicTable.get("cls").? } } },
                .{ 0xe9a1, ParsedEntry{ .other_instr = .{ .instr = MnemonicTable.get("skup").?, .args = .{ .nybble_byte = .{ .nybble = 0x9, .byte = 0 } } } } },
                .{ 0x01b3, ParsedEntry{ .other_instr = .{ .instr = MnemonicTable.get("dbgrid").?, .args = .{ .byte_nybble = .{ .byte = 0, .nybble = 0x3 } } } } },
            };

            var ret_buffer: [2]u8 = undefined;
            var fixed_writer: Io.Writer = .fixed(&ret_buffer);

            for (expected_pairs) |pair| {
                try pair.@"1".serialize(null, &fixed_writer);
                const actual = mem.readInt(u16, &ret_buffer, .big);
                try testing.expectEqual(pair.@"0", actual);
                fixed_writer.end = 0;
            }
        }
    };

    pub const AddressValue = union(enum) {
        label: []const u8,
        addr: chip.Addr,
    };
};

test {
    _ = MnemonicTable;
    _ = As8ParserState;
}
