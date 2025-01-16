const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();

    try code.appendSlice(&.{ 0x48, 0x31, 0xC0 }); // xor rax, rax
    try code.append(0xC3); // ret

    try execute_bytecode(code.items);
}

fn execute_bytecode(code: []u8) !void {
    const protection = std.posix.PROT.WRITE | std.posix.PROT.READ | std.posix.PROT.EXEC;
    const flags = .{ .ANONYMOUS = true, .TYPE = .PRIVATE };

    const page_buffer = try std.posix.mmap(null, code.len, protection, flags, -1, 0);
    defer std.posix.munmap(page_buffer);

    @memcpy(page_buffer, code);

    const execute_code: *fn () void = @ptrCast(page_buffer.ptr);
    execute_code();
}
