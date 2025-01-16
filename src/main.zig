const std = @import("std");

const TAPE_SIZE = 30000;

const Operation = enum(u8) {
    INC,
    DEC,
    NEXT,
    PREV,
    READ,
    WRITE,
    JMP_IF_ZERO,
    JMP_IF_NOT_ZERO,
};

const Instruction = struct {
    op: Operation,
    amount: usize,
};

const EntryPoint = fn (
    tape_ptr: ?*const u8,
    write: ?*fn (u8) void,
    read: ?*fn () u8,
) void;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const code = try generate_bytecode(allocator);
    defer code.deinit();

    try execute_bytecode(code.items);
}

fn generate_bytecode(allocator: std.mem.Allocator) !std.ArrayList(u8) {
    var code = std.ArrayList(u8).init(allocator);

    try code.appendSlice(&.{ 0x48, 0x31, 0xC0 }); // xor rax, rax
    try code.append(0xC3); // ret

    return code;
}

fn execute_bytecode(code: []u8) !void {
    const protection = std.posix.PROT.WRITE | std.posix.PROT.READ | std.posix.PROT.EXEC;
    const flags = .{ .ANONYMOUS = true, .TYPE = .PRIVATE };

    const page_buffer = try std.posix.mmap(null, code.len, protection, flags, -1, 0);
    defer std.posix.munmap(page_buffer);

    @memcpy(page_buffer, code);

    const execute_code: *const EntryPoint = @ptrCast(page_buffer.ptr);
    execute_code(null, null, null);
}
