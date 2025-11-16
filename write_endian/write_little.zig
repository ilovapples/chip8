const write_endian = @import("write_endian.zig");
pub fn main() !void {
    try write_endian.write_endian(.little);
}
