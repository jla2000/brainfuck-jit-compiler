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

fn write_handler(data_ptr: *u8) callconv(.C) void {
    stdout.writeByte(data_ptr.*) catch {};
}

fn read_handler(data_ptr: *u8) callconv(.C) void {
    data_ptr.* = stdin.readByte() catch 0;
}

const LoopElement = struct {
    jump_address: usize,
    next_address: usize,
};

const Loop = struct {
    begin: LoopElement,
    end: LoopElement,
};

// rdi -> data pointer
// rsi -> write function address
// rdx -> read function address
fn generate_bytecode(allocator: std.mem.Allocator, instructions: []const u8) !std.ArrayList(u8) {
    std.debug.print("Compiling...\n", .{});

    var code = std.ArrayList(u8).init(allocator);
    var loop_start = std.ArrayList(LoopElement).init(allocator);
    var loops = std.ArrayList(Loop).init(allocator);

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
                try loop_start.append(LoopElement{
                    .jump_address = jump,
                    .next_address = code.items.len,
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
                try loops.append(Loop{
                    .begin = loop_start.pop(),
                    .end = LoopElement{
                        .jump_address = jump,
                        .next_address = code.items.len,
                    },
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

    for (loops.items) |loop| {
        write_jump_offset(code.items, loop.begin.jump_address, loop.end.next_address);
        write_jump_offset(code.items, loop.end.jump_address, loop.begin.next_address);
    }

    return code;
}

fn write_jump_offset(
    code: []u8,
    jump_address: usize,
    target_address: usize,
) void {
    const JUMP_OPCODE_SIZE = 6;
    const JUMP_OPERAND_OFFSET = 2;
    const relative_offset: u32 = @truncate(target_address -% jump_address - JUMP_OPCODE_SIZE);
    std.mem.writeInt(u32, @ptrCast(&code[jump_address + JUMP_OPERAND_OFFSET]), relative_offset, .little);
}

fn execute_bytecode(code: []u8) !void {
    const data_size = 30000;

    const data_buffer = try std.posix.mmap(null, data_size, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .ANONYMOUS = true, .TYPE = .PRIVATE }, -1, 0);
    const code_buffer = try std.posix.mmap(null, code.len, std.posix.PROT.READ | std.posix.PROT.WRITE | std.posix.PROT.EXEC, .{ .ANONYMOUS = true, .TYPE = .PRIVATE }, -1, 0);

    defer std.posix.munmap(data_buffer);
    defer std.posix.munmap(code_buffer);

    @memset(data_buffer, 0);
    @memcpy(code_buffer[0..code.len], code);

    std.debug.print("Preparing memory...\n", .{});
    std.debug.print("Code : {x} - {x} -> {d} bytes\n", .{ &code_buffer[0], &code_buffer[code_buffer.len - 1], code_buffer.len });
    std.debug.print("Data : {x} - {x} -> {d} bytes\n", .{ &data_buffer[0], &data_buffer[data_buffer.len - 1], data_buffer.len });
    std.debug.print("Executing bytecode...\n", .{});

    const execute_code: *const fn (
        data_ptr: *const u8,
        write_fn: *const fn (*u8) callconv(.C) void,
        read_fn: *const fn (*u8) callconv(.C) void,
    ) callconv(.C) void = @ptrCast(code_buffer.ptr);

    execute_code(&data_buffer[0], &write_handler, &read_handler);
}

fn save_bytecode(filename: []const u8, code: []u8) !void {
    const file = try std.fs.cwd().createFile(filename, .{});
    defer file.close();

    _ = try file.write(code);
}
