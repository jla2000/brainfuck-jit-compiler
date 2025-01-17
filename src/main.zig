const std = @import("std");

const Instruction = enum(u8) {
    INC_CELL,
    DEC_CELL,
    NEXT_CELL,
    PREV_CELL,
    READ_CELL,
    WRITE_CELL,
    JMP_IF_ZERO,
    JMP_IF_NOT_ZERO,
};

const EntryPoint = fn (
    tape_ptr: *const u8,
) callconv(.C) void;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const code = try generate_bytecode(allocator, &.{ .INC_CELL, .NEXT_CELL, .INC_CELL, .PREV_CELL, .DEC_CELL });
    defer code.deinit();

    try execute_bytecode(code.items);
}

fn generate_bytecode(allocator: std.mem.Allocator, instructions: []const Instruction) !std.ArrayList(u8) {
    var code = std.ArrayList(u8).init(allocator);

    const amount = 1;

    for (instructions) |instruction| {
        switch (instruction) {
            .INC_CELL => try code.appendSlice(&.{ 0x80, 0x07, amount }), // add byte ptr [rdi], amount
            .DEC_CELL => try code.appendSlice(&.{ 0x80, 0x2F, amount }), // sub byte ptr [rdi], amount
            .NEXT_CELL => try code.appendSlice(&.{ 0x48, 0x83, 0xC7, amount }), // add rdi, amount
            .PREV_CELL => try code.appendSlice(&.{ 0x48, 0x83, 0xEF, amount }), // sub rdi, amount
            else => {},
        }
    }

    try code.appendSlice(&.{ 0x48, 0x83, 0xC7, 0x02 }); // add rdi, 0x2
    try code.appendSlice(&.{ 0xC6, 0x07, 0xFF }); // mov BYTE PTR [rdi], 0xff
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
    const execute_code: *const EntryPoint = @ptrCast(page_buffer.ptr);
    execute_code(@ptrCast(&tape));

    std.debug.print("0: {}, 1: {}\n", .{ tape[0], tape[1] });
}
