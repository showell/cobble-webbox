//! **A BLANK FAT16 VOLUME**, laid out as `mkfs.fat -F 16` lays one out, for
//! a library that keeps its files with Cobblestone's Fat16 foreword: the
//! host's disk, before Codex has written to it. 16 MiB, no partition table
//! (the foreword's boot-volume probe mounts a raw FAT image from sector 0):
//!
//!   sector 0          the boot sector and its BPB
//!   sectors 1-33      FAT 1, and 34-66 FAT 2 (16-bit entries)
//!   sectors 67-98     the root directory, 512 entries
//!   sectors 99-       the data area, 4 sectors a cluster (8,167 clusters)
//!
//! Only these first 99 sectors are written; the rest of the image is zeros,
//! sparse on a filesystem that keeps it so.

const std = @import("std");
const Io = std.Io;

pub const sector_bytes = 512;
pub const sectors: u32 = 32768;
pub const image_bytes: u64 = @as(u64, sectors) * sector_bytes;

const sectors_per_cluster = 4;
const reserved = 1;
const fats = 2;
const root_entries = 512;
const sectors_per_fat = 33;

/// The first sectors of the volume, everything that is not zero.
pub const head_sectors = reserved + fats * sectors_per_fat + root_entries * 32 / sector_bytes;

/// The volume's non-zero head (`head_sectors` sectors), into `out`.
pub fn head(out: *[head_sectors * sector_bytes]u8) void {
    @memset(out, 0);
    const b = out[0..sector_bytes];
    b[0..3].* = .{ 0xEB, 0x3C, 0x90 };
    b[3..11].* = "CODEXWBX".*;
    std.mem.writeInt(u16, b[11..13], sector_bytes, .little);
    b[13] = sectors_per_cluster;
    std.mem.writeInt(u16, b[14..16], reserved, .little);
    b[16] = fats;
    std.mem.writeInt(u16, b[17..19], root_entries, .little);
    std.mem.writeInt(u16, b[19..21], @intCast(sectors), .little);
    b[21] = 0xF8;
    std.mem.writeInt(u16, b[22..24], sectors_per_fat, .little);
    std.mem.writeInt(u16, b[24..26], 63, .little);
    std.mem.writeInt(u16, b[26..28], 255, .little);
    b[36] = 0x80;
    b[38] = 0x29;
    std.mem.writeInt(u32, b[39..43], 0xC0DE_C0DE, .little);
    // No label: a label here would want its twin entry in the root
    // directory, and fsck.fat removes one that has none.
    b[43..54].* = "NO NAME    ".*;
    b[54..62].* = "FAT16   ".*;
    b[510] = 0x55;
    b[511] = 0xAA;
    // Each FAT's first two entries: the media byte, and end of chain.
    for (0..fats) |f| {
        const at = (reserved + f * sectors_per_fat) * sector_bytes;
        std.mem.writeInt(u16, out[at..][0..2], 0xFFF8, .little);
        std.mem.writeInt(u16, out[at + 2 ..][0..2], 0xFFFF, .little);
    }
}

/// A blank volume at `path`, made new; refused if a file is there.
pub fn create(io: Io, path: []const u8) !void {
    const file = try Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    var h: [head_sectors * sector_bytes]u8 = undefined;
    head(&h);
    try file.writePositionalAll(io, &h, 0);
    try file.setLength(io, image_bytes);
    try file.sync(io);
}

test "the head is a FAT16 boot sector and two FATs, and nothing else is written" {
    var h: [head_sectors * sector_bytes]u8 = undefined;
    head(&h);
    try std.testing.expectEqual(@as(u16, 512), std.mem.readInt(u16, h[11..13], .little));
    try std.testing.expectEqualStrings("FAT16   ", h[54..62]);
    try std.testing.expectEqual(@as(u8, 0xAA), h[511]);
    try std.testing.expectEqual(@as(u16, 0xFFF8), std.mem.readInt(u16, h[512..514], .little));
    try std.testing.expectEqual(@as(u16, 0xFFF8), std.mem.readInt(u16, h[(1 + 33) * 512 ..][0..2], .little));
    try std.testing.expectEqual(@as(usize, 99), head_sectors);
}
