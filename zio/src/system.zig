const zio = @import("../zio.zig");

pub const InitError = error {
    
};

/// Initialize all things related to IO for the platform.
/// This is mostly for windows WinSock initialization.
pub inline fn initialize() InitError!void {
    return zio.backend.initialize();
}

/// Cleanup IO stuff: A.K.A WSACleanup() on windows.
pub inline fn cleanup() void {
    return zio.backend.cleanup();
}

/// A reference to an internal kernel object.
/// This serves as the basis for other IO objects such as
/// `Poller`s and `Socket`s.
pub const Handle = zio.backend.Handle;

/// The result of an IO operation.
/// The meaning of the status differs depending on where
/// or how the `Result` is generated.
pub const Result = struct {
    data: u32,
    status: Status,

    pub const Status = enum {
        /// There was an error processing the IO operation.
        /// At this point, one should normally `.close()` the IO object.
        Error,
        /// The operation should be retried (possibly later) as either:
        /// - the kernel has no more resources to provide and it would block.
        /// - the action needs to be re-performed in order to get the true `Result`. 
        Retry,
        /// The IO operation was completed, but only partially.
        /// There's still some remaining data that needs to be consumed.
        Partial,
        /// The IO operation was completed fully and successfully.
        Completed,
    };
};

/// A representation of user space data to feed into IO operations.
/// Certain sequential bytes of data which are fed into the kernel
/// require to be wraped into a `Buffer` in order to remain valid.
/// Conversions between slices of bytes and `Buffers` could be done
/// in-place as `@sizeOf(Buffer) == @sizeOf([]u8)` and the conversion
/// is essentially a no-op on platforms where the internal layouts match.
pub const Buffer = struct {
    inner: zio.backend.Buffer,

    pub inline fn fromBytes(bytes: []const u8) @This() {
        return @This() { .inner = zio.backend.Buffer.fromBytes(bytes) };
    }

    pub inline fn getBytes(self: @This()) []u8 {
        return self.inner.getBytes();
    }
};
