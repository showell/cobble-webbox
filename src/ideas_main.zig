//! Idea Forge, served: webbox's Linux host with IdeaWeb (ideas_app.zig).
//!
//! Run:  zig build serve-ideas       (on http://localhost:9105)

const std = @import("std");
const webbox = @import("webbox");
const app = @import("ideas_app.zig");

pub const site = webbox.site.Site(app);

pub fn main(init: std.process.Init.Minimal) !void {
    try @import("webbox_linux").linux_host.Server(site).run(init, .{
        .name = "idea-forge",
        .env = .{
            .port = "IDEAS_PORT",
            .bind = "IDEAS_BIND",
            .config = "IDEAS_CONFIG",
            .trusted_proxy = "IDEAS_TRUSTED_PROXY",
            .keepalive_ms = "IDEAS_KEEPALIVE_MS",
        },
        .default_port = 9105,
        .default_trusted_proxy = "127.0.0.1",
        // The host opens a second root at the start; the house keeps no
        // secret in it.
        .default_auth_dir = "auth",
        .routes_hint = "(/, /offer, /claim, /claims, /idea, /api/health)",
        .free_space = unread,
    }, report);
}

/// Nothing is written to the data volume: the house's state is in memory.
fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(_: *const site.Started) void {
    std.debug.print("idea-forge: the house is open\n", .{});
}
