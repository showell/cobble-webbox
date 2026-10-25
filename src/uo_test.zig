//! uoaix's proofs, compiled to Zig (src/gen/uo.zig, src/gen/uo_town.zig),
//! run the way a webbox host would run them: on the 16 MB stack both hosts
//! give a request, in a heap region the host gives. Their lines must be
//! their `.expected` files', byte for byte.
//!
//!   - GameVendorReplay: real buy and sell packets against a vendor.
//!   - TownLiveProof: three residents walking a 128x224 town to lodging,
//!     work and tavern seats, its map filled by a recursion over every cell.

const std = @import("std");

/// zig-metal-unikernel's one stack, and Linux's request threads' default.
const request_stack = 16 * 1024 * 1024;

/// Generous for a proof; each test prints what it used.
const heap_region = 512 * 1024 * 1024;

var printed: std.ArrayList(u8) = .empty;

fn sink(line: []const u8) void {
    printed.appendSlice(std.testing.allocator, line) catch @panic("oom");
    printed.append(std.testing.allocator, '\n') catch @panic("oom");
}

fn expectProof(comptime proof: type, comptime name: []const u8, expected: []const u8) !void {
    const region = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
    defer std.heap.page_allocator.free(region);
    @memset(region, 0);
    proof.heapGive(region);
    printed = .empty;
    defer printed.deinit(std.testing.allocator);

    const Run = struct {
        fn run() void {
            proof.runProof(sink);
        }
    };
    @import("stack.zig").onStack(request_stack, Run.run, .{});

    std.debug.print("uo {s}: {d} bytes of Codex heap\n", .{ name, proof.heapUsed() });
    try std.testing.expectEqualStrings(expected, printed.items);
}

test "the vendor proof answers as its expected file, on a request's stack, in a host's region" {
    try expectProof(@import("uo_api.zig").vendor, "vendor proof", @embedFile("uo_expected"));
}

test "the town proof answers as its expected file, on a request's stack, in a host's region" {
    try expectProof(@import("uo_api.zig").town, "town proof", @embedFile("uo_town_expected"));
}

const watch = @import("uo_watch_api.zig").api;

/// TownWatch's heap, one region for the process: its tests' towns are built
/// one above another in it, each measuring its own growth.
var watch_region: ?[]align(4096) u8 = null;

fn giveWatchRegion() !void {
    if (watch_region != null) return;
    const region = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
    @memset(region, 0);
    watch.heapGive(region);
    watch_region = region;
}

/// What a ticking host keeps: the town built once, then brought forward
/// 30 game seconds at a time (the host's quarter-second tick at 120 game
/// seconds a real one) for three game days.
const Ticked = struct { at_work: bool, shut_at_night: usize, shut_by_day: usize, after_day_one: i64, after_day_three: i64, failed: bool };

fn tickThreeDays() Ticked {
    const w = watch.new();
    if (watch.problem(w).len > 0) @panic("uo watch: no town");
    const start: i64 = 6 * 3600;
    const day: i64 = 24 * 3600;
    var out: Ticked = .{ .at_work = false, .shut_at_night = 0, .shut_by_day = 0, .after_day_one = 0, .after_day_three = 0, .failed = false };
    var s: i64 = start;
    while (s <= start + 3 * day) : (s += 30) {
        if (!watch.tick(w, s)) out.failed = true;
        // Mid-morning of day two, everyone is at their shop, not at the inn,
        // and the shops are open by their hours as they were not at 3 am.
        if (s == start + day - 3 * 3600) {
            const mark = watch.heapMark();
            out.shut_at_night = std.mem.count(u8, watch.json(w, s), "\"shut\":1");
            watch.heapBack(mark);
        }
        if (s == start + day + 4 * 3600) {
            const mark = watch.heapMark();
            const j = watch.json(w, s);
            out.at_work = std.mem.indexOf(u8, j, "\"x\":1495") == null;
            out.shut_by_day = std.mem.count(u8, j, "\"shut\":1");
            watch.heapBack(mark);
        }
        if (s == start + day) out.after_day_one = watch.heapUsed();
    }
    out.after_day_three = watch.heapUsed();
    return out;
}

/// A player who walks between Good Eats (its oven, where Nell works) and
/// the Hammer And Anvil (Jorin's) every two game hours, for three game days.
const Walked = struct { greetings: usize, from_nell: bool, arrived: bool, valid: bool, after_day_one: i64, after_day_three: i64 };

fn walkThreeDays() Walked {
    const w = watch.new();
    if (watch.problem(w).len > 0) @panic("uo watch: no town");
    var out: Walked = .{ .greetings = 0, .from_nell = false, .arrived = false, .valid = false, .after_day_one = 0, .after_day_three = 0 };
    if ((watch.join(w, 0, "Ann") catch -1) <= 0) return out;
    const start: i64 = 6 * 3600;
    const day: i64 = 24 * 3600;
    var s: i64 = start;
    while (s <= start + 3 * day) : (s += 30) {
        if (@mod(s - start, 2 * 3600) == 0) {
            const to_baker = @mod(@divTrunc(s - start, 2 * 3600), 2) == 0;
            _ = if (to_baker) watch.goal(w, 0, 1449, 1613) else watch.goal(w, 0, 1418, 1547);
        }
        if (!watch.tick(w, s)) @panic("uo watch: a step failed");
        const mark = watch.heapMark();
        const said = watch.greet(w, s);
        out.greetings += std.mem.count(u8, said, "\"who\":");
        if (std.mem.indexOf(u8, said, "\"who\":\"Nell\"") != null) out.from_nell = true;
        if (std.mem.indexOf(u8, watch.json(w, s), "\"name\":\"Ann\",\"x\":1449,\"y\":1613") != null) out.arrived = true;
        watch.heapBack(mark);
        if (s == start + day) out.after_day_one = watch.heapUsed();
    }
    out.after_day_three = watch.heapUsed();
    out.valid = watch.valid(w);
    return out;
}

test "a player walks the town for three game days: greeted at the shops, the town valid, the heap flat after the first day" {
    try giveWatchRegion();
    const t = @import("stack.zig").onStack(request_stack, walkThreeDays, .{});

    std.debug.print("uo player: {d} greetings (Nell among them: {}), arrived {}, valid {}; heap {d} after a day, {d} after three\n", .{ t.greetings, t.from_nell, t.arrived, t.valid, t.after_day_one, t.after_day_three });
    try std.testing.expect(t.arrived);
    try std.testing.expect(t.greetings > 0);
    try std.testing.expect(t.valid);
    try std.testing.expectEqual(t.after_day_one, t.after_day_three);
}

test "the town watch ticks three game days on a request's stack: shops open by their hours, the heap flat after the first" {
    try giveWatchRegion();
    const t = @import("stack.zig").onStack(request_stack, tickThreeDays, .{});

    std.debug.print("uo town watch: {d} bytes of Codex heap after a day, {d} after three; {d} shops shut at 3 am, {d} at 10 am\n", .{ t.after_day_one, t.after_day_three, t.shut_at_night, t.shut_by_day });
    try std.testing.expect(!t.failed);
    try std.testing.expect(t.at_work);
    try std.testing.expect(t.shut_by_day < t.shut_at_night);
    try std.testing.expectEqual(t.after_day_one, t.after_day_three);
}
