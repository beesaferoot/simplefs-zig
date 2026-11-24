const std = @import("std");

/// Disk emulator
const BLOCK_SIZE: usize = 4096;

const Disk = struct {
    allocator: std.mem.Allocator,
    file: ?std.Io.File,
    name: ?[]const u8,
    blocks: u32,

    reads: u32 = 0,
    writes: u32 = 0,
    mounts: u32 = 0,

    /// Create a new disk image.
    ///
    /// Fails if the image already exists.
    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        file_path: []const u8,
        block_count: u32,
    ) !Disk {
        if (block_count == 0) {
            return error.InvalidBlockCount;
        }

        const file_size: u64 =
            @as(u64, block_count) * @as(u64, BLOCK_SIZE);

        const owned_name = try allocator.dupe(u8, file_path);
        errdefer allocator.free(owned_name);

        const file = try dir.createFile(io, file_path, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = std.Io.File.Permissions.fromMode(0o600),
        });
        errdefer file.close(io);

        try file.setLength(io, file_size);

        return .{
            .allocator = allocator,
            .file = file,
            .name = owned_name,
            .blocks = block_count,
        };
    }

    /// Open an existing disk image.
    ///
    /// The disk capacity is inferred from the image size.
    /// The image must contain at least one complete block.
    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        file_path: []const u8,
    ) !Disk {
        const file = try dir.openFile(io, file_path, .{
            .mode = .read_write,
        });
        errdefer file.close(io);

        const file_size = try file.length(io);

        if (file_size == 0 or file_size % BLOCK_SIZE != 0) {
            return error.InvalidDiskImage;
        }

        const block_count = file_size / BLOCK_SIZE;

        if (block_count > std.math.maxInt(u32)) {
            return error.DiskTooLarge;
        }

        const owned_name = try allocator.dupe(u8, file_path);
        errdefer allocator.free(owned_name);

        return .{
            .allocator = allocator,
            .file = file,
            .name = owned_name,
            .blocks = @intCast(block_count),
        };
    }

    /// Close the underlying disk image.
    pub fn close(self: *Disk, io: std.Io) !void {
        const file = self.file orelse return error.AlreadyClosed;

        file.close(io);
        self.file = null;

        if (self.name) |name| {
            self.allocator.free(name);
            self.name = null;
        }
    }

    /// Return the disk size in blocks.
    pub fn size(self: *const Disk) u32 {
        return self.blocks;
    }

    /// Return the disk image path, if still open.
    pub fn path(self: *const Disk) ?[]const u8 {
        return self.name;
    }

    pub fn isMounted(self: *const Disk) bool {
        return self.mounts > 0;
    }

    pub fn umount(self: *Disk) void {
        if (self.mounts > 0) {
            self.mounts -= 1;
        }
    }

    fn validateBlock(self: *const Disk, block_number: u32) !void {
        if (block_number >= self.blocks) {
            return error.BlockOutOfRange;
        }
    }

    pub fn readBlock(self: *Disk, io: std.Io, block_number: u32, buffer: *[BLOCK_SIZE]u8) !void {
        try self.validateBlock(block_number);

        const file = self.file orelse return error.DiskClosed;

        const offset: u64 = @as(u64, block_number) * @as(u64, BLOCK_SIZE);

        const bytes_read = try file.readPositionalAll(io, buffer, offset);

        if (bytes_read != BLOCK_SIZE) {
            return error.FailedBlockRead;
        }
        self.reads += 1;
    }

    pub fn writeBlock(self: *Disk, io: std.Io, block_number: u32, buffer: *const [BLOCK_SIZE]u8) !void {
        try self.validateBlock(block_number);

        const file = self.file orelse return error.DiskClosed;

        const offset: u64 = @as(u64, block_number) * @as(u64, BLOCK_SIZE);

        try file.writePositionalAll(io, buffer, offset);

        self.writes += 1;
    }
};

test "create allocates the requested disk size" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try Disk.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        "disk.img",
        4,
    );
    defer {
        if (disk.file != null) {
            disk.close(testing.io) catch unreachable;
        }
    }

    try testing.expectEqual(@as(u32, 4), disk.size());

    const expected_size: u64 = 4 * BLOCK_SIZE;
    const actual_size = try disk.file.?.length(testing.io);

    try testing.expectEqual(expected_size, actual_size);
}

test "create refuses to overwrite an existing disk" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try Disk.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        "disk.img",
        4,
    );

    try disk.close(testing.io);

    try testing.expectError(
        error.PathAlreadyExists,
        Disk.create(
            testing.allocator,
            testing.io,
            tmp.dir,
            "disk.img",
            8,
        ),
    );
}

test "open existing disk image" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Create an image first.
    var original = try Disk.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        "disk.img",
        8,
    );

    try original.close(testing.io);

    // Open it without specifying its capacity.
    var disk = try Disk.open(
        testing.allocator,
        testing.io,
        tmp.dir,
        "disk.img",
    );
    defer {
        if (disk.file != null) {
            disk.close(testing.io) catch unreachable;
        }
    }

    try testing.expectEqual(@as(u32, 8), disk.size());
}

test "read and write blocks" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try Disk.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        "disk.img",
        4,
    );
    defer {
        if (disk.file != null) {
            disk.close(testing.io) catch unreachable;
        }
    }

    var write_buffer: [BLOCK_SIZE]u8 = @splat(0xAB);
    var read_buffer: [BLOCK_SIZE]u8 = undefined;

    try disk.writeBlock(testing.io, 0, &write_buffer);
    try disk.readBlock(testing.io, 0, &read_buffer);

    try testing.expectEqualSlices(
        u8,
        &write_buffer,
        &read_buffer,
    );

    try testing.expectEqual(@as(u32, 1), disk.writes);
    try testing.expectEqual(@as(u32, 1), disk.reads);
}

test "block operations reject invalid block numbers" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try Disk.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        "disk.img",
        4,
    );
    defer {
        if (disk.file != null) {
            disk.close(testing.io) catch unreachable;
        }
    }

    var buffer: [BLOCK_SIZE]u8 = undefined;

    try testing.expectError(
        error.BlockOutOfRange,
        disk.readBlock(testing.io, 4, &buffer),
    );

    try testing.expectError(
        error.BlockOutOfRange,
        disk.writeBlock(testing.io, 4, &buffer),
    );
}

test "closed disk rejects further operations" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var disk = try Disk.create(
        testing.allocator,
        testing.io,
        tmp.dir,
        "disk.img",
        4,
    );

    try disk.close(testing.io);

    try testing.expectError(
        error.AlreadyClosed,
        disk.close(testing.io),
    );

    var buffer: [BLOCK_SIZE]u8 = undefined;

    try testing.expectError(
        error.DiskClosed,
        disk.readBlock(testing.io, 0, &buffer),
    );
}

test "open rejects malformed disk images" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(
        testing.io,
        "invalid.img",
        .{},
    );
    try file.setLength(testing.io, 100);
    file.close(testing.io);

    try testing.expectError(
        error.InvalidDiskImage,
        Disk.open(
            testing.allocator,
            testing.io,
            tmp.dir,
            "invalid.img",
        ),
    );
}
