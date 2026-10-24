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

const std = @import("std");
const chat = @import("gen/chat.zig").api;

/// Garbage the changes may leave before the state is read again: about
/// 4,000 sends at the 8 KB one costs.
pub const default_garbage_budget: i64 = 32 * 1024 * 1024;

/// The Codex heap's region on every host: the bare-metal one has no virtual
/// memory to reserve 4 GiB from, and the Linux one is held to the same, so a
/// chat that outgrows it fails in a checkout first. What it holds is the
/// state as last read (about 20 KB a stored message, with what its reading
/// left), the garbage budget, and the largest answer being built: a
/// 3,000-message chat peaks near 105 MB.
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

/// The state as the files hold it; `problem` says why not, when they cannot
/// be trusted with the next write.
pub fn start(problem: *[]const u8) StartError!Host {
    if (chat.heapRegionSize() != heap_region) chat.heapRegion(heap_region);
    chat.heapReset();
    const l = chat.load();
    if (l.problem.len > 0) {
        problem.* = l.problem;
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
