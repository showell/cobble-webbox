//! A Codex library's heap region from the operating system, for a host that
//! has one (the Linux sites and the tests): page_allocator's pages, backed
//! lazily and zero when first touched, so a large region costs only what
//! the chapter uses. Once per library per process.

const std = @import("std");

pub fn give(comptime lib: type, size: usize) !void {
    const Once = struct {
        var given = false;
    };
    if (Once.given) return;
    // rawAlloc, not alignedAlloc: a Debug build fills an Allocator's memory
    // with 0xAA, and the heap's base must start zero.
    const p = std.heap.page_allocator.rawAlloc(size, .fromByteUnits(4096), @returnAddress()) orelse return error.OutOfMemory;
    lib.cx.heapGive(@alignCast(p[0..size]));
    Once.given = true;
}
