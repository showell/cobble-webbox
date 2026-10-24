//! Codex Chat's HTTP, for a webbox site (`webbox.site.Site(App)`, or a
//! site that mounts it among its own routes, as angry-gopher does): the
//! paths, the page and the event stream here; the chat itself, its state,
//! its files and its heap, in src/chat_host.zig over ChatServer.codex and
//! ChatStore.codex compiled to Zig (src/gen/chat.zig).
//!
//!   GET /codex-chat/                 the page: ChatPage.codex as Cobblestone's
//!                                    HTML plug builds it (web/chat.html)
//!   GET /codex-chat/api/chat/events  the event stream: `changed` after each
//!                                    change
//!   /codex-chat/api/chat/*           ChatServer's routes, without the prefix
//!
//! **EVERY NAME IT HAS ON A HOST CARRIES `codex-chat`**: its paths, its bus
//! key, its files' folder and the page's localStorage key, so it shares a
//! site with Gopher Chat without one in common. The page asks for the API
//! relative to itself.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const chat = @import("chat_host.zig");

/// Where everything this chat serves lives on a site.
pub const prefix = "/codex-chat";

/// The bus key every page's event stream listens on; a change publishes
/// `changed`, and each page asks again with its own token.
const events_key = "codex-chat";

/// The data root when the host names none (a checkout); chat_main.zig may
/// set it from CHAT_DATA.
pub var data_dir: []const u8 = "data";

pub const StartReport = chat.StartReport;

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    return chat.setup(io, base, if (roots) |r| r.data_dir else data_dir);
}

pub const refresh = chat.refresh;

/// No route reads a body: the page sends its parameters in the query.
pub fn bodyLimit(path: []const u8) u64 {
    _ = path;
    return 4096;
}

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *webbox.bus.Bus) !void {
    const whole = try http.target(req, alloc);
    const path = http.pathUnder(http.pathOf(whole), prefix) orelse return http.notFound(req);
    // The page's relative URLs need the trailing slash to resolve under it.
    if (path.len == 0) return http.redirect(req, prefix ++ "/");
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/chat.html")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        return req.respond(@embedFile("chat_page"), .{ .extra_headers = &.{http.html_ct} });
    }
    if (std.mem.eql(u8, path, "/api/chat/events")) return webbox.sse.forward(req, bus, events_key);
    if (!std.mem.startsWith(u8, path, "/api/")) return http.notFound(req);
    _ = try http.readLimitedBody(req, alloc, bodyLimit(path));
    const r = try chat.answer(io, alloc, @tagName(req.head.method), whole[prefix.len..], path);
    if (r.changed) bus.publish(events_key, "changed");
    return req.respond(r.body, .{ .status = r.status, .extra_headers = &.{.{ .name = "content-type", .value = r.content_type }} });
}
