const std = @import("std");
const posix = std.posix;
const shm = @import("shmallocator.zig");

pub const Test = struct { a: u32, b: u16, c: []const u8 };

pub fn main() !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    var pool = try shm.ShmPool.openPath(io, "/dev/shm", "shm_test", 64 * 1024);
    defer pool.close();

    const msg = pool.read(struct { text: []const u8, tes: Test }) orelse return;

    std.debug.print("{s}", .{msg.text.get()});
    std.debug.print("{} {} {s}\n", .{ msg.tes.a, msg.tes.b, msg.tes.c.get() });
}
