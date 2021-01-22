const std = @import("std");

pub const Lock = struct {
    mutex: std.Thread.Mutex = std.Thread.Mutex{},

    pub fn acquire(self: *Lock) void {
        _ = self.mutex.acquire();
    }

    const Held = @typeInfo(@TypeOf(std.Thread.Mutex.acquire)).Fn.return_type.?;
    pub fn release(self: *Lock) void {
        (Held{ .mutex = &self.mutex.impl }).release();
    }
};
