const std = @import("std");

pub fn ShmPtr(comptime T: type) type {
    return struct {
        const Self = @This();

        relative_offset: i32 = 0,

        pub inline fn get(self: *const Self) ?*T {
            if (self.relative_offset == 0) return null;

            const self_addr = @intFromPtr(self);
            const target_addr = @as(usize, @intCast(@as(isize, @bitCast(self_addr)) + self.relative_offset));
            return @ptrFromInt(target_addr);
        }

        pub inline fn point_to(self: *Self, target: ?*T) void {
            const target_ptr = target orelse {
                self.relative_offset = 0;
                return;
            };

            const self_addr = @intFromPtr(self);
            const target_addr = @intFromPtr(target_ptr);
            const diff = @as(isize, @bitCast(target_addr)) - @as(isize, @bitCast(self_addr));
            self.relative_offset = @intCast(diff);
        }
    };
}

/// `ShmPtr` but the target type is resolved through `targetType`.
/// used for self-referential structs
pub fn ShmPtrLazy(comptime T: type, comptime targetType: fn (type) type) type {
    return struct {
        const Self = @This();

        pub const ChildType = targetType(T);

        relative_offset: i32 = 0,

        pub inline fn get(self: *const Self) ?*ChildType {
            if (self.relative_offset == 0) return null;

            const self_addr = @intFromPtr(self);
            const target_addr = @as(usize, @intCast(@as(isize, @bitCast(self_addr)) + self.relative_offset));
            return @ptrFromInt(target_addr);
        }

        pub inline fn point_to(self: *Self, target: ?*ChildType) void {
            const target_ptr = target orelse {
                self.relative_offset = 0;
                return;
            };

            const self_addr = @intFromPtr(self);
            const target_addr = @intFromPtr(target_ptr);
            const diff = @as(isize, @bitCast(target_addr)) - @as(isize, @bitCast(self_addr));
            self.relative_offset = @intCast(diff);
        }
    };
}

fn sameType(comptime T: type) type {
    return T;
}

/// a slice stored as an offset relative to its own address
pub fn ShmSlice(comptime T: type) type {
    return ShmSliceLazy(T, sameType);
}

/// `ShmSlice` but the target type is resolved through `targetType`.
/// used for self-referential structs
pub fn ShmSliceLazy(comptime T: type, comptime targetType: fn (type) type) type {
    return struct {
        const Self = @This();

        pub const is_shm_slice = true;
        pub const ChildType = targetType(T);

        relative_offset: i32 = 0,
        len: usize = 0,

        pub inline fn get(self: *const Self) []const ChildType {
            if (self.relative_offset == 0 or self.len == 0) return &.{};

            const self_addr = @intFromPtr(self);
            const target_addr = @as(usize, @intCast(@as(isize, @bitCast(self_addr)) + self.relative_offset));
            return @as([*]const ChildType, @ptrFromInt(target_addr))[0..self.len];
        }

        pub inline fn point_to(self: *Self, slice: []const ChildType) void {
            self.len = slice.len;
            if (slice.len == 0) {
                self.relative_offset = 0;
                return;
            }

            const self_addr = @intFromPtr(self);
            const target_addr = @intFromPtr(slice.ptr);
            const diff = @as(isize, @bitCast(target_addr)) - @as(isize, @bitCast(self_addr));
            self.relative_offset = @intCast(diff);
        }
    };
}

pub fn ShmManyPtr(comptime T: type) type {
    return ShmManyPtrLazy(T, sameType);
}

pub fn ShmManyPtrLazy(comptime T: type, comptime targetType: fn (type) type) type {
    return struct {
        const Self = @This();

        pub const is_shm_many_ptr = true;
        pub const ChildType = targetType(T);

        relative_offset: isize = 0,

        pub inline fn get(self: *const Self) ?[*]ChildType {
            if (self.relative_offset == 0) return null;

            const self_addr = @intFromPtr(self);
            const target_addr = @as(usize, @intCast(@as(isize, @bitCast(self_addr)) + self.relative_offset));
            return @ptrFromInt(target_addr);
        }

        pub inline fn point_to(self: *Self, target: ?[*]const ChildType) void {
            const target_ptr = target orelse {
                self.relative_offset = 0;
                return;
            };

            const self_addr = @intFromPtr(self);
            const target_addr = @intFromPtr(target_ptr);
            self.relative_offset = @as(isize, @bitCast(target_addr)) - @as(isize, @bitCast(self_addr));
        }
    };
}

pub fn ShmFnPtr(comptime T: type) type {
    return ShmFnPtrLazy(T, sameType);
}

pub fn ShmFnPtrLazy(comptime T: type, comptime targetType: fn (type) type) type {
    return struct {
        const Self = @This();

        pub const ChildType = targetType(T);

        relative_offset: isize = 0,

        pub inline fn get(self: *const Self) ?*ChildType {
            if (self.relative_offset == 0) return null;

            const self_addr = @intFromPtr(self);
            const target_addr = @as(usize, @intCast(@as(isize, @bitCast(self_addr)) + self.relative_offset));
            return @ptrFromInt(target_addr);
        }

        pub inline fn point_to(self: *Self, target: ?*const ChildType) void {
            const target_ptr = target orelse {
                self.relative_offset = 0;
                return;
            };

            const self_addr = @intFromPtr(self);
            const target_addr = @intFromPtr(target_ptr);
            self.relative_offset = @as(isize, @bitCast(target_addr)) - @as(isize, @bitCast(self_addr));
        }
    };
}
