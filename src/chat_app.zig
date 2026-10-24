//! Codex Chat (Cobblestone's apps/chat), served by webbox
//! (`webbox.site.Site(App)`): ChatServer.codex's routes and ChatStore.codex's
//! disk, compiled to Zig (src/gen/chat.zig), in place of apps/chat/web/
//! server.ps1, which served the same page and the same API.
//!
//!   GET /codex-chat/              the page: Cobblestone's own build of
//!                                 ChatPage.codex (web/chat.html, compiled in)
//!   GET /codex-chat/api/chat/events  the event stream: `changed` after each
//!                                 change
//!   /codex-chat/api/chat/*        ChatServer's `chat-route`, given the path
//!                                 without the prefix, with what the host
//!                                 knows: the time of day (UTC, `HH:mm`) and
//!                                 a fresh token (16 hex digits, as
//!                                 server.ps1 cut its GUIDs)
//!
//! **EVERY NAME IT HAS ON A HOST CARRIES `codex-chat`**: its paths, its bus
//! key, its disk image (and the page's localStorage key), so it can share a
//! site with Gopher Chat (which owns `/chat`, `/channel`, `/login` and `/`,
//! among others) without one in common. The page asks for the API relative
//! to itself, so ChatServer's own paths stay `/api/chat/*`.
//!
//! **THE STATE IS IN FILES THE HOST KEEPS.** ChatStore keeps them through
//! the FileSystem effect, under `codex-chat/` in the host's data root
//! (src/chat_files.zig, over webbox's store): a file per account, per
//! conversation, and each conversation's messages, appended. It reads them
//! at the start and, after every request that changes anything (register,
//! send, start, group: server.ps1's Save-State calls), writes what that
//! request added; the host makes it durable before the next response, as
//! it does every store write. On bare metal the same files are on the boot
//! volume, through the compiler's FAT16 handlers.
//!
//! Files ChatStore will not trust with the next write (a missing account
//! file, a file that does not parse) are not served: the API answers 503
//! with why, so a site this chat is part of (angry-gopher) keeps serving
//! everything else; chat_main.zig, a server of its own, refuses to start.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const chat = @import("gen/chat.zig").api;
const chat_files = @import("chat_files.zig");
const ChatHost = @import("chat_host.zig");

/// The data root when the host names none (a checkout); main.zig may set it
/// from CHAT_DATA.
pub var data_dir: []const u8 = "data";

/// One handler runs at a time (webbox's hosts), so it is shared plainly.
var host: ChatHost = undefined;

/// Why the chat is not served, or "" while it is: files it cannot trust with
/// the next write. The chat answers 503 with it rather than stop the site
/// it is part of; a server of its own (chat_main.zig) refuses to start.
var problem: []const u8 = "not started";

/// Whether `setup` has run: the files' host and the heap's region are its.
var set_up = false;

pub const StartReport = struct { files: []const u8, problem: []const u8 };

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    const dir = if (roots) |r| r.data_dir else data_dir;
    chat_files.use(io, base, dir);
    chat.useFiles(chat_files.host(chat.FileHost));
    const region = try base.alignedAlloc(u8, .fromByteUnits(4096), ChatHost.heap_region);
    @memset(region, 0);
    chat.heapGive(region);
    set_up = true;
    refresh();
    return .{ .files = dir, .problem = problem };
}

/// The state read again from the files: at the start, and after something
/// other than this chat changed them (a site's script on its store). A site
/// that never set the chat up has none to read.
pub fn refresh() void {
    if (!set_up) return;
    var why: []const u8 = "";
    if (ChatHost.start(&why)) |h| {
        host = h;
        problem = "";
    } else |_| problem = why;
}

/// No route reads a body: the page sends its parameters in the query, a
/// POST's too.
pub fn bodyLimit(path: []const u8) u64 {
    _ = path;
    return 4096;
}

/// The bus key every page's event stream listens on. A change publishes
/// `changed` and nothing else: each page asks again with its own token, as
/// ChatServe's streams on bare metal have it.
const events_key = "codex-chat";

/// Where everything this chat serves lives on a site.
pub const prefix = "/codex-chat";

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, bus: *webbox.bus.Bus) !void {
    const whole = try http.target(req, alloc);
    const sub = http.pathUnder(http.pathOf(whole), prefix) orelse return http.notFound(req);
    // The page's relative URLs need the trailing slash to resolve under it.
    if (sub.len == 0) return http.redirect(req, prefix ++ "/");
    const target = whole[prefix.len..];
    const path = sub;
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/chat.html")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        return req.respond(@embedFile("chat_page"), .{ .extra_headers = &.{http.html_ct} });
    }
    if (std.mem.eql(u8, path, "/api/chat/events")) return webbox.sse.forward(req, bus, events_key);
    if (!std.mem.startsWith(u8, path, "/api/")) return http.notFound(req);
    if (problem.len > 0) {
        const msg = try std.fmt.allocPrint(alloc, "codex chat is not serving its files: {s}", .{problem});
        return req.respond(msg, .{ .status = .service_unavailable, .extra_headers = &.{http.plain_ct} });
    }
    _ = try http.readLimitedBody(req, alloc, 4096);
    var time: [5]u8 = undefined;
    var token: [16]u8 = undefined;
    timeOfDay(io, &time);
    freshToken(io, &token);
    const answer = host.request(alloc, &time, &token, @tagName(req.head.method), target, path) catch |e| switch (e) {
        error.NotAscii => return req.respond("{\"error\":\"the request is not ASCII\"}", .{ .status = .bad_request, .extra_headers = &.{http.json_ct} }),
        else => return e,
    };
    if (!answer.saved) return req.respond("{\"error\":\"the disk refused the write\"}", .{ .status = .internal_server_error, .extra_headers = &.{http.json_ct} });
    if (ChatHost.changes(path)) bus.publish(events_key, "changed");
    const content_type = try std.fmt.allocPrint(alloc, "{s}; charset=utf-8", .{answer.content_type});
    return req.respond(answer.body, .{ .extra_headers = &.{.{ .name = "content-type", .value = content_type }} });
}

/// The wall clock's time of day, UTC, as server.ps1 stamped a message
/// (`HH:mm`).
fn timeOfDay(io: Io, out: *[5]u8) void {
    const s: u64 = @intCast(@divFloor(Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s));
    const day = s % std.time.s_per_day;
    _ = std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ day / 3600, day % 3600 / 60 }) catch unreachable;
}

/// 16 random hex digits: a session's name, which only its holder knows.
fn freshToken(io: Io, out: *[16]u8) void {
    var b: [8]u8 = undefined;
    io.random(&b);
    const hex = "0123456789abcdef";
    for (b, 0..) |x, i| {
        out[2 * i] = hex[x >> 4];
        out[2 * i + 1] = hex[x & 15];
    }
}
