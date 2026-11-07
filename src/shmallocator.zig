const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;
const shmptr = @import("shmptr.zig");
const ShmPtr = shmptr.ShmPtr;
const ShmPtrLazy = shmptr.ShmPtrLazy;
const ShmSlice = shmptr.ShmSlice;
const ShmSliceLazy = shmptr.ShmSliceLazy;
const ShmManyPtrLazy = shmptr.ShmManyPtrLazy;
const ShmFnPtrLazy = shmptr.ShmFnPtrLazy;

const ShmAllocator = @This();

end_index: usize,
buffer: []u8,
header: ?*Header = null,

pub fn init(buffer: []u8) ShmAllocator {
    return .{
        .buffer = buffer,
        .end_index = 0,
    };
}

pub fn initShared(buffer: []u8, header: *Header) ShmAllocator {
    return .{
        .buffer = buffer,
        .end_index = 0,
        .header = header,
    };
}

inline fn loadEnd(self: *const ShmAllocator) usize {
    if (self.header) |header| return header.end_index.load(.seq_cst);
    return @atomicLoad(usize, &self.end_index, .seq_cst);
}

inline fn storeEnd(self: *ShmAllocator, value: usize) void {
    if (self.header) |header| {
        header.end_index.store(value, .seq_cst);
    } else {
        @atomicStore(usize, &self.end_index, value, .seq_cst);
    }
}

inline fn casEnd(self: *ShmAllocator, expected: usize, new_value: usize) bool {
    if (self.header) |header| {
        return header.end_index.cmpxchgWeak(expected, new_value, .seq_cst, .seq_cst) == null;
    }
    return @cmpxchgWeak(usize, &self.end_index, expected, new_value, .seq_cst, .seq_cst) == null;
}

fn bump(self: *ShmAllocator, n: usize, ptr_align: usize) ?[*]u8 {
    var end = self.loadEnd();
    while (true) {
        const adjust_off = mem.alignPointerOffset(self.buffer.ptr + end, ptr_align) orelse return null;
        const adjusted_index = end + adjust_off;
        const new_end_index = adjusted_index + n;
        if (new_end_index > self.buffer.len) return null;
        if (self.casEnd(end, new_end_index)) return self.buffer.ptr + adjusted_index;
        end = self.loadEnd();
    }
}

pub fn ToShmType(comptime T: type) type {
    if (isShmPtrInstance(T) or isShmManyPtrInstance(T) or isShmSliceInstance(T)) return T;
    return switch (@typeInfo(T)) {
        .@"struct" => ToShmStruct(T),
        .pointer => |p| switch (p.size) {
            .one => if (@typeInfo(p.child) == .@"fn") ShmFnPtrLazy(p.child, toShmTarget) else ShmPtrLazy(p.child, toShmTarget),
            .slice => ShmSliceLazy(p.child, toShmTarget),
            .many, .c => ShmManyPtrLazy(p.child, toShmTarget),
        },
        .optional => |o| if (@typeInfo(o.child) == .pointer and @typeInfo(o.child).pointer.size == .one)
            ShmPtrLazy(@typeInfo(o.child).pointer.child, toShmTarget)
        else
            ?ToShmType(o.child),
        .array => |a| [a.len]ToShmType(a.child),
        .@"union" => |u| ToShmUnion(u),
        else => T,
    };
}

fn ToShmUnion(comptime u: std.lang.Type.Union) type {
    const len = u.field_names.len;

    comptime var field_names: [len][]const u8 = undefined;
    comptime var field_types: [len]type = undefined;

    inline for (u.field_names, u.field_types, 0..) |name, field_type, i| {
        field_names[i] = name;
        field_types[i] = ToShmType(field_type);
    }

    return if (u.tag_type) |Tag|
        @Union(u.layout, Tag, &field_names, &field_types, &@splat(.{}))
    else
        @Union(u.layout, null, &field_names, &field_types, &@splat(.{}));
}

fn toShmTarget(comptime T: type) type {
    return ToShmType(T);
}

fn ToShmStruct(comptime T: type) type {
    const struct_info = @typeInfo(T).@"struct";
    const len = struct_info.field_names.len;

    comptime var field_names: [len][]const u8 = undefined;
    comptime var field_types: [len]type = undefined;
    comptime var field_attrs: [len]std.lang.Type.Struct.FieldAttributes = undefined;

    inline for (struct_info.field_names, struct_info.field_types, 0..) |name, field_type, i| {
        field_names[i] = name;
        const FieldShmType = ToShmType(field_type);
        field_types[i] = FieldShmType;
        if (comptime isShmPtrInstance(FieldShmType) or isShmSliceInstance(FieldShmType)) {
            field_attrs[i] = .{ .default_value_ptr = &FieldShmType{} };
        } else {
            field_attrs[i] = .{};
        }
    }

    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

pub fn deepCopyAndConvert(self: *ShmAllocator, comptime DestType: type, dest: *DestType, src: anytype) !void {
    try self.deepCopy(DestType, dest, src);
}

fn deepCopy(self: *ShmAllocator, comptime DestType: type, dest: *DestType, src: anytype) !void {
    switch (@typeInfo(DestType)) {
        .@"struct" => {
            if (comptime isShmSliceInstance(DestType)) {
                const ChildType = DestType.ChildType;
                if (src.len == 0) {
                    dest.point_to(&.{});
                } else {
                    const dest_slice = try self.allocator().alloc(ChildType, src.len);
                    for (dest_slice, src) |*d, s| try self.deepCopy(ChildType, d, s);
                    dest.point_to(dest_slice);
                }
            } else if (comptime isShmPtrInstance(DestType)) {
                const src_info = @typeInfo(@TypeOf(src));
                const ChildSrcType = switch (src_info) {
                    .pointer => |p| p.child,
                    .optional => @typeInfo(src_info.optional.child).pointer.child,
                    else => @compileError("converted pointer field must come from *T or ?*T"),
                };
                const src_ptr: ?*const ChildSrcType = src;
                if (src_ptr) |p| {
                    if (comptime @typeInfo(ChildSrcType) == .@"fn") {
                        dest.point_to(@constCast(p));
                    } else {
                        dest.point_to(try self.create(ChildSrcType, p.*));
                    }
                } else {
                    dest.point_to(null);
                }
            } else if (comptime isShmManyPtrInstance(DestType)) {
                const src_ptr: ?[*]const DestType.ChildType = @ptrCast(src);
                dest.point_to(src_ptr);
            } else {
                const struct_info = @typeInfo(DestType).@"struct";
                inline for (struct_info.field_names) |name| {
                    try self.deepCopy(@FieldType(DestType, name), &@field(dest, name), @field(src, name));
                }
            }
        },
        .array => |a| {
            for (dest, src) |*d, s| try self.deepCopy(a.child, d, s);
        },
        .@"union" => |u| {
            const src_info = @typeInfo(@TypeOf(src)).@"union";
            if (src_info.tag_type != null) {
                switch (std.meta.activeTag(src)) {
                    inline else => |tag| {
                        const name = @tagName(tag);
                        const PayloadDest = @FieldType(DestType, name);
                        if (comptime u.layout == .@"packed")
                            @compileError("packed unions cannot be deep copied in place");
                        dest.* = @unionInit(DestType, name, undefined);
                        const payload_ptr: *PayloadDest = @ptrCast(@alignCast(dest));
                        try self.deepCopy(PayloadDest, payload_ptr, @field(src, name));
                    },
                }
            } else {
                inline for (u.field_types) |FT| {
                    if (comptime @sizeOf(ToShmType(FT)) != @sizeOf(FT))
                        @compileError("untagged union with converted field sizes cannot be deep copied");
                }
                @memcpy(std.mem.asBytes(dest), std.mem.asBytes(&src));
            }
        },
        .optional => |o| {
            if (src) |src_payload| {
                const ChildType = o.child;
                dest.* = @as(?ChildType, emptyValue(ChildType));
                if (dest.*) |*dest_payload| {
                    try self.deepCopy(ChildType, dest_payload, src_payload);
                }
            } else {
                dest.* = null;
            }
        },
        else => dest.* = src,
    }
}

fn emptyValue(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .@"union" => |u| @unionInit(T, u.field_names[0], undefined),
        else => std.mem.zeroes(T),
    };
}

fn isShmPtrInstance(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and
        !@hasDecl(T, "is_shm_slice") and
        !@hasDecl(T, "is_shm_many_ptr") and
        @hasDecl(T, "point_to") and
        @hasDecl(T, "get");
}

fn isShmSliceInstance(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_shm_slice");
}

fn isShmManyPtrInstance(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "is_shm_many_ptr");
}

pub fn allocConverted(self: *ShmAllocator, src: anytype) !*ToShmType(@TypeOf(src)) {
    const SrcType = @TypeOf(src);
    const DestType = ToShmType(SrcType);

    const slice = try self.allocator().alloc(DestType, 1);
    const dest_ref = &slice[0];

    try self.deepCopyAndConvert(DestType, dest_ref, src);

    return dest_ref;
}

pub fn create(self: *ShmAllocator, comptime T: type, src: T) !*ToShmType(T) {
    const DestType = ToShmType(T);

    const slice = try self.allocator().alloc(DestType, 1);
    const dest_ref = &slice[0];

    try self.deepCopyAndConvert(DestType, dest_ref, src);

    return dest_ref;
}

pub fn destroy(self: *ShmAllocator, ptr: anytype) void {
    const PtrType = @TypeOf(ptr);
    const info = @typeInfo(PtrType);
    if (info != .pointer or info.pointer.size != .One) {
        @compileError("destroy expects a single item pointer.");
    }

    const T = info.Pointer.child;
    const raw_buf = @as([*]u8, @ptrCast(ptr))[0..@sizeOf(T)];

    self.allocator().free(raw_buf);
}

/// NOT thread safe.
pub fn allocator(self: *ShmAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        },
    };
}

/// Provides a lock free thread safe `Allocator` interface to the underlying `FixedBufferAllocator`
pub fn threadSafeAllocator(self: *ShmAllocator) Allocator {
    return .{
        .ptr = self,
        .vtable = &.{
            .alloc = threadSafeAlloc,
            .resize = Allocator.noResize,
            .remap = Allocator.noRemap,
            .free = Allocator.noFree,
        },
    };
}

pub fn ownsPtr(self: *ShmAllocator, ptr: [*]u8) bool {
    return sliceContainsPtr(self.buffer, ptr);
}

pub fn ownsSlice(self: *ShmAllocator, slice: []u8) bool {
    return sliceContainsSlice(self.buffer, slice);
}

pub fn isLastAllocation(self: *ShmAllocator, buf: []u8) bool {
    return buf.ptr + buf.len == self.buffer.ptr + self.loadEnd();
}

pub fn alloc(ctx: *anyopaque, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
    const self: *ShmAllocator = @ptrCast(@alignCast(ctx));
    _ = ra;
    return self.bump(n, alignment.toByteUnits());
}

pub fn resize(
    ctx: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    new_size: usize,
    return_address: usize,
) bool {
    const self: *ShmAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = return_address;
    assert(@inComptime() or self.ownsSlice(buf));

    if (!self.isLastAllocation(buf)) {
        if (new_size > buf.len) return false;
        return true;
    }

    const end = self.loadEnd();
    if (new_size <= buf.len) {
        self.storeEnd(end - (buf.len - new_size));
        return true;
    }

    const add = new_size - buf.len;
    if (add + end > self.buffer.len) return false;

    self.storeEnd(end + add);
    return true;
}

pub fn remap(
    context: *anyopaque,
    memory: []u8,
    alignment: mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
}

pub fn free(
    ctx: *anyopaque,
    buf: []u8,
    alignment: mem.Alignment,
    return_address: usize,
) void {
    const self: *ShmAllocator = @ptrCast(@alignCast(ctx));
    _ = alignment;
    _ = return_address;
    assert(@inComptime() or self.ownsSlice(buf));

    if (self.isLastAllocation(buf)) {
        self.storeEnd(self.loadEnd() - buf.len);
    }
}

fn threadSafeAlloc(ctx: *anyopaque, n: usize, alignment: mem.Alignment, ra: usize) ?[*]u8 {
    const self: *ShmAllocator = @ptrCast(@alignCast(ctx));
    _ = ra;
    return self.bump(n, alignment.toByteUnits());
}

pub fn reset(self: *ShmAllocator) void {
    self.storeEnd(0);
}

fn sliceContainsPtr(container: []u8, ptr: [*]u8) bool {
    return @intFromPtr(ptr) >= @intFromPtr(container.ptr) and
        @intFromPtr(ptr) < (@intFromPtr(container.ptr) + container.len);
}

fn sliceContainsSlice(container: []u8, slice: []u8) bool {
    return @intFromPtr(slice.ptr) >= @intFromPtr(container.ptr) and
        (@intFromPtr(slice.ptr) + slice.len) <= (@intFromPtr(container.ptr) + container.len);
}

pub const Header = extern struct {
    magic: u32,
    version: u32,
    size: usize,
    end_index: std.atomic.Value(usize),
    root_offset: std.atomic.Value(usize),
    lock: std.atomic.Value(u32),
};

/// A shared-memory region whose allocator state lives in said region.
pub const ShmPool = struct {
    io: std.Io,
    file: std.Io.File,
    mem: []align(std.heap.page_size_min) u8,
    header: *Header,
    allocator_state: ShmAllocator,

    const Self = @This();

    pub const magic: u32 = 0x53484D50; // "SHMP"
    pub const version: u32 = 1;
    pub const data_offset = std.mem.alignForward(usize, @sizeOf(Header), 16);
    pub const min_size = data_offset + 16;

    /// Creates a region if it does not exist, otherwise attaches to it.
    pub fn open(io: std.Io, dir: std.Io.Dir, name: []const u8, size: usize) !Self {
        if (size < min_size) return error.SizeTooSmall;

        var file = try dir.createFile(io, name, .{ .read = true, .truncate = false });
        errdefer file.close(io);

        // race condition?
        const existing = try file.length(io);
        const fresh = existing == 0;
        if (fresh) {
            try file.setLength(io, @intCast(size));
        } else if (existing != size) {
            return error.SizeMismatch;
        }

        const memory = try std.posix.mmap(
            null,
            size,
            .{ .WRITE = true, .READ = true },
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        errdefer std.posix.munmap(memory);

        const header: *Header = @ptrCast(@alignCast(memory.ptr));
        if (fresh) {
            header.* = .{
                .magic = magic,
                .version = version,
                .size = size,
                .root_offset = .init(0),
                .end_index = .init(0),
                .lock = .init(0),
            };
        } else {
            if (header.magic != magic) return error.BadMagic;
            if (header.version != version) return error.VersionMismatch;
            if (header.size != size) return error.SizeMismatch;
        }

        return .{
            .io = io,
            .file = file,
            .mem = memory,
            .header = header,
            .allocator_state = ShmAllocator.initShared(memory[data_offset..], header),
        };
    }

    pub fn openPath(io: std.Io, dir_path: []const u8, name: []const u8, size: usize) !Self {
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        defer dir.close(io);
        return open(io, dir, name, size);
    }

    pub fn close(self: *Self) void {
        std.posix.munmap(self.mem);
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn publish(self: *Self, comptime T: type, value: T) !void {
        const root = try self.allocator_state.create(T, value);
        const offset = @intFromPtr(root) - @intFromPtr(self.data().ptr);
        self.header.root_offset.store(offset + 1, .release);
    }

    pub fn read(self: *Self, comptime T: type) ?*const ToShmType(T) {
        const raw = self.header.root_offset.load(.acquire);
        if (raw == 0) return null;
        return @ptrFromInt(@intFromPtr(self.data().ptr) + (raw - 1));
    }

    pub const deinit = close;

    pub fn allocator(self: *Self) Allocator {
        return self.allocator_state.allocator();
    }

    pub fn threadSafeAllocator(self: *Self) Allocator {
        return self.allocator_state.threadSafeAllocator();
    }

    pub fn data(self: *Self) []u8 {
        return self.allocator_state.buffer;
    }

    pub fn usedBytes(self: *Self) usize {
        return self.allocator_state.loadEnd();
    }

    pub fn reset(self: *Self) void {
        self.header.root_offset.store(0, .release);
        self.allocator_state.reset();
    }

    pub fn tryLock(self: *Self) bool {
        return self.header.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) == null;
    }

    pub fn lock(self: *Self) void {
        while (!self.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *Self) void {
        self.header.lock.store(0, .release);
    }
};

const SimpleData = struct {
    id: u32,
    value: f64,
};

const NestedData = struct {
    tag: u8,
    target: *SimpleData,
};

test "ToShmType layout conversion" {
    const MutatedType = ShmAllocator.ToShmType(NestedData);

    const info = @typeInfo(MutatedType);
    try std.testing.expect(info == .@"struct");

    const fields = info.@"struct".field_names;
    try std.testing.expectEqual(@as(usize, 2), fields.len);

    try std.testing.expectEqualStrings(fields[0], "tag");
    try std.testing.expect(info.@"struct".field_types[0] == u8);

    try std.testing.expectEqualStrings(fields[1], "target");
    try std.testing.expect(info.@"struct".field_types[1].ChildType == ShmAllocator.ToShmType(SimpleData));
}

const testing = std.testing;

const TaskNode = struct {
    id: u32,
    next: ?*TaskNode,
};

test "ArrayList Pipeline: Appending pre-swizzled structures with relative references" {
    var raw_buffer: [8192]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);
    const shm_alloc = shm.allocator();

    const ShmTaskNode = ShmAllocator.ToShmType(TaskNode);

    var list: std.ArrayList(ShmTaskNode) = .empty;
    defer list.deinit(shm_alloc);

    const target_node_1 = try shm.allocator().create(ShmTaskNode);
    target_node_1.* = ShmTaskNode{ .id = 1, .next = .{ .relative_offset = 0 } };

    const target_node_2 = try shm.allocator().create(ShmTaskNode);
    target_node_2.* = ShmTaskNode{ .id = 2, .next = .{ .relative_offset = 0 } };

    const element_1 = ShmTaskNode{ .id = 1, .next = .{ .relative_offset = 0 } };
    const element_2 = ShmTaskNode{ .id = 2, .next = .{ .relative_offset = 0 } };

    try list.append(shm_alloc, element_1);
    try list.append(shm_alloc, element_2);

    list.items[0].next.point_to(target_node_1);
    list.items[1].next.point_to(target_node_2);

    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expect(shm.ownsSlice(std.mem.sliceAsBytes(list.items)));

    try testing.expectEqual(@as(u32, 1), list.items[0].id);
    try testing.expectEqual(@as(u32, 1), list.items[0].next.get().?.id);

    try testing.expectEqual(@as(u32, 2), list.items[1].id);
    try testing.expectEqual(@as(u32, 2), list.items[1].next.get().?.id);
}

test "ArrayList Pipeline: Internal dynamic resizing and memory shift stability" {
    var raw_buffer: [4096]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);
    const shm_alloc = shm.allocator();

    const ShmTaskNode = ShmAllocator.ToShmType(TaskNode);

    var list: std.ArrayList(ShmTaskNode) = .empty;
    defer list.deinit(shm_alloc);

    const shared_target = try shm.allocator().create(ShmTaskNode);
    shared_target.* = ShmTaskNode{ .id = 777, .next = .{ .relative_offset = 0 } };

    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const node = ShmTaskNode{ .id = i, .next = .{ .relative_offset = 0 } };
        try list.append(shm_alloc, node);
    }

    try testing.expect(list.capacity >= 20);
    try testing.expect(shm.ownsSlice(std.mem.sliceAsBytes(list.items)));

    for (list.items, 0..) |*item, idx| {
        try testing.expectEqual(@as(u32, @intCast(idx)), item.id);
        item.next.point_to(shared_target);
        try testing.expectEqual(@as(u32, 777), item.next.get().?.id);
        try testing.expectEqual(@intFromPtr(shared_target), @intFromPtr(item.next.get().?));
    }
}

test "Deep copy creates a converted graph in the buffer" {
    var raw_buffer: [4096]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    var child = SimpleData{ .id = 42, .value = 1.5 };
    const src = NestedData{ .tag = 9, .target = &child };
    const converted = try shm.create(NestedData, src);

    try testing.expect(converted.tag == 9);
    try testing.expect(converted.target.get().?.id == 42);
    try testing.expect(converted.target.get().?.value == 1.5);
    try testing.expect(shm.ownsPtr(@ptrCast(converted.target.get().?)));
}

const SliceData = struct {
    name: []const u8,
    values: []const u32,
};

test "Deep copy converts slices into shared slices" {
    var raw_buffer: [4096]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    const values = [_]u32{ 10, 20, 30 };
    const src = SliceData{ .name = "hello", .values = &values };
    const converted = try shm.create(SliceData, src);

    try testing.expectEqualStrings("hello", converted.name.get());
    try testing.expectEqual(@as(usize, 3), converted.values.get().len);
    try testing.expectEqual(@as(u32, 20), converted.values.get()[1]);
    try testing.expect(shm.ownsSlice(@constCast(converted.name.get())));
    try testing.expect(shm.ownsSlice(std.mem.sliceAsBytes(@constCast(converted.values.get()))));
}

test "N-dimensional slices are converted recursively" {
    var raw_buffer: [8192]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    const Grid = struct { rows: []const []const u8 };
    const rows_src = [_][]const u8{ "abc", "de" };
    const src = Grid{ .rows = &rows_src };

    const converted = try shm.create(Grid, src);
    const rows = converted.rows.get();
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("abc", rows[0].get());
    try testing.expectEqualStrings("de", rows[1].get());
}

test "Arrays and optionals are converted recursively" {
    var raw_buffer: [8192]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    const Fixed = struct {
        items: [2]SimpleData,
        maybe: ?SimpleData,
        flags: [3]bool,
    };
    const src = Fixed{
        .items = .{ .{ .id = 1, .value = 1.0 }, .{ .id = 2, .value = 2.0 } },
        .maybe = .{ .id = 3, .value = 3.0 },
        .flags = .{ true, false, true },
    };

    const converted = try shm.create(Fixed, src);
    try testing.expectEqual(@as(u32, 2), converted.items[1].id);
    try testing.expectEqual(@as(u32, 3), converted.maybe.?.id);
    try testing.expect(converted.flags[2]);
}

test "Pointers to primitives are converted" {
    var raw_buffer: [4096]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    const Boxed = struct { value: *u32 };
    var n: u32 = 99;
    const converted = try shm.create(Boxed, .{ .value = &n });

    try testing.expectEqual(@as(u32, 99), converted.value.get().?.*);
    try testing.expect(shm.ownsPtr(@ptrCast(converted.value.get().?)));
}

test "Many-item pointers are made relative" {
    var raw_buffer: [4096]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    const ManyData = struct { bytes: [*]const u8, n: usize };
    const bytes = [_]u8{ 1, 2, 3 };
    const converted = try shm.create(ManyData, .{ .bytes = &bytes, .n = bytes.len });

    try testing.expectEqual(@as(usize, 3), converted.n);
    try testing.expectEqual(@as(u8, 2), converted.bytes.get().?[1]);
}

test "Tagged unions are converted recursively" {
    var raw_buffer: [4096]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    const U = union(enum) { num: u32, data: NestedData, text: []const u8 };
    const Holder = struct { u: U };

    var child = SimpleData{ .id = 5, .value = 2.0 };
    const src = Holder{ .u = .{ .data = .{ .tag = 1, .target = &child } } };
    const converted = try shm.create(Holder, src);

    switch (converted.u) {
        .data => {
            const d = &converted.u.data;
            try testing.expectEqual(@as(u8, 1), d.tag);
            try testing.expectEqual(@as(u32, 5), d.target.get().?.id);
        },
        else => return error.UnexpectedUnionTag,
    }
}

fn answer() u32 {
    return 42;
}

test "Function pointers are made relative" {
    var raw_buffer: [4096]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    const FnData = struct { f: *const fn () u32 };
    const converted = try shm.create(FnData, .{ .f = &answer });

    try testing.expectEqual(@as(u32, 42), converted.f.get().?());
}

test "Untagged unions of plain data are copied" {
    var raw_buffer: [4096]u8 = undefined;
    var shm = ShmAllocator.init(&raw_buffer);

    const Raw = union { a: u32, b: f32 };
    const Holder = struct { r: Raw };
    const converted = try shm.create(Holder, .{ .r = .{ .a = 7 } });

    try testing.expectEqual(@as(u32, 7), converted.r.a);
}

test "ShmPool shares allocator state between attachments" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pool_a = try ShmPool.open(io, tmp.dir, "pool", 8192);
    defer pool_a.close();

    const a = pool_a.allocator();
    const bytes_a = try a.alloc(u8, 16);
    @memset(bytes_a, 0xAB);

    var pool_b = try ShmPool.open(io, tmp.dir, "pool", 8192);
    defer pool_b.close();

    try testing.expectEqual(pool_a.usedBytes(), pool_b.usedBytes());

    const b = pool_b.allocator();
    const bytes_b = try b.alloc(u8, 8);
    try testing.expect(@intFromPtr(bytes_b.ptr) != @intFromPtr(bytes_a.ptr));
    try testing.expect(pool_b.usedBytes() > pool_a.usedBytes() - 16);

    const offset = @intFromPtr(bytes_a.ptr) - @intFromPtr(pool_a.data().ptr);
    try testing.expectEqual(@as(u8, 0xAB), pool_b.data()[offset]);
}

test "ShmPool lock is shared across attachments" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pool_a = try ShmPool.open(io, tmp.dir, "locked", 4096);
    defer pool_a.close();
    var pool_b = try ShmPool.open(io, tmp.dir, "locked", 4096);
    defer pool_b.close();

    try testing.expect(pool_a.tryLock());
    try testing.expect(!pool_b.tryLock());
    pool_a.unlock();
    try testing.expect(pool_b.tryLock());
    pool_b.unlock();
}

test "ShmPool preserves allocation state across reopen" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var pool = try ShmPool.open(io, tmp.dir, "persist", 4096);
    const first = try pool.allocator().alloc(u8, 32);
    @memset(first, 7);
    const used = pool.usedBytes();
    pool.close();

    var reopened = try ShmPool.open(io, tmp.dir, "persist", 4096);
    defer reopened.close();

    try testing.expectEqual(used, reopened.usedBytes());
    const second = try reopened.allocator().alloc(u8, 8);
    try testing.expect(@intFromPtr(second.ptr) >= @intFromPtr(reopened.data().ptr) + used);
}
