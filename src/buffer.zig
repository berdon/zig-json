const std = @import("std");
const Allocator = std.mem.Allocator;

const BufferType = enum { jsonString, streamSource };

/// Wrapper around an array (to be removed) or StreamSource (which is itself a wrapper around a buffer or stream).
/// This was introduced as an intermediate step before transitioning directly to a stream source. However,
/// StreamSources behave a bit...disparate, so it might stick around.
pub const Buffer = struct {
    /// A string or StreamSource
    buffer: union(BufferType) { jsonString: []const u8, streamSource: *std.io.StreamSource },
    /// The position in the array or the position of the StreamSource
    /// Note: StreamSource does support getPos but only for seekable streams
    position: u64 = 0,
    /// The last byte read
    last: ?u8 = null,
    /// A peek byte - doesn't count towards position* or being read.
    /// Note: It does actually count towards position but its existence subtracts from the returned position
    peekByte: ?u8 = null,
    /// A peek^2 byte - doesn't count towards position* or being read.
    /// Note: It does actually count towards position but its existence subtracts from the returned position
    peekNextByte: ?u8 = null,
    /// Returns the position of the next unread byte
    pub fn getPos(self: *Buffer) BufferErrors!u64 {
        return switch (self.buffer) {
            BufferType.jsonString => self.position,
            BufferType.streamSource => |ss| {
                const position = ss.getPos() catch return self.position;
                if (self.peekNextByte) |_| return position - 2;
                if (self.peekByte) |_| return position - 1;
                return position;
            },
        };
    }
    /// Returns the total size of the buffer or maxInt if the size is unavailable
    pub fn getEndPos(self: *Buffer) BufferErrors!u64 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| js.len,
            BufferType.streamSource => |ss| (if (ss.getEndPos() catch std.math.maxInt(u64) == 0) std.math.maxInt(u64) else ss.getEndPos() catch std.math.maxInt(u64)),
        };
    }
    /// Skips over count bytes
    /// Note: Clears the last byte read if count > 0
    pub fn skipBytes(self: *Buffer, count: u64) BufferErrors!void {
        if (count == 0) return;
        switch (self.buffer) {
            BufferType.jsonString => self.position = self.position + count,
            BufferType.streamSource => |ss| {
                var skipped: usize = 0;
                while (self.peekByte) |_| {
                    if (skipped == count) break;
                    _ = try self.readByte();
                    skipped += 1;
                }
                if (skipped < count) {
                    ss.reader().skipBytes(count - skipped, .{}) catch return BufferErrors.ReadError;
                }
                self.position += (count - skipped);
                self.last = null;
            },
        }
    }
    /// Reads a byte from the buffer
    pub fn readByte(self: *Buffer) BufferErrors!u8 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| {
                defer self.position += 1;
                self.last = js[try self.getPos()];
                return self.last.?;
            },
            BufferType.streamSource => |ss| {
                if (self.peekByte) |pb| {
                    if (self.peekNextByte) |pnb| {
                        self.peekByte = pnb;
                        self.peekNextByte = null;
                    } else {
                        self.peekByte = null;
                    }
                    self.last = pb;
                    self.position += 1;
                    return pb;
                }

                const byte = ss.reader().readByte() catch return BufferErrors.ReadError;
                self.last = byte;
                self.position += 1;
                return byte;
            },
        };
    }
    /// Reads buffer.len worth of bytes into buffer
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
                var count: usize = 0;
                while (self.peekByte) |_| {
                    if (buffer.len == count) break;
                    buffer[count] = try self.readByte();
                    count += 1;
                }
                if (buffer.len > count) {
                    count += ss.read(buffer[count..buffer.len]) catch return BufferErrors.ReadError;
                }

                self.last = buffer[buffer.len - 1];
                self.position += buffer.len;
                return count;
            },
        };
    }
    /// Reads up to len bytes into buffer
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
                var count: usize = 0;
                while (self.peekByte) |_| {
                    if (len == count) break;
                    buffer[count] = try self.readByte();
                    count += 1;
                }
                if (len > count) {
                    count += ss.reader().readAtLeast(buffer[count..len], len - count) catch return BufferErrors.ReadError;
                }

                self.last = buffer[len - 1];
                self.position += len;
                return count;
            },
        };
    }
    /// Returns the next byte but doesn't advance the read position
    pub fn peek(self: *Buffer) BufferErrors!u8 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| js[try self.getPos()],
            BufferType.streamSource => |ss| {
                if (self.peekByte) |pb| return pb;
                self.peekByte = ss.reader().readByte() catch return BufferErrors.ReadError;
                return self.peekByte.?;
            },
        };
    }
    /// Returns the second next byte but doesn't advance the read position
    pub fn peekNext(self: *Buffer) BufferErrors!u8 {
        return switch (self.buffer) {
            BufferType.jsonString => |js| js[try self.getPos() + 1],
            BufferType.streamSource => |ss| {
                if (self.peekNextByte) |pb| return pb;
                if (self.peekByte == null) _ = try self.peek();

                self.peekNextByte = ss.reader().readByte() catch return BufferErrors.ReadError;
                return self.peekNextByte.?;
            },
        };
    }
    /// Returns the last byte
    pub fn lastByte(self: *Buffer) ?u8 {
        return self.last;
    }
};

pub const BufferErrors = BufferError;

pub const BufferError = error{ReadError};

pub fn bufferFromText(text: []const u8) Buffer {
    return Buffer{ .buffer = .{ .jsonString = text } };
}

pub fn bufferFromStreamSource(source: *std.io.StreamSource) Buffer {
    return Buffer{ .buffer = .{ .streamSource = source } };
}

test "Can peek from file backed buffer" {
    const file = try std.fs.cwd().openFile("testFiles/simple.txt", .{});
    defer file.close();

    var streamSource = std.io.StreamSource{ .file = file };
    var buffer = bufferFromStreamSource(&streamSource);

    try std.testing.expectEqual(try buffer.peek(), '1');
}

test "Can skip from file backed buffer" {
    const file = try std.fs.cwd().openFile("testFiles/simple.txt", .{});
    defer file.close();

    var streamSource = std.io.StreamSource{ .file = file };
    var buffer = bufferFromStreamSource(&streamSource);

    try buffer.skipBytes(3);
    try std.testing.expectEqual(try buffer.peek(), '4');
    try std.testing.expectEqual(try buffer.readByte(), '4');

    try buffer.skipBytes(1);
    try std.testing.expectEqual(try buffer.peek(), '6');
    try std.testing.expectEqual(try buffer.peekNext(), '7');
    try std.testing.expectEqual(try buffer.readByte(), '6');
    try std.testing.expectEqual(try buffer.readByte(), '7');
}

test "Can readByte from peeked file backed buffer" {
    const file = try std.fs.cwd().openFile("testFiles/simple.txt", .{});
    defer file.close();

    var streamSource = std.io.StreamSource{ .file = file };
    var buffer = bufferFromStreamSource(&streamSource);

    try std.testing.expectEqual(try buffer.peek(), '1');
    try std.testing.expectEqual(try buffer.peekNext(), '2');
    try std.testing.expectEqual(try buffer.readByte(), '1');
    try std.testing.expectEqual(try buffer.readByte(), '2');
    try std.testing.expectEqual(try buffer.peek(), '3');
    try std.testing.expectEqual(try buffer.peekNext(), '4');
    try std.testing.expectEqual(try buffer.readByte(), '3');
    try std.testing.expectEqual(try buffer.peek(), '4');
    try std.testing.expectEqual(try buffer.readByte(), '4');
}

test "Can read from peeked file backed buffer" {
    const file = try std.fs.cwd().openFile("testFiles/simple.txt", .{});
    defer file.close();

    var streamSource = std.io.StreamSource{ .file = file };
    var buffer = bufferFromStreamSource(&streamSource);

    var readBuffer: [5]u8 = undefined;
    try std.testing.expectEqual(try buffer.peek(), '1');

    _ = try buffer.read(&readBuffer);
    try std.testing.expect(std.mem.eql(u8, &readBuffer, "12345"));

    try std.testing.expectEqual(try buffer.peek(), '6');
    try std.testing.expectEqual(try buffer.peekNext(), '7');

    _ = try buffer.read(&readBuffer);
    try std.testing.expect(std.mem.eql(u8, &readBuffer, "67890"));
}

test "Can readN from peeked file backed buffer" {
    const file = try std.fs.cwd().openFile("testFiles/simple.txt", .{});
    defer file.close();

    var streamSource = std.io.StreamSource{ .file = file };
    var buffer = bufferFromStreamSource(&streamSource);

    var readBuffer: [10]u8 = undefined;
    try std.testing.expectEqual(try buffer.peek(), '1');

    _ = try buffer.readN(&readBuffer, 5);
    try std.testing.expect(std.mem.eql(u8, readBuffer[0..5], "12345"));

    try std.testing.expectEqual(try buffer.peek(), '6');
    try std.testing.expectEqual(try buffer.peekNext(), '7');

    _ = try buffer.readN(&readBuffer, 5);
    try std.testing.expect(std.mem.eql(u8, readBuffer[0..5], "67890"));
}
