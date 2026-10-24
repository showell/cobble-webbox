//! **CODEX CHAT'S STATE BETWEEN REQUESTS, AND ITS HEAP**: what a site does
//! around each call into the chapters (src/gen/chat.zig), apart from HTTP.
//!
//! The Codex heap is one bump frontier that never frees, so a site that
//! only called the routes would grow by every answer it built. Two rules
//! keep it bounded:
//!
//!   - **A read changes nothing**, so the frontier goes back to where it
//!     was before the read once its answer is copied out: a read costs
//!     nothing that lasts. ChatServer's reads answer with the state they
//!     were given.
//!   - **A change keeps what it made**, beside the garbage it made with it.
//!     When the garbage passes `garbage_budget`, the heap is given back
//!     whole and the state read again from the files, which hold every
//!     change before it is answered (ChatServe's compaction, the same way).
//!
//! The calls run on the caller's stack: 16 MB on both webbox hosts (Linux's
//! request threads, the bare-metal host's one stack), which a 3,000-message
//! conversation fits (chat_test).
//!
//! **THE ONE CHAT A SITE SERVES** (`setup`, `refresh`, `answer`, below):
//! its files and its heap's region, set once; files it cannot trust, which
//! make every answer a 503 saying why (a site the chat is part of serves
//! the rest); and what the host knows that ChatServer asks of it, the time
//! of day and a fresh token. chat_app.zig is the HTTP around `answer`.

const std = @import("std");
const Io = @import("host_io").Io;
const chat = @import("gen/chat.zig").api;
const chat_files = @import("chat_files.zig");

/// Garbage the changes may leave before the state is read again: about
/// 4,000 sends at the 8 KB one costs.
pub const default_garbage_budget: i64 = 32 * 1024 * 1024;

/// The Codex heap's region a site gives (`chat.heapGive`) on every host: the
/// bare-metal one has no virtual memory to reserve 4 GiB from, and the
/// Linux one is held to the same, so a chat that outgrows it fails in a
/// checkout first. What it holds is the state as last read (about 20 KB a
/// stored message, with what its reading left), the garbage budget, and the
/// largest answer being built: a 3,000-message chat peaks near 105 MB.
pub const heap_region: usize = 256 * 1024 * 1024;

/// The routes after which server.ps1 saved its state: ChatServer's only
/// changes.
pub const changing = [_][]const u8{ "/api/chat/register", "/api/chat/send", "/api/chat/start", "/api/chat/group" };

pub fn changes(path: []const u8) bool {
    for (changing) |c| if (std.mem.eql(u8, path, c)) return true;
    return false;
}

pub const Answer = struct {
    /// How it went: `saved` false is a change the files refused (the state
    /// is read again from them, and the body is ChatServer's answer to a
    /// change that did not happen, so the site answers an error instead).
    saved: bool,
    content_type: []const u8,
    body: []const u8,
};

state: chat.State,
/// The heap in use just after the state was last read, so the garbage since
/// is what the frontier has gone past it.
loaded_at: i64,
/// How many times the state has been read again: a test's measure.
reloads: usize = 0,
garbage_budget: i64 = default_garbage_budget,

const Host = @This();

pub const StartError = error{FilesUntrusted};

/// The state as the files hold it; `why` says why not, when they cannot be
/// trusted with the next write.
pub fn start(why: *[]const u8) StartError!Host {
    chat.heapReset();
    const l = chat.load();
    if (l.problem.len > 0) {
        why.* = l.problem;
        return error.FilesUntrusted;
    }
    return .{ .state = l.state, .loaded_at = chat.heapUsed() };
}

/// One request: `path` is the target's path, which says whether it may
/// change anything. The answer's body and type are `alloc`'s.
pub fn request(self: *Host, alloc: std.mem.Allocator, time: []const u8, token: []const u8, method: []const u8, target: []const u8, path: []const u8) !Answer {
    const before = chat.heapMark();
    errdefer chat.heapBack(before);
    const change = changes(path);
    const m = chat.mark(self.state);
    const a = try chat.route(self.state, time, token, method, target, "");
    const out: Answer = .{ .saved = true, .content_type = try alloc.dupe(u8, a.content_type), .body = try alloc.dupe(u8, a.body) };
    if (!change) {
        chat.heapBack(before);
        return out;
    }
    self.state = a.state;
    if (!chat.save(m, self.state)) {
        self.reload();
        return .{ .saved = false, .content_type = out.content_type, .body = out.body };
    }
    if (chat.heapUsed() - self.loaded_at > self.garbage_budget) self.reload();
    return out;
}

/// The heap given back and the state read again from the files. They were
/// trusted at the start and only this host has written them since, so a
/// problem now is the machine's, and stops it.
fn reload(self: *Host) void {
    chat.heapReset();
    const l = chat.load();
    if (l.problem.len > 0) std.debug.panic("codex chat: the files it wrote will not read back: {s}", .{l.problem});
    self.state = l.state;
    self.loaded_at = chat.heapUsed();
    self.reloads += 1;
}

// ── The one chat a site serves ───────────────────────────────────────────

var served: Host = undefined;
/// Why the chat is not served, or "" while it is.
var problem: []const u8 = "not started";
/// Whether `setup` has run: the files' host and the heap's region are its.
var set_up = false;

pub const StartReport = struct { files: []const u8, problem: []const u8 };

/// The chat's files under `data_dir`, its heap's region from `base` (zeroed,
/// as bare metal's boot zero-fills its heap), and its state read from them.
pub fn setup(io: Io, base: std.mem.Allocator, data_dir: []const u8) !StartReport {
    chat_files.use(io, base, data_dir);
    chat.useFiles(chat_files.host(chat.FileHost));
    const region = try base.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
    @memset(region, 0);
    chat.heapGive(region);
    set_up = true;
    refresh();
    return .{ .files = data_dir, .problem = problem };
}

/// The state read again from the files: at the start, and after something
/// other than this chat changed them (a site's script on its store). A site
/// that never set the chat up has none to read.
pub fn refresh() void {
    if (!set_up) return;
    var why: []const u8 = "";
    if (start(&why)) |h| {
        served = h;
        problem = "";
    } else |_| problem = why;
}

/// What a site answers an API request with; `changed` says the pages should
/// be told.
pub const Reply = struct {
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
    changed: bool,
};

/// One API request (`target` and its `path` without the site's prefix).
pub fn answer(io: Io, alloc: std.mem.Allocator, method: []const u8, target: []const u8, path: []const u8) !Reply {
    if (problem.len > 0)
        return .{ .status = .service_unavailable, .content_type = "text/plain; charset=utf-8", .body = try std.fmt.allocPrint(alloc, "codex chat is not serving its files: {s}", .{problem}), .changed = false };
    var time: [5]u8 = undefined;
    var token: [16]u8 = undefined;
    timeOfDay(io, &time);
    freshToken(io, &token);
    const json = "application/json; charset=utf-8";
    const a = served.request(alloc, &time, &token, method, target, path) catch |e| switch (e) {
        error.NotAscii => return .{ .status = .bad_request, .content_type = json, .body = "{\"error\":\"the request is not ASCII\"}", .changed = false },
        else => return e,
    };
    if (!a.saved) return .{ .status = .internal_server_error, .content_type = json, .body = "{\"error\":\"the disk refused the write\"}", .changed = false };
    return .{ .status = .ok, .content_type = try std.fmt.allocPrint(alloc, "{s}; charset=utf-8", .{a.content_type}), .body = a.body, .changed = changes(path) };
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
