//! Codex Chat, served: webbox's Linux host with ChatServer and ChatStore
//! (chat_app.zig).
//!
//! Run:  zig build serve-chat       (on http://localhost:9106)

const std = @import("std");
const webbox = @import("webbox");
const app = @import("chat_app.zig");

pub const site = webbox.site.Site(app);

pub fn main(init: std.process.Init.Minimal) !void {
    var env = try std.process.Environ.createMap(init.environ, std.heap.page_allocator);
    defer env.deinit();
    // The chat's own folder when no config names one: CHAT_DATA, else
    // data/codex-chat/ under where the server runs.
    if (env.get("CHAT_DATA")) |p| app.data_dir = try std.heap.page_allocator.dupe(u8, p);
    try @import("webbox_linux").linux_host.Server(site).run(init, .{
        .name = "codex-chat",
        .env = .{
            .port = "CHAT_PORT",
            .bind = "CHAT_BIND",
            .config = "CHAT_CONFIG",
            .trusted_proxy = "CHAT_TRUSTED_PROXY",
            .keepalive_ms = "CHAT_KEEPALIVE_MS",
        },
        .default_port = 9106,
        .default_trusted_proxy = "127.0.0.1",
        // The host opens a second root at the start; the chat keeps no
        // secret in it (its tokens are in its own files, under data/).
        .default_auth_dir = "auth",
        .routes_hint = "(/, /api/chat/*)",
        .free_space = unread,
    }, report);
}

/// Not read: no page here shows the data volume's free space.
fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(started: *const site.Started) void {
    if (started.app.problem.len > 0) {
        std.debug.print("codex-chat: not serving the files under {s}: {s}\n", .{ started.app.files, started.app.problem });
        std.process.exit(1);
    }
    std.debug.print("codex-chat: state in {s}/\n", .{started.app.files});
}
