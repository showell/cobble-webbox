//! GameServer.codex, compiled to Zig (src/gen/games.zig), answering as
//! server.ps1's VM answered: a request line in, one printed line out.

const std = @import("std");
const app = @import("app.zig");
const games = @import("gen/games.zig").api;

/// One request on the chapter's own stack, as the site makes it: the next
/// store, and the answer parsed.
fn ask(store: *games.Store, line: []const u8) !app.Answer {
    const Call = struct {
        fn run(out: *anyerror!app.Answer, s: *games.Store, l: []const u8) void {
            out.* = blk: {
                const r = games.dispatch(s.*, l) catch |e| break :blk e;
                s.* = r.store;
                break :blk app.parseAnswer(r.printed orelse break :blk error.NothingPrinted) orelse error.Malformed;
            };
        }
    };
    var out: anyerror!app.Answer = undefined;
    const t = try std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, Call.run, .{ &out, store, line });
    t.join();
    return out;
}

const Ttt = struct { squares: []const i64, cur: i64, done: bool, winner: i64 };

test "tic-tac-toe through GameServer: a new game, then steps until perfect play draws" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var store = games.newStore();
    const first = try ask(&store, "GET /api/tictactoe/new");
    try std.testing.expectEqual(@as(u10, 200), first.status);
    try std.testing.expectEqualStrings("application/json", first.content_type);
    var board = try std.json.parseFromSliceLeaky(Ttt, a, first.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 9), board.squares.len);
    for (board.squares) |sq| try std.testing.expectEqual(@as(i64, 0), sq);
    var steps: usize = 0;
    while (!board.done) : (steps += 1) {
        try std.testing.expect(steps < 9);
        const r = try ask(&store, "GET /api/tictactoe/step");
        try std.testing.expectEqual(@as(u10, 200), r.status);
        board = try std.json.parseFromSliceLeaky(Ttt, a, r.body, .{ .ignore_unknown_fields = true });
    }
    try std.testing.expectEqual(@as(usize, 9), steps);
    try std.testing.expectEqual(@as(i64, 0), board.winner);
}

test "an unknown game is GameServer's own 404, and a step with no game its 400" {
    var store = games.newStore();
    const nf = try ask(&store, "GET /api/nosuchgame/new");
    try std.testing.expectEqual(@as(u10, 404), nf.status);
    const no_game = try ask(&store, "GET /api/tictactoe/step");
    try std.testing.expectEqual(@as(u10, 400), no_game.status);
    try std.testing.expect(std.mem.indexOf(u8, no_game.body, "no active game") != null);
}
