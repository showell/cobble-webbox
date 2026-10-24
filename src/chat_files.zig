//! Codex Chat's files, kept by webbox: the host behind the FileSystem ops
//! ChatStore.codex performs (read-text, write-file, append-file, list-dir,
//! make-dir), which the ZigEmitter turns into calls on `cx_file_host`.
//!
//! **EVERY PATH IS UNDER THE HOST'S DATA ROOT**, through webbox's store, so
//! the files keep FAT's rules on Linux as on the bare-metal host, and sit
//! where the host keeps its own: `data/codex-chat/...` in a checkout, and
//! the attached volume's data root on a droplet, beside Gopher Chat's
//! `chat/`. ChatStore names every path from `codex-chat/`.
//!
//! What a call answers lives until the next call (`answers` is reset as
//! each one starts), which is as long as the emitted code holds it: it
//! copies a read or a listing into Codex text at once. One handler runs at
//! a time on webbox's hosts, so the state here is shared plainly.
//!
//! **A FILE THAT WILL NOT READ IS NOT AN ABSENT FILE.** An absent one reads
//! as "" (FileSystem's answer); any other failure stops the server, since
//! answering "" would read as no account or no messages and the next write
//! would build on that.

const std = @import("std");
const Io = @import("host_io").Io;
const store = @import("webbox").store;

var root: []const u8 = "data";
var io: Io = undefined;
var answers: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// The host as the emitted code takes it (gen/*.zig's `CxFileHost`).
pub fn host(comptime FileHost: type) FileHost {
    return .{ .read = read, .write = write, .append = append, .list = list, .make_dir = makeDir };
}

/// Where the files are and the Io they are reached through, set as the host
/// starts: `data_dir` is the host's data root.
pub fn use(host_io: Io, data_dir: []const u8) void {
    io = host_io;
    root = data_dir;
}

/// The arena for one call, emptied of the last call's answer.
fn call() std.mem.Allocator {
    _ = answers.reset(.retain_capacity);
    return answers.allocator();
}

/// `path` under the data root, or null for a path that would leave it.
fn under(a: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (path.len == 0 or path[0] == '/') return null;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |p| if (std.mem.eql(u8, p, "..")) return null;
    return std.fs.path.join(a, &.{ root, path }) catch null;
}

fn read(path: []const u8) ?[]const u8 {
    const a = call();
    const p = under(a, path) orelse return null;
    return store.readOrNull(io, a, p, .unlimited) catch |e|
        std.debug.panic("codex chat: {s} will not read: {s}", .{ p, @errorName(e) });
}

fn write(path: []const u8, bytes: []const u8) bool {
    const a = call();
    const p = under(a, path) orelse return false;
    store.replace(io, a, p, bytes, .{}) catch return false;
    return true;
}

fn append(path: []const u8, bytes: []const u8) bool {
    const a = call();
    const p = under(a, path) orelse return false;
    _ = store.append(io, a, p, bytes) catch return false;
    return true;
}

/// The names joined by newlines, a folder's with a trailing slash, as
/// list-dir answers them.
fn list(path: []const u8) []const u8 {
    const a = call();
    const p = under(a, path) orelse return "";
    const entries = store.list(io, a, p) catch return "";
    var out: std.ArrayList(u8) = .empty;
    for (entries) |e| {
        out.appendSlice(a, e.name) catch return "";
        if (e.kind == .directory) out.append(a, '/') catch return "";
        out.append(a, '\n') catch return "";
    }
    return out.items;
}

fn makeDir(path: []const u8) bool {
    const a = call();
    const p = under(a, path) orelse return false;
    store.makeDir(io, a, p) catch return false;
    return true;
}
