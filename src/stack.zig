//! **THE CHAPTER'S STACK**: emitted Codex recurses as its source does, and
//! the program it came from ran on a 512 MiB stack (the emitter's `main`),
//! not a handler's. Each call into a library runs on a thread with that
//! much, reserved and faulted in only as deep as it goes.

const std = @import("std");

const chapter_stack = 512 * 1024 * 1024;

/// `f(args)` on a thread with the chapter's stack; its answer.
pub fn onBigStack(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    const Call = struct {
        fn run(out: *R, a: @TypeOf(args)) void {
            out.* = @call(.auto, f, a);
        }
    };
    var out: R = undefined;
    const t = std.Thread.spawn(.{ .stack_size = chapter_stack }, Call.run, .{ &out, args }) catch @panic("cobble-webbox: no thread for the chapter's stack");
    t.join();
    return out;
}
