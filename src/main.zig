const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    if (std.os.argv.len != 2) {
        std.debug.print("Usage: ./brainfuck-jit-compiler <FILENAME>\n", .{});
        return;
    }

    const filename = std.mem.span(std.os.argv[1]);
    const program_file = try std.fs.cwd().openFile(filename, .{});
    defer program_file.close();
    const program = try program_file.readToEndAlloc(allocator, 0xFFFF);

    const bytecode = try generate_bytecode(allocator, program);
    defer bytecode.deinit();

    try save_bytecode("debug.bin", bytecode.items);
    try execute_bytecode(bytecode.items);
}

const stdout = std.io.getStdOut().writer();
const stdin = std.io.getStdIn().reader();

fn write_handler(tape_ptr: *u8) callconv(.C) void {
    stdout.writeByte(tape_ptr.*) catch {};
}

fn read_handler(tape_ptr: *u8) callconv(.C) void {
    tape_ptr.* = stdin.readByte() catch 0;
}

const LoopElement = struct {
    jump_address: usize,
    after_address: usize,
};

// rdi -> tape pointer
// rsi -> write function address
// rdx -> read function address
fn generate_bytecode(allocator: std.mem.Allocator, instructions: []const u8) !std.ArrayList(u8) {
    var code = std.ArrayList(u8).init(allocator);
    var loop_start = std.ArrayList(LoopElement).init(allocator);
    var loop_end = std.ArrayList(LoopElement).init(allocator);

    var amount: u8 = 1;

    for (instructions, 0..) |instruction, index| {
        switch (instruction) {
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
            '[' => {
                try code.appendSlice(&.{
                    0x80, 0x3F, 0x00, // cmp byte ptr [rdi], 0
                });
                const jump = code.items.len;
                try code.appendSlice(&.{
                    0x0F, 0x84, 0x00, 0x00, 0x00, 0x00, // jz rel32
                });
                const after = code.items.len;
                try loop_start.append(LoopElement{
                    .jump_address = jump,
                    .after_address = after,
                });
            },
            ']' => {
                try code.appendSlice(&.{
                    0x80, 0x3F, 0x00, // cmp byte ptr [rdi], 0
                });
                const jump = code.items.len;
                try code.appendSlice(&.{
                    0x0F, 0x85, 0x00, 0x00, 0x00, 0x00, // jnz rel32
                });
                const after = code.items.len;
                try loop_end.append(LoopElement{
                    .jump_address = jump,
                    .after_address = after,
                });
            },
            else => {
                const next_index = index + 1;
                if (next_index < instructions.len and instructions[next_index] == instruction) {
                    amount += 1;
                    continue;
                }

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
                    else => {},
                }

                amount = 1;
            },
        }
    }

    try code.append(0xC3); // ret

    std.debug.assert(loop_start.items.len == loop_end.items.len);

    for (loop_start.items, loop_end.items) |loop_start_element, loop_end_element| {
        write_jump_address(code.items, loop_start_element.jump_address, loop_end_element.after_address);
        write_jump_address(code.items, loop_end_element.jump_address, loop_start_element.after_address);
    }

    return code;
}

fn calculate_relative_jump_offset(
    jump_address: usize,
    target_address: usize,
) u32 {
    const JUMP_OPCODE_SIZE = 6;
    return @truncate(target_address -% jump_address - JUMP_OPCODE_SIZE);
}

fn write_jump_address(
    code: []u8,
    jump_address: usize,
    target_address: usize,
) void {
    const JUMP_OPERAND_OFFSET = 2;
    const relative_offset = calculate_relative_jump_offset(jump_address, target_address);
    write_u32(code, jump_address + JUMP_OPERAND_OFFSET, relative_offset);
}

fn write_u32(code: []u8, offset: usize, value: u32) void {
    code[offset + 3] = @truncate(value >> 24);
    code[offset + 2] = @truncate(value >> 16);
    code[offset + 1] = @truncate(value >> 8);
    code[offset + 0] = @truncate(value);
}

fn execute_bytecode(code: []u8) !void {
    const tape_size = 30000;

    const tape_buffer = try std.posix.mmap(null, tape_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .ANONYMOUS = true, .TYPE = .PRIVATE }, -1, 0);
    const code_buffer = try std.posix.mmap(null, code.len, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC, .{ .ANONYMOUS = true, .TYPE = .PRIVATE }, -1, 0);

    defer std.posix.munmap(tape_buffer);
    defer std.posix.munmap(code_buffer);

    @memset(tape_buffer, 0);
    @memcpy(code_buffer[0..code.len], code);

    std.debug.print("Code base address: {x}\n", .{&code_buffer[0]});
    std.debug.print("Tape base address: {x}\n", .{&tape_buffer[0]});
    std.debug.print("Tape end address:  {x}\n", .{&tape_buffer[tape_buffer.len - 1]});

    const execute_code: *const fn (
        tape_ptr: *const u8,
        write_fn: *const fn (*u8) callconv(.C) void,
        read_fn: *const fn (*u8) callconv(.C) void,
    ) callconv(.C) void = @ptrCast(code_buffer.ptr);

    execute_code(&tape_buffer[0], &write_handler, &read_handler);
}

fn save_bytecode(filename: []const u8, code: []u8) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    _ = try file.write(code);
}
