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

    // Idea Forge (apps/ideas): zig build serve-ideas. Its page, as
    // Cobblestone's HTML plug built it once (web/idea-forge.html; README.md
    // says how), is compiled in.
    const ideas_exe = b.addExecutable(.{ .name = "idea-forge", .root_module = b.createModule(.{
        .root_source_file = b.path("src/ideas_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    withIdeaPage(b, ideas_exe.root_module);
    b.installArtifact(ideas_exe);
    const serve_ideas = b.addRunArtifact(ideas_exe);
    serve_ideas.step.dependOn(b.getInstallStep());
    b.step("serve-ideas", "Serve Idea Forge on http://localhost:9105 (IDEAS_PORT)").dependOn(&serve_ideas.step);

    // Codex Chat (apps/chat): zig build serve-chat. Its page, Cobblestone's
    // own build of ChatPage.codex (apps/chat/web/chat.html), is compiled in.
    const chat_exe = b.addExecutable(.{ .name = "codex-chat", .root_module = b.createModule(.{
        .root_source_file = b.path("src/chat_main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    withChatPage(b, chat_exe.root_module);
    b.installArtifact(chat_exe);
    const serve_chat = b.addRunArtifact(chat_exe);
    serve_chat.step.dependOn(b.getInstallStep());
    b.step("serve-chat", "Serve Codex Chat on http://localhost:9106/codex-chat/ (CHAT_PORT), its state in data/codex-chat/ (CHAT_DATA)").dependOn(&serve_chat.step);

    // The sites' own tests, and the libraries answering through the emitted Zig.
    const tests = b.step("test", "The sites' tests, and GameServer.codex's and IdeaWeb.codex's answers through the emitted Zig");
    for ([_][]const u8{ "src/app.zig", "src/games_test.zig", "src/ideas_app.zig", "src/ideas_test.zig", "src/chat_app.zig", "src/chat_test.zig" }) |root| {
        const m = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        });
        if (std.mem.startsWith(u8, root, "src/ideas_")) withIdeaPage(b, m);
        if (std.mem.startsWith(u8, root, "src/chat_")) withChatPage(b, m);
        tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = m })).step);
    }
}

/// The page chat_app.zig serves at `/`, as `@embedFile("chat_page")`.
fn withChatPage(b: *std.Build, m: *std.Build.Module) void {
    m.addAnonymousImport("chat_page", .{ .root_source_file = b.path("web/chat.html") });
}

/// The page ideas_app.zig serves at `/`, as `@embedFile("idea_forge_page")`.
fn withIdeaPage(b: *std.Build, m: *std.Build.Module) void {
    m.addAnonymousImport("idea_forge_page", .{ .root_source_file = b.path("web/idea-forge.html") });
}
