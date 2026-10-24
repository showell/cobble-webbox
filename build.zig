const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // webbox is two modules: `webbox`, portable, what the site imports; and
    // `webbox_linux`, the Linux host, for a Linux `main` only. `host_io` is
    // the one file the sources take their `Io` from.
    const webbox_dep = b.dependency("webbox", .{ .target = target, .optimize = optimize });
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "webbox", .module = webbox_dep.module("webbox") },
        .{ .name = "host_io", .module = webbox_dep.module("host_io") },
        .{ .name = "webbox_linux", .module = webbox_dep.module("webbox_linux") },
    };

    // The game server, for Cobblestone's pages: zig build serve, from the
    // checkout, beside ../cobblestone-pin.
    const exe = b.addExecutable(.{ .name = "cobble-games", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    b.installArtifact(exe);
    const serve = b.addRunArtifact(exe);
    serve.step.dependOn(b.getInstallStep());
    b.step("serve", "Serve Cobblestone's games on http://localhost:9104 (COBBLE_PORT), pages from ../cobblestone-pin (COBBLESTONE_ROOT)").dependOn(&serve.step);

    // The site's own tests, and GameServer answering through the emitted Zig.
    const tests = b.step("test", "The site's tests and GameServer.codex's answers through the emitted Zig");
    for ([_][]const u8{ "src/app.zig", "src/games_test.zig" }) |root| {
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }) });
        tests.dependOn(&b.addRunArtifact(t).step);
    }
}
