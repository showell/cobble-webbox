//! uoaix's GameVendorReplay.codex, compiled to Zig (src/gen/uo.zig), run
//! the way a webbox host would run it: on the 16 MB stack both hosts give
//! a request, in a heap region the host gives. Its lines must be its
//! `.expected` file's, byte for byte.

const std = @import("std");
const uo = @import("gen/uo.zig").api;

/// zig-metal-unikernel's one stack, and Linux's request threads' default.
const request_stack = 16 * 1024 * 1024;

/// Generous for a proof; the test prints what it used.
const heap_region = 512 * 1024 * 1024;

var printed: std.ArrayList(u8) = .empty;

fn sink(line: []const u8) void {
    printed.appendSlice(std.testing.allocator, line) catch @panic("oom");
    printed.append(std.testing.allocator, '\n') catch @panic("oom");
}

fn runProof() void {
    uo.runProof(sink);
}

test "the vendor proof answers as its expected file, on a request's stack, in a host's region" {
    const region = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), heap_region);
    defer std.heap.page_allocator.free(region);
    @memset(region, 0);
    uo.heapGive(region);
    defer printed.deinit(std.testing.allocator);

    @import("stack.zig").onStack(request_stack, runProof, .{});

    std.debug.print("uo vendor proof: {d} bytes of Codex heap\n", .{uo.heapUsed()});
    try std.testing.expectEqualStrings(@embedFile("uo_expected"), printed.items);
}
