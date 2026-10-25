//! uoaix's live town, served: webbox's Linux host with uo_app.zig.
//!
//! Run:  zig build serve-uo       (on http://localhost:9107/uo/town/)

const std = @import("std");
const webbox = @import("webbox");
const app = @import("uo_app.zig");

pub const site = webbox.site.Site(app);

pub fn main(init: std.process.Init.Minimal) !void {
    try @import("webbox_linux").linux_host.Server(site).run(init, .{
        .name = "uo",
        .env = .{
            .port = "UO_PORT",
            .bind = "UO_BIND",
            .config = "UO_CONFIG",
            .trusted_proxy = "UO_TRUSTED_PROXY",
            .keepalive_ms = "UO_KEEPALIVE_MS",
        },
        .default_port = 9107,
        .default_trusted_proxy = "127.0.0.1",
        .default_auth_dir = "auth",
        .routes_hint = "(/uo/town/)",
        .free_space = unread,
    }, report);
}

/// Not read: no page here shows the data volume's free space.
fn unread(_: *const std.process.Environ.Map) webbox.free_space.FreeSpace {
    return .unknown;
}

fn report(started: *const site.Started) void {
    if (started.app.problem.len > 0) {
        std.debug.print("uo: no town: {s}\n", .{started.app.problem});
        std.process.exit(1);
    }
}
