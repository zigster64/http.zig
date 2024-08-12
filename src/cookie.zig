const std = @import("std");

const Allocator = std.mem.Allocator;

pub const sameSiteMode = enum {
    None,
    Lax,
    Strict,
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    path: ?[]const u8 = null,
    domain: ?[]const u8 = null,
    maxAge: usize = 0, // 0 - none specified.  < 0 = delete cookie now. > 0 = max age in seconds
    secure: bool = true,
    session: bool = false,
    httpOnly: bool = true,
    sameSite: sameSiteMode = .Default,
};
