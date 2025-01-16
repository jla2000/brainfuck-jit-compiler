const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();

    try code.append(0x00);
}
