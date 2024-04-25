const std = @import("std");
const Allocator = std.mem.Allocator;

const BufferType = enum { jsonString, streamSource };

pub const Buffer = struct {
    buffer: union(BufferType) {jsonString: []const u8, streamSource: *std.io.StreamSource},
    position: u64 = 0,
    last: ?u8 = null,
    pub fn getPos(self: *Buffer) BufferErrors!u64 {
        return switch (self.buffer) {
            BufferType.jsonString => self.position,
            BufferType.streamSource => |ss| ss.getPos() catch return BufferErrors.ReadError
        };
    }
    pub fn getEndPos(self: *Buffer) BufferErrors!u64 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| js.len,
            BufferType.streamSource => |ss| ss.getEndPos() catch return BufferErrors.ReadError
        };
    }
    pub fn seekTo(self: *Buffer, location: u64) BufferErrors!void {
        switch (self.buffer) {
            BufferType.jsonString => self.position = location,
            BufferType.streamSource => |ss| ss.seekTo(location)
        }
    }
    pub fn seekBy(self: *Buffer, offset: i64) BufferErrors!void {
        switch (self.buffer) {
            BufferType.jsonString => self.position = if (offset < 0) self.position - @as(u64, @abs(offset)) else self.position + @as(u64, @abs(offset)),
            BufferType.streamSource => |ss| ss.seekBy(offset) catch return BufferErrors.ReadError
        }
    }
    pub fn skipBytes(self: *Buffer, count: u64) BufferErrors!void {
        switch (self.buffer) {
            BufferType.jsonString => self.position = self.position + count,
            BufferType.streamSource => |ss| ss.reader().skipBytes(count, .{}) catch return BufferErrors.ReadError
        }
    }
    pub fn substringOwned(self: *Buffer, start: u64, end: u64, allocator: Allocator) BufferErrors![]const u8 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| {
                const buffer = allocator.alloc(u8, end - start) catch return BufferErrors.OutOfMemoryError;
                std.mem.copyForwards(u8, buffer, js[start..end]);
                return buffer;
            },
            BufferType.streamSource => |ss| {
                const buffer = allocator.alloc(u8, end - start) catch return BufferErrors.OutOfMemoryError;
                ss.seekTo(start) catch return BufferErrors.ReadError;
                _ = ss.read(buffer) catch return BufferErrors.ReadError;
                return buffer;
            }
        };
    }
    pub fn readByte(self: *Buffer) BufferErrors!u8 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| {
                defer self.position += 1;
                self.last = js[try self.getPos()];
                return self.last.?;
            },
            BufferType.streamSource => |ss| {
                const byte = ss.reader().readByte() catch return BufferErrors.ReadError;
                self.last = byte;
                return byte;
            }
        };
    }
    pub fn read(self: *Buffer, buffer: []u8) BufferErrors!u64 {
        return switch (self.buffer) {
            BufferType.jsonString => {
                var index: u64 = 0;
                while (index != buffer.len) {
                    buffer[index] = try self.readByte();
                    index += 1;
                }
                self.last = buffer[buffer.len - 1];
                return index;
            },
            BufferType.streamSource => |ss| {
                const count = ss.read(buffer) catch return BufferErrors.ReadError;
                self.last = buffer[buffer.len - 1];
                return count;
            }
        };
    }
    pub fn readN(self: *Buffer, buffer: []u8, len: u64) BufferErrors!u64 {
        return switch (self.buffer) {
            BufferType.jsonString => {
                if (len >= buffer.len) unreachable;
                var index: u64 = 0;
                while (index != len and index != buffer.len) {
                    buffer[index] = try self.readByte();
                    index += 1;
                }
                self.last = buffer[buffer.len - 1];
                return index;
            },
            BufferType.streamSource => |ss| {
                const count = ss.reader().readAtLeast(buffer, len) catch return BufferErrors.ReadError;
                self.last = buffer[buffer.len - 1];
                return count;
            }
        };
    }
    pub fn peek(self: *Buffer) BufferErrors!u8 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| js[try self.getPos()],
            BufferType.streamSource => |ss| {
                const byte = ss.reader().readByte() catch return BufferErrors.ReadError;
                ss.seekBy(-1) catch return BufferErrors.ReadError;
                return byte;
            }
        };
    }
    pub fn peekNext(self: *Buffer) BufferErrors!u8 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| js[try self.getPos() + 1],
            BufferType.streamSource => |ss| {
                var byte = ss.reader().readByte() catch return BufferErrors.ReadError;
                byte = ss.reader().readByte() catch return BufferErrors.ReadError;
                ss.seekBy(-2) catch return BufferErrors.ReadError;
                return byte;
            }
        };
    }
    pub fn lastByte(self: *Buffer) ?u8 {
        return self.last;
    }
};

pub const BufferErrors = BufferError;

pub const BufferError = error{
    ReadError,
    OutOfMemoryError
};

pub fn bufferFromText(text: []const u8) Buffer {
    return Buffer{ .buffer = .{ .jsonString = text } };
}

pub fn bufferFromStreamSource(source: *std.io.StreamSource) Buffer {
    return Buffer{ .buffer = .{ .streamSource = source } };
}