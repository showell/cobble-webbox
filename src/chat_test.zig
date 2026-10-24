//! ChatServer.codex and ChatStore.codex, compiled to Zig (src/gen/chat.zig),
//! keeping a chat in files: a fresh data root, a short conversation saved to
//! it through the FileSystem effect (src/chat_files.zig over webbox's store)
//! request by request as the site saves it, the files it leaves, and the
//! state read back from them as a restarted server reads it; then a damaged
//! account file, which a load must refuse rather than serve.

const std = @import("std");
const store = @import("webbox").store;
const chat = @import("gen/chat.zig").api;
const chat_files = @import("chat_files.zig");

/// `f(args)` on the chapter's stack, as the site calls it.
fn big(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    return @import("stack.zig").onBigStack(f, args);
}

/// One request, saved as the site saves it: a mark before the route, what
/// the route added written after it.
fn get(state: *chat.State, target: []const u8, token: []const u8) ![]const u8 {
    const Call = struct {
        fn run(s: *chat.State, t: []const u8, tok: []const u8) error{ NotAscii, NotSaved }![]const u8 {
            const m = chat.mark(s.*);
            const a = try chat.route(s.*, "12:00", tok, "GET", t, "");
            s.* = a.state;
            if (!chat.save(m, s.*)) return error.NotSaved;
            return a.body;
        }
    };
    return big(Call.run, .{ state, target, token });
}

fn loadClean() !chat.State {
    const l = big(chat.load, .{});
    try std.testing.expectEqualStrings("", l.problem);
    return l.state;
}

test "a chat kept in files through Codex's FileSystem effect is there after a restart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path, "data" });
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    chat_files.use(io, data);
    chat.useFiles(chat_files.host(chat.FileHost));
    defer chat.useFiles(null);

    // A fresh root loads as a fresh state: nobody holds a token yet.
    var state = try loadClean();
    try std.testing.expectEqualStrings("{\"error\":\"auth\"}", try get(&state, "/api/chat/me?t=tok-ann", "x"));

    _ = try get(&state, "/api/chat/register?name=ann", "tok-ann");
    _ = try get(&state, "/api/chat/register?name=ben", "tok-ben");
    try std.testing.expectEqualStrings("{\"convId\":\"c1\"}", try get(&state, "/api/chat/start?t=tok-ann&with=ben", "x"));
    _ = try get(&state, "/api/chat/send?t=tok-ann&to=c1&body=kept+on+disk", "x");
    _ = try get(&state, "/api/chat/send?t=tok-ben&to=c1&body=and+appended", "x");

    // The files are where ChatStore says, in the host's data root: an
    // account each, and each message a line of its conversation's messages.
    const path = struct {
        fn of(al: std.mem.Allocator, root: []const u8, rel: []const u8) []const u8 {
            return std.fs.path.join(al, &.{ root, "codex-chat", rel }) catch unreachable;
        }
    }.of;
    try std.testing.expectEqualStrings("{\"name\":\"ann\",\"token\":\"tok-ann\"}", try store.read(io, a, path(a, data, "users/0.json"), .unlimited));
    try std.testing.expectEqualStrings("{\"id\":\"c1\",\"kind\":\"dm\",\"name\":\"\",\"members\":[\"ann\",\"ben\"]}", try store.read(io, a, path(a, data, "convs/c1/conv.json"), .unlimited));
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"sender\":\"ann\",\"body\":\"kept on disk\",\"time\":\"12:00\"}\n{\"id\":2,\"sender\":\"ben\",\"body\":\"and appended\",\"time\":\"12:00\"}\n",
        try store.read(io, a, path(a, data, "convs/c1/messages.jsonl"), .unlimited),
    );

    // A restart: nothing kept but the files.
    var again = try loadClean();
    const msgs = try get(&again, "/api/chat/messages?t=tok-ben&conv=c1", "x");
    try std.testing.expectEqualStrings("{\"count\":\"2\",\"body-0\":\"kept on disk\",\"sender-0\":\"ann\",\"time-0\":\"12:00\",\"mine-0\":\"0\",\"body-1\":\"and appended\",\"sender-1\":\"ben\",\"time-1\":\"12:00\",\"mine-1\":\"1\"}", msgs);
    // And it goes on from where it was: the next conversation is c2.
    _ = try get(&again, "/api/chat/register?name=cat", "tok-cat");
    try std.testing.expectEqualStrings("{\"convId\":\"c2\"}", try get(&again, "/api/chat/start?t=tok-ben&with=cat", "x"));
    // A name claimed before the restart is still claimed after it.
    try std.testing.expectEqualStrings("{\"error\":\"name taken\"}", try get(&again, "/api/chat/register?name=ann", "tok-other"));

    // An account file that does not parse is files the next claim could
    // overwrite someone in: the load says so instead of serving them.
    try store.write(io, a, path(a, data, "users/0.json"), "x\"name\":\"ann\"", .{});
    const damaged = big(chat.load, .{});
    try std.testing.expectEqualStrings("codex-chat/users/0.json is missing or does not parse", damaged.problem);
}
