//! Codex Chat (Cobblestone's apps/chat), served by webbox
//! (`webbox.site.Site(App)`): ChatServer.codex's routes and ChatStore.codex's
//! disk, compiled to Zig (src/gen/chat.zig), in place of apps/chat/web/
//! server.ps1, which served the same page and the same API.
//!
//!   GET /, /chat.html   the page: apps/chat/web/chat.html, Cobblestone's own
//!                       build of ChatPage.codex (web/chat.html, compiled in)
//!   /api/chat/*         ChatServer's `chat-route`, with what the host knows:
//!                       the time of day (UTC, `HH:mm`) and a fresh token
//!                       (16 hex digits, as server.ps1 cut its GUIDs)
//!
//! **THE STATE IS ON A DISK CODEX DRIVES.** `disk_path` is a FAT16 volume
//! (a blank one is made the first time, src/fat16_blank.zig); ChatStore
//! reads it at the start and writes it after every request that changes
//! anything (register, send, start, group: server.ps1's Save-State calls),
//! through the Fat16 foreword, whose sectors this host reads and writes in
//! the image (`readSector`, `writeSector`). The file it keeps there,
//! CHAT.JSN, is the same one ChatStore keeps on bare metal.

const std = @import("std");
const Io = @import("host_io").Io;
const webbox = @import("webbox");
const http = webbox.http;
const chat = @import("gen/chat.zig").api;
const fat16_blank = @import("fat16_blank.zig");
const onBigStack = @import("stack.zig").onBigStack;

/// The disk image; main.zig may set it from CHAT_DISK.
pub var disk_path: []const u8 = "data/chat.img";

var disk: std.Io.File = undefined;
var disk_io: Io = undefined;
/// One handler runs at a time (webbox's hosts), so it is shared plainly.
var state: chat.State = undefined;

pub const StartReport = struct { disk: []const u8, made: bool };

pub fn setup(io: Io, base: std.mem.Allocator, roots: ?webbox.site.Roots) !StartReport {
    _ = base;
    _ = roots;
    disk_io = io;
    var made = false;
    if (std.fs.path.dirname(disk_path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch {};
    disk = Io.Dir.cwd().openFile(io, disk_path, .{ .mode = .read_write }) catch |e| switch (e) {
        error.FileNotFound => blk: {
            try fat16_blank.create(io, disk_path);
            made = true;
            break :blk try Io.Dir.cwd().openFile(io, disk_path, .{ .mode = .read_write });
        },
        else => return e,
    };
    chat.useDisk(.{ .read = readSector, .write = writeSector });
    state = onBigStack(chat.load, .{});
    return .{ .disk = disk_path, .made = made };
}

fn readSector(lba: u64, sector: *[512]u8) bool {
    const n = disk.readPositionalAll(disk_io, sector, lba * 512) catch return false;
    return n == 512;
}

fn writeSector(lba: u64, sector: *const [512]u8) bool {
    disk.writePositionalAll(disk_io, sector, lba * 512) catch return false;
    return true;
}

/// No route reads a body: the page sends its parameters in the query, a
/// POST's too.
pub fn bodyLimit(path: []const u8) u64 {
    _ = path;
    return 4096;
}

/// The routes after which server.ps1 saved its state.
const changing = [_][]const u8{ "/api/chat/register", "/api/chat/send", "/api/chat/start", "/api/chat/group" };

pub fn routes(req: *std.http.Server.Request, io: Io, alloc: std.mem.Allocator, _: *webbox.bus.Bus) !void {
    const target = try http.target(req, alloc);
    const path = http.pathOf(target);
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/chat.html")) {
        if (req.head.method != .GET) return http.methodNotAllowed(req, .GET);
        return req.respond(@embedFile("chat_page"), .{ .extra_headers = &.{http.html_ct} });
    }
    if (!std.mem.startsWith(u8, path, "/api/")) return http.notFound(req);
    _ = try http.readLimitedBody(req, alloc, 4096);
    var time: [5]u8 = undefined;
    var token: [16]u8 = undefined;
    timeOfDay(io, &time);
    freshToken(io, &token);
    const answer = onBigStack(routeOne, .{ &time, &token, @tagName(req.head.method), target }) catch
        return req.respond("{\"error\":\"the request is not ASCII\"}", .{ .status = .bad_request, .extra_headers = &.{http.json_ct} });
    for (changing) |c| if (std.mem.eql(u8, path, c)) {
        if (!onBigStack(chat.save, .{state})) return req.respond("{\"error\":\"the disk refused the write\"}", .{ .status = .internal_server_error, .extra_headers = &.{http.json_ct} });
        try disk.sync(disk_io);
        break;
    };
    const content_type = try std.fmt.allocPrint(alloc, "{s}; charset=utf-8", .{answer.content_type});
    return req.respond(answer.body, .{ .extra_headers = &.{.{ .name = "content-type", .value = content_type }} });
}

fn routeOne(time: *const [5]u8, token: *const [16]u8, method: []const u8, target: []const u8) error{NotAscii}!chat.Answer {
    const a = try chat.route(state, time, token, method, target, "");
    state = a.state;
    return a;
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
