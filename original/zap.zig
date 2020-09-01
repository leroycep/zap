const std = @import("std");
const builtin = @import("builtin");

test "zap" {
    _ = zync;
    _ = zuma;
    _ = zio;
    _ = zell;
}

pub const zync = struct {
    pub usingnamespace @import("zync/src/utils.zig");
    pub usingnamespace @import("zync/src/atomic.zig");
    pub usingnamespace @import("zync/src/futex.zig");
    pub usingnamespace @import("zync/src/lock.zig");
};

pub const zuma = struct {
    pub usingnamespace @import("zuma/src/memory.zig");
    pub usingnamespace @import("zuma/src/affinity.zig");
    pub usingnamespace @import("zuma/src/thread.zig");

    pub const backend = switch (builtin.os) {
        .linux => @import("zuma/src/backend/linux.zig"),
        .windows => @import("zuma/src/backend/windows.zig"),
        else => @import("zuma/src/backend/posix.zig"),
    };
};

pub const zio = struct {
    pub usingnamespace @import("zio/src/io.zig");
    pub usingnamespace @import("zio/src/event.zig");
    pub usingnamespace @import("zio/src/address.zig");
    pub usingnamespace @import("zio/src/socket.zig");

    pub const backend = switch (builtin.os) {
        .linux => @import("zio/src/backend/linux.zig"),
        .windows => @import("zio/src/backend/windows.zig"),
        .macosx, .freebsd, .netbsd, .openbsd, .dragonfly => @import("zio/src/backend/posix.zig"),
        else => @compileError("Only linux, windows and some *BSD variants are supported"),
    };
};

pub const zell = struct {
    pub usingnamespace @import("zell/src/executor.zig");
};