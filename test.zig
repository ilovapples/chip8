const std = @import("std");
const expect = std.testing.expect;

fn deref(i: anytype) @typeInfo(@TypeOf(i)).pointer.child {
    comptime std.debug.assert(@typeInfo(@TypeOf(i)) == .pointer);
    return i.*;
}

test {
    try expect(deref(&8) == 9);
}
