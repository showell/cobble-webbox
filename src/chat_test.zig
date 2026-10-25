//! ChatServer.codex and ChatStore.codex, compiled to Zig (src/gen/chat.zig),
//! through the site's host (src/chat_host.zig) on the stack both webbox
//! hosts give a request, 16 MB: a chat kept in files (src/chat_files.zig
//! over webbox's store), read back after a restart, and refused when an
//! account file is damaged; then a long conversation, and the Codex heap it
//! leaves behind, which the host keeps bounded.

const std = @import("std");
const store = @import("webbox").store;
const chat = @import("chat_api.zig").api;
const chat_files = @import("chat_files.zig");
const ChatHost = @import("chat_host.zig");

/// zig-metal-unikernel's one stack, and Linux's request threads' default.
const request_stack = 16 * 1024 * 1024;

fn onRequestStack(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    return @import("stack.zig").onStack(request_stack, f, args);
}

/// One request through the host, as the site makes it; the answer's body.
fn get(host: *ChatHost, a: std.mem.Allocator, target: []const u8, token: []const u8) ![]const u8 {
    const Call = struct {
        fn run(h: *ChatHost, al: std.mem.Allocator, t: []const u8, tok: []const u8) anyerror![]const u8 {
            const path = t[0 .. std.mem.indexOfScalar(u8, t, '?') orelse t.len];
            const answer = try h.request(al, "12:00", tok, "GET", t, path);
            if (!answer.saved) return error.NotSaved;
            return answer.body;
        }
    };
    return onRequestStack(Call.run, .{ host, a, target, token });
}

fn startClean() !ChatHost {
    const Call = struct {
        fn run(problem: *[]const u8) ChatHost.StartError!ChatHost {
            return ChatHost.start(problem);
        }
    };
    var problem: []const u8 = "";
    const h = onRequestStack(Call.run, .{&problem}) catch |e| {
        std.debug.print("start: {s}\n", .{problem});
        return e;
    };
    return h;
}

const Root = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    threaded: std.Io.Threaded,
    data: []const u8,

    fn init(self: *Root) !void {
        self.arena = .init(std.testing.allocator);
        self.tmp = std.testing.tmpDir(.{});
        self.data = try std.fs.path.join(self.arena.allocator(), &.{ ".zig-cache", "tmp", &self.tmp.sub_path, "data" });
        self.threaded = .init(self.arena.allocator(), .{});
        chat_files.use(self.threaded.io(), self.arena.allocator(), self.data);
        chat.useFiles(chat_files.host(chat.FileHost));
        chat.heapGive(region());
    }

    /// The heap's one region for the whole test process, as a site gives it.
    var given: ?[]align(4096) u8 = null;
    fn region() []align(4096) u8 {
        if (given == null) {
            const r = std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), ChatHost.heap_region) catch @panic("no region for the Codex heap");
            @memset(r, 0);
            given = r;
        }
        return given.?;
    }
    fn deinit(self: *Root) void {
        chat.useFiles(null);
        self.threaded.deinit();
        self.tmp.cleanup();
        self.arena.deinit();
    }
    fn path(self: *Root, rel: []const u8) []const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.data, rel }) catch unreachable;
    }
};

test "a chat kept in files through Codex's FileSystem effect is there after a restart" {
    var r: Root = undefined;
    try r.init();
    defer r.deinit();
    const a = r.arena.allocator();
    const io = r.threaded.io();

    // A fresh root starts a fresh chat: nobody holds a token yet.
    var host = try startClean();
    try std.testing.expectEqualStrings("{\"error\":\"auth\"}", try get(&host, a, "/api/chat/me?t=tok-ann", "x"));

    _ = try get(&host, a, "/api/chat/register?name=ann", "tok-ann");
    _ = try get(&host, a, "/api/chat/register?name=ben", "tok-ben");
    try std.testing.expectEqualStrings("{\"convId\":\"c1\"}", try get(&host, a, "/api/chat/start?t=tok-ann&with=ben", "x"));
    _ = try get(&host, a, "/api/chat/send?t=tok-ann&to=c1&body=kept+on+disk", "x");
    _ = try get(&host, a, "/api/chat/send?t=tok-ben&to=c1&body=and+appended", "x");

    // The files are where ChatStore says, in the host's data root: an
    // account each, and each message a line of its conversation's messages.
    try std.testing.expectEqualStrings("{\"name\":\"ann\",\"token\":\"tok-ann\"}", try store.read(io, a, r.path("users/0.json"), .unlimited));
    try std.testing.expectEqualStrings("{\"id\":\"c1\",\"kind\":\"dm\",\"name\":\"\",\"members\":[\"ann\",\"ben\"]}", try store.read(io, a, r.path("convs/c1/conv.json"), .unlimited));
    try std.testing.expectEqualStrings(
        "{\"id\":1,\"sender\":\"ann\",\"body\":\"kept on disk\",\"time\":\"12:00\"}\n{\"id\":2,\"sender\":\"ben\",\"body\":\"and appended\",\"time\":\"12:00\"}\n",
        try store.read(io, a, r.path("convs/c1/messages.jsonl"), .unlimited),
    );

    // A restart: nothing kept but the files.
    var again = try startClean();
    const msgs = try get(&again, a, "/api/chat/messages?t=tok-ben&conv=c1", "x");
    try std.testing.expectEqualStrings("{\"count\":\"2\",\"body-0\":\"kept on disk\",\"sender-0\":\"ann\",\"time-0\":\"12:00\",\"mine-0\":\"0\",\"body-1\":\"and appended\",\"sender-1\":\"ben\",\"time-1\":\"12:00\",\"mine-1\":\"1\"}", msgs);
    // And it goes on from where it was: the next conversation is c2.
    _ = try get(&again, a, "/api/chat/register?name=cat", "tok-cat");
    try std.testing.expectEqualStrings("{\"convId\":\"c2\"}", try get(&again, a, "/api/chat/start?t=tok-ben&with=cat", "x"));
    // A name claimed before the restart is still claimed after it.
    try std.testing.expectEqualStrings("{\"error\":\"name taken\"}", try get(&again, a, "/api/chat/register?name=ann", "tok-other"));

    // An account file that does not parse is files the next claim could
    // overwrite someone in: the host says so instead of serving them.
    try store.write(io, a, r.path("users/0.json"), "x\"name\":\"ann\"", .{});
    var problem: []const u8 = "";
    try std.testing.expectError(error.FilesUntrusted, ChatHost.start(&problem));
    try std.testing.expectEqualStrings("codex-chat/users/0.json is missing or does not parse", problem);
}

test "a long conversation on a 16 MB stack, in a Codex heap the host keeps bounded" {
    var r: Root = undefined;
    try r.init();
    defer r.deinit();
    const a = r.arena.allocator();

    var host = try startClean();
    // Small enough that 3,000 sends (about 23 MB of garbage) pass it
    // several times.
    host.garbage_budget = 4 * 1024 * 1024;
    _ = try get(&host, a, "/api/chat/register?name=ann", "tok-ann");
    _ = try get(&host, a, "/api/chat/register?name=ben", "tok-ben");
    _ = try get(&host, a, "/api/chat/start?t=tok-ann&with=ben", "x");

    const messages = 3000;
    var most: i64 = 0;
    var i: usize = 0;
    while (i < messages) : (i += 1) {
        const t = try std.fmt.allocPrint(a, "/api/chat/send?t={s}&to=c1&body=message+number+{d}+of+a+long+conversation", .{ if (i % 2 == 0) "tok-ann" else "tok-ben", i });
        _ = try get(&host, a, t, "x");
        most = @max(most, chat.heapUsed());
        // A read in between gives back everything it made.
        if (i % 500 == 0) {
            const before = chat.heapUsed();
            _ = try get(&host, a, "/api/chat/conversations?t=tok-ann", "x");
            try std.testing.expectEqual(before, chat.heapUsed());
        }
    }
    // The heap never held more than the state as last read and the garbage
    // budget beside it, so the state was read again on the way.
    try std.testing.expect(host.reloads >= 1);
    try std.testing.expect(most <= host.loaded_at + host.garbage_budget + 1024 * 1024);

    // The one answer that holds every message, through the state as read
    // again, and given back once answered.
    const before = chat.heapUsed();
    const all = try get(&host, a, "/api/chat/messages?t=tok-ben&conv=c1", "x");
    try std.testing.expect(std.mem.indexOf(u8, all, "\"count\":\"3000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, all, "\"body-2999\":\"message number 2999 of a long conversation\"") != null);
    try std.testing.expectEqual(before, chat.heapUsed());

    std.debug.print("\n  codex heap: {d} reloads; most {d:.1} MB; the state as last read {d:.1} MB; {d} bytes in the longest answer\n", .{ host.reloads, mb(most), mb(host.loaded_at), all.len });
}

fn mb(n: i64) f64 {
    return @as(f64, @floatFromInt(n)) / (1024.0 * 1024.0);
}
