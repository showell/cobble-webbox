//! Cobblestone's games, served: webbox's Linux host with the game server
//! (app.zig). Run it from this checkout, beside the Cobblestone one whose
//! pages it serves.
//!
//! Run:  zig build serve       (on http://localhost:9104)

const std = @import("std");
const webbox = @import("webbox");
const app = @import("app.zig");

pub const site = webbox.site.Site(app);

pub fn main(init: std.process.Init.Minimal) !void {
    var env = try std.process.Environ.createMap(init.environ, std.heap.page_allocator);
    defer env.deinit();
    // The checkout the pages come from: COBBLESTONE_ROOT, else the sibling
    // ../cobblestone-pin (the pinned worktree codexzig was run against).
    if (env.get("COBBLESTONE_ROOT")) |root| app.cobble_root = try std.heap.page_allocator.dupe(u8, root);
    try @import("webbox_linux").linux_host.Server(site).run(init, .{
        .name = "cobble-games",
        .env = .{
            .port = "COBBLE_PORT",
            .bind = "COBBLE_BIND",
            .config = "COBBLE_CONFIG",
            .trusted_proxy = "COBBLE_TRUSTED_PROXY",
            .keepalive_ms = "COBBLE_KEEPALIVE_MS",
        },
        .default_port = 9104,
        .default_trusted_proxy = "127.0.0.1",
        // The host opens a second root at the start; the game server keeps
        // no secret in it.
        .default_auth_dir = "auth",
        .routes_hint = "(/, /games/ID, /api/*, /web/*, /assets/*)",
        .free_space = unread,
    }, report);
}

/// Nothing is written to the data volume.
fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(started: *const site.Started) void {
    std.debug.print("cobble-games: pages from {s}\n", .{started.app.cobble_root});
}
