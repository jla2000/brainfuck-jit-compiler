const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const code = try generate_bytecode(allocator, ".,");
    defer code.deinit();

    try execute_bytecode(code.items);
}

fn write_handler(tape_ptr: *u8) callconv(.C) void {
    std.debug.print("Write called with ptr={}\n", .{tape_ptr});
}

fn read_handler(tape_ptr: *u8) callconv(.C) void {
    std.debug.print("Read called with ptr={}\n", .{tape_ptr});
}

fn generate_bytecode(allocator: std.mem.Allocator, instructions: []const u8) !std.ArrayList(u8) {
    var code = std.ArrayList(u8).init(allocator);

    const amount = 1;

    for (instructions) |instruction| {
        switch (instruction) {
            '+' => try code.appendSlice(&.{
                0x80, 0x07, amount, // add byte ptr [rdi], amount
            }),
            '-' => try code.appendSlice(&.{
                0x80, 0x2F, amount, // sub byte ptr [rdi], amount
            }),
            '>' => try code.appendSlice(&.{
                0x48, 0x83, 0xC7, amount, // add rdi, amount
            }),
            '<' => try code.appendSlice(&.{
                0x48, 0x83, 0xEF, amount, // sub rdi, amount
            }),
            '.' => try code.appendSlice(&.{
                0x57, // push rdi
                0x56, // push rsi
                0x52, // push rdx
                0xFF, 0xD6, // call rsi
                0x5A, // pop rdx
                0x5E, // pop rsi
                0x5F, // pop rdi
            }),
            ',' => try code.appendSlice(&.{
                0x57, // push rdi
                0x56, // push rsi
                0x52, // push rdx
                0xFF, 0xD2, // call rdx
                0x5A, // pop rdx
                0x5E, // pop rsi
                0x5F, // pop rdi
            }),
            else => {},
        }
    }

    try code.append(0xC3); // ret

    return code;
}

fn execute_bytecode(code: []u8) !void {
    const protection = std.posix.PROT.WRITE | std.posix.PROT.READ | std.posix.PROT.EXEC;
    const flags = .{ .ANONYMOUS = true, .TYPE = .PRIVATE };

    const page_buffer = try std.posix.mmap(null, code.len, protection, flags, -1, 0);
    defer std.posix.munmap(page_buffer);

    @memcpy(page_buffer, code);

    var tape = std.mem.zeroes([30000]u8);

    const execute_code: *const fn (
        tape_ptr: *const u8,
        write_fn: *const fn (*u8) callconv(.C) void,
        read_fn: *const fn (*u8) callconv(.C) void,
    ) callconv(.C) void = @ptrCast(page_buffer.ptr);

    execute_code(@ptrCast(&tape), &write_handler, &read_handler);
}
