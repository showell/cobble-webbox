//! A uoaix proof's face for a host (src/gen/uo.zig, src/gen/uo_town.zig: the
//! proof built as a library exporting its `opening`): its Console lines to
//! the host's sink, from a fresh heap each run.

pub fn Proof(comptime lib: type) type {
    return struct {
        pub const heapGive = lib.cx.heapGive;
        pub const heapUsed = lib.cx.heapUsed;

        /// The proof, once, from a fresh heap: each line it prints, UTF-8,
        /// to `sink`, valid only during that call.
        pub fn runProof(sink: *const fn ([]const u8) void) void {
            lib.cx.heapReset();
            lib.cx_host_print = sink;
            defer lib.cx_host_print = null;
            lib.opening();
        }
    };
}

pub const vendor = Proof(@import("gen/uo.zig"));
pub const town = Proof(@import("gen/uo_town.zig"));
