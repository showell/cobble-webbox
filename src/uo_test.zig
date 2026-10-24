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

fn expectProof(comptime lib: type, comptime name: []const u8, expected: []const u8) !void {
    const region = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
    defer std.heap.page_allocator.free(region);
    @memset(region, 0);
    lib.api.heapGive(region);
    printed = .empty;
    defer printed.deinit(std.testing.allocator);

    const Run = struct {
        fn run() void {
            lib.api.runProof(sink);
        }
    };
    @import("stack.zig").onStack(request_stack, Run.run, .{});

    std.debug.print("uo {s}: {d} bytes of Codex heap\n", .{ name, lib.api.heapUsed() });
    try std.testing.expectEqualStrings(expected, printed.items);
}

test "the vendor proof answers as its expected file, on a request's stack, in a host's region" {
    try expectProof(@import("gen/uo.zig"), "vendor proof", @embedFile("uo_expected"));
}

test "the town proof answers as its expected file, on a request's stack, in a host's region" {
    try expectProof(@import("gen/uo_town.zig"), "town proof", @embedFile("uo_town_expected"));
}

const watch = @import("gen/uo_watch.zig").api;

/// What a ticking host keeps: the town built once, then brought forward
/// 30 game seconds at a time (the host's quarter-second tick at 120 game
/// seconds a real one) for three game days.
const Ticked = struct { at_work: bool, after_day_one: i64, after_day_three: i64, failed: bool };

fn tickThreeDays() Ticked {
    const w = watch.new();
    if (watch.problem(w).len > 0) @panic("uo watch: no town");
    const start: i64 = 6 * 3600;
    const day: i64 = 24 * 3600;
    var out: Ticked = .{ .at_work = false, .after_day_one = 0, .after_day_three = 0, .failed = false };
    var s: i64 = start;
    while (s <= start + 3 * day) : (s += 30) {
        if (!watch.tick(w, s)) out.failed = true;
        // Mid-morning of day two, everyone is at their shop, not at the inn.
        if (s == start + day + 4 * 3600) {
            const mark = watch.heapMark();
            out.at_work = std.mem.indexOf(u8, watch.json(w, s), "\"x\":1495") == null;
            watch.heapBack(mark);
        }
        if (s == start + day) out.after_day_one = watch.heapUsed();
    }
    out.after_day_three = watch.heapUsed();
    return out;
}

test "the town watch ticks three game days on a request's stack, its heap flat after the first" {
    const region = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
    defer std.heap.page_allocator.free(region);
    @memset(region, 0);
    watch.heapGive(region);

    const t = @import("stack.zig").onStack(request_stack, tickThreeDays, .{});

    std.debug.print("uo town watch: {d} bytes of Codex heap after a day, {d} after three\n", .{ t.after_day_one, t.after_day_three });
    try std.testing.expect(!t.failed);
    try std.testing.expect(t.at_work);
    try std.testing.expectEqual(t.after_day_one, t.after_day_three);
}
