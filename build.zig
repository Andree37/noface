const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });

    // The app, with Zig's own bounds and overflow checks on: they cost page turns
    // nothing measurable. `-Dfast=true` builds without them.
    const fast = b.option(bool, "fast", "Build the app without Zig's runtime safety checks") orelse false;
    const noface = b.addExecutable(.{
        .name = "noface",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = if (fast) .ReleaseFast else .ReleaseSafe,
            .strip = true,
            .link_libc = true,
        }),
    });
    addFontAndImageCode(b, noface.root_module);
    b.installArtifact(noface);

    // The picture helper. Built against the Kindle's own glibc, because it loads the
    // Kindle's JPEG XR decoder at run time, which a static musl program can't.
    const jxr = b.addExecutable(.{
        .name = "jxr2pgm",
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .arm,
                .os_tag = .linux,
                .abi = .gnueabihf,
                .glibc_version = .{ .major = 2, .minor = 35, .patch = 0 },
                .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
            }),
            .optimize = .ReleaseFast,
            .strip = true,
            .link_libc = true,
        }),
    });
    jxr.root_module.addCSourceFile(.{ .file = b.path("device/jxr/jxr2pgm.c"), .flags = &.{"-O2"} });
    b.installArtifact(jxr);

    // Ownership boundaries: `zig build check` fails when a file imports across one.
    const host = b.graph.host;
    const boundaries = b.addExecutable(.{
        .name = "boundaries",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/check/boundaries.zig"), .target = host }),
    });
    const run_boundaries = b.addRunArtifact(boundaries);
    run_boundaries.addArg("src");
    const check_step = b.step("check", "Check that files only import what their folder may use");
    check_step.dependOn(&run_boundaries.step);
    const boundary_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tools/check/boundaries.zig"), .target = host }) });
    check_step.dependOn(&b.addRunArtifact(boundary_tests).step);

    // Tiger Style (docs/TIGER_STYLE.md): `zig build check` fails when a file breaks a
    // rule more than tools/check/style_baseline.txt allows, or less without the
    // baseline being lowered to match. `zig build style-baseline` lowers it.
    const style = b.addExecutable(.{
        .name = "style",
        .root_module = b.createModule(.{ .root_source_file = b.path("tools/check/style.zig"), .target = host }),
    });
    const run_style = b.addRunArtifact(style);
    run_style.addArgs(&.{ ".", "check" });
    run_style.has_side_effects = true; // Reads the sources itself, so always runs
    check_step.dependOn(&run_style.step);
    const style_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tools/check/style.zig"), .target = host }) });
    check_step.dependOn(&b.addRunArtifact(style_tests).step);
    const write_baseline = b.addRunArtifact(style);
    write_baseline.addArgs(&.{ ".", "baseline" });
    write_baseline.has_side_effects = true;
    b.step("style-baseline", "Lower the Tiger Style baseline to what the code breaks now (never raise it)").dependOn(&write_baseline.step);
    // zig fmt, as Tiger Style asks: the code is formatted as the formatter has it
    const fmt = b.addFmt(.{ .paths = &.{ b.path("src"), b.path("tools"), b.path("build.zig") }, .check = true });
    check_step.dependOn(&fmt.step);

    // Development tools, kept out of the app. Built with `zig build tools`.
    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    addFontAndImageCode(b, core);

    const tools_step = b.step("tools", "Build the development tools in tools/");
    for ([_][]const u8{ "latency", "kfxstat", "pagetest", "panelshot", "touchsim", "fbcap", "fbrec", "xtap", "kfxshape" }) |name| {
        const tool = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
                .target = target,
                .optimize = .ReleaseFast,
                .strip = true,
                .link_libc = true,
            }),
        });
        tool.root_module.addImport("core", core);
        tools_step.dependOn(&b.addInstallArtifact(tool, .{}).step);
    }

    // Scenario tests: the real app played by script on a screen in memory.
    // `zig build scenarios` builds the Kindle copy (zig-out/bin/noface-scenarios) and,
    // on a Linux or Mac computer, builds and runs one there too.
    const scenarios_step = b.step("scenarios", "Build the scenario tests, and run them on a Linux host");
    const kindle_scenarios = scenarioExe(b, target, "noface-scenarios");
    scenarios_step.dependOn(&b.addInstallArtifact(kindle_scenarios, .{}).step);
    const host_os = b.graph.host.result;
    if (host_os.os.tag == .linux and host_os.cpu.arch == .x86_64) {
        // As 32-bit x86, which a 64-bit Linux runs as is: on Linux noface makes Linux's
        // own system calls, written for the Kindle's 32-bit ARM, and this matches it
        const x86 = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl });
        const host_scenarios = scenarioExe(b, x86, "noface-scenarios-host");
        scenarios_step.dependOn(&b.addRunArtifact(host_scenarios).step);
    } else if (host_os.os.tag == .macos) {
        // On a Mac, natively: noface's system calls go through the C library there
        const host_scenarios = scenarioExe(b, b.graph.host, "noface-scenarios-host");
        scenarios_step.dependOn(&b.addRunArtifact(host_scenarios).step);
    }

    // The simulator: noface on this computer, shown in a browser
    const sim_step = b.step("sim", "Run noface on this computer, in a browser (-Dbooks=<folder of EPUBs>)");
    const sim_books = b.option([]const u8, "books", "The simulator's books: a folder of EPUBs (the test book if not given)");
    const sim = b.addExecutable(.{
        .name = "noface-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    addFontAndImageCode(b, sim.root_module);
    b.step("sim-build", "Build the simulator without running it").dependOn(&b.addInstallArtifact(sim, .{}).step);
    const run_sim = b.addRunArtifact(sim);
    if (sim_books) |folder| run_sim.addArg(folder);
    sim_step.dependOn(&run_sim.step);

    const test_step = b.step("test", "Run unit tests on the host");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    addFontAndImageCode(b, tests.root_module); // So text measuring can be tested with a real font
    // So src/kindle/paths.zig can check the shell scripts name the same places
    tests.root_module.addAnonymousImport("data_sh", .{ .root_source_file = b.path("device/data.sh") });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn scenarioExe(b: *std.Build, target: std.Build.ResolvedTarget, name: []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/scenarios.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .strip = true,
            .link_libc = true,
        }),
    });
    addFontAndImageCode(b, exe.root_module);
    return exe;
}

fn addFontAndImageCode(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("third_party"));
    module.addCSourceFile(.{ .file = b.path("src/gfx/stb_shim.c"), .flags = &.{"-O2"} });
}
