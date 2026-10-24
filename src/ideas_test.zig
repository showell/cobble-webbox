//! IdeaWeb.codex, compiled to Zig (src/gen/ideas.zig), keeping the house's
//! rules: three candidates a deal, one deal a caller a day, a claim
//! reserves its seed for good, and the ledger shows it.

const std = @import("std");
const ideas = @import("gen/ideas.zig").api;
const statusOf = @import("ideas_app.zig").statusOf;

const House = struct {
    state: ideas.State,

    fn ask(h: *House, who: []const u8, day: i64, target: []const u8) !ideas.Answer {
        const Call = struct {
            fn run(out: *anyerror!ideas.Answer, hh: *House, w: []const u8, d: i64, t: []const u8) void {
                out.* = blk: {
                    const a = ideas.route(hh.state, w, d, "GET", t, "") catch |e| break :blk e;
                    hh.state = a.state;
                    break :blk a;
                };
            }
        };
        var out: anyerror!ideas.Answer = undefined;
        const t = try std.Thread.spawn(.{ .stack_size = 512 * 1024 * 1024 }, Call.run, .{ &out, h, who, day, target });
        t.join();
        return out;
    }
};

const Offer = struct { offer: i64, candidates: []const std.json.Value };

test "a deal, a second deal the same day refused, a claim, and the ledger" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var house: House = .{ .state = ideas.newState() };

    const health = try house.ask("alice", 0, "/api/health");
    try std.testing.expectEqual(@as(?u10, 200), statusOf(health.status));
    try std.testing.expect(std.mem.indexOf(u8, health.body, "idea-forge") != null);

    const deal = try house.ask("alice", 0, "/offer?prompt=build+me+a+website+that+makes+me+a+million+dollars");
    try std.testing.expectEqual(@as(?u10, 200), statusOf(deal.status));
    const offer = try std.json.parseFromSliceLeaky(Offer, a, deal.body, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 3), offer.candidates.len);

    const again = try house.ask("alice", 0, "/offer?prompt=again");
    try std.testing.expectEqual(@as(?u10, 429), statusOf(again.status));
    // Another day, another deal.
    const tomorrow = try house.ask("alice", 1, "/offer?prompt=again");
    try std.testing.expectEqual(@as(?u10, 200), statusOf(tomorrow.status));

    const claim = try house.ask("alice", 0, try std.fmt.allocPrint(a, "/claim?offer={d}&pick=1", .{offer.offer}));
    try std.testing.expectEqual(@as(?u10, 200), statusOf(claim.status));
    // Not bob's offer to claim.
    const foreign = try house.ask("bob", 0, try std.fmt.allocPrint(a, "/claim?offer={d}&pick=0", .{offer.offer}));
    try std.testing.expectEqual(@as(?u10, 404), statusOf(foreign.status));

    const ledger = try house.ask("bob", 0, "/claims");
    try std.testing.expectEqual(@as(?u10, 200), statusOf(ledger.status));
    try std.testing.expect(std.mem.indexOf(u8, ledger.body, "ali***") != null);
}
