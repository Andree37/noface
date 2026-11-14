const std = @import("std");
const assert = std.debug.assert;

/// The development tools in tools/, each built from tools/<name>.zig.
const tool_names = [_][]const u8{
    "latency",
    "kfxstat",
    "pagetest",
    "panelshot",
    "touchsim",
    "fbcap",
    "fbrec",
    "xtap",
    "kfxshape",
};

/// The tools in tools/ that run on this computer, each built from tools/<name>.zig.
const host_tool_names = [_][]const u8{
    "build_dictionary",
    "pgm2png",
    "package",
};

comptime {
    // Each tool is installed under its name, so no two may share one
    const all = tool_names ++ host_tool_names;
    for (all, 0..) |name, index| {
        for (all[index + 1 ..]) |other| assert(!std.mem.eql(u8, name, other));
    }
}

/// What goes on the Kindle, as `zig build` makes it.
const App = struct {
    noface: *std.Build.Step.Compile,
    launcher: *std.Build.Step.Compile,
    jxr: *std.Build.Step.Compile,
};

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });
    // The Kindle: its system calls are written for 32-bit ARM
    assert(target.result.cpu.arch == .arm);
    assert(target.result.ptrBitWidth() == 32);

    const app = build_app(b, target);
    build_checks(b);
    build_tools(b, target);
    build_host_tools(b);
    build_package(b, app);
    build_scenarios(b, target);
    build_sim(b);
    build_tests(b);
}

/// The app, its launcher, and the picture helper it runs.
fn build_app(b: *std.Build, target: std.Build.ResolvedTarget) App {
    assert(target.result.os.tag == .linux);
    assert(target.result.abi == .musleabihf); // Static: it runs on any Kindle
    // The app, with Zig's own bounds and overflow checks on: they cost page turns
    // nothing measurable. `-Dfast=true` builds without them.
    const fast = b.option(
        bool,
        "fast",
        "Build the app without Zig's runtime safety checks",
    ) orelse false;
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
    b.installArtifact(noface);

    // The launcher: starts the app and always puts the Kindle's own screens back.
    // Small, and apart from the app, so nothing the app does can take it down.
    const launcher = b.addExecutable(.{
        .name = "noface-launch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/launch.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .strip = true,
        }),
    });
    b.installArtifact(launcher);

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
    jxr.root_module.addCSourceFile(.{
        .file = b.path("device/jxr/jxr2pgm.c"),
        .flags = &.{"-O2"},
    });
    b.installArtifact(jxr);
    assert(launcher.root_module.link_libc != true); // Static, and needing nothing but Linux
    assert(noface.root_module.link_libc == true);
    return .{ .noface = noface, .launcher = launcher, .jxr = jxr };
}

/// Tools that run on this computer: the dictionary builder, the snapshot converter and
/// the packer. Built into zig-out/bin with `zig build host-tools`.
fn build_host_tools(b: *std.Build) void {
    assert(host_tool_names.len > 0);
    const host_tools_step = b.step("host-tools", "Build the tools that run on this computer");
    for (host_tool_names) |name| {
        const tool = host_tool(b, name);
        host_tools_step.dependOn(&b.addInstallArtifact(tool, .{}).step);
    }
    assert(host_tools_step.dependencies.items.len == host_tool_names.len);
}

fn host_tool(b: *std.Build, name: []const u8) *std.Build.Step.Compile {
    assert(name.len > 0);
    const tool = b.addExecutable(.{
        .name = name,
        .root_module = host_tool_module(b, name),
    });
    assert(tool.root_module.resolved_target != null);
    return tool;
}

/// A host tool's code: the dictionary builder folds words as the app's search does.
fn host_tool_module(b: *std.Build, name: []const u8) *std.Build.Module {
    assert(name.len > 0);
    const module = b.createModule(.{
        .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    module.addImport("search", b.createModule(.{
        .root_source_file = b.path("src/model/search.zig"),
        .target = b.graph.host,
    }));
    assert(module.import_table.count() > 0);
    return module;
}

/// `zig build package -Dversion=1.2.3`: everything built, then packed as
/// zig-out/noface-1.2.3.zip, the zip a release carries (see tools/package.zig).
fn build_package(b: *std.Build, app: App) void {
    const version_help = "The version a package is for, like 1.2.3";
    const version = b.option([]const u8, "version", version_help) orelse "dev";
    assert(version.len > 0);
    const pack = b.addRunArtifact(host_tool(b, "package"));
    const zip_name = b.fmt("noface-{s}.zip", .{version});
    const zip = pack.addOutputFileArg(zip_name);
    pack.addArg(version);
    const executable = "755";
    const plain = "644";
    pack_file(pack, executable, "noface/noface", app.noface.getEmittedBin());
    pack_file(pack, executable, "noface/noface-launch", app.launcher.getEmittedBin());
    pack_file(pack, executable, "noface/jxr2pgm", app.jxr.getEmittedBin());
    pack_file(pack, plain, "noface/noface-autostart.conf", b.path("device/noface-autostart.conf"));
    pack_file(pack, executable, "noface/kpm/noface/launch.sh", b.path("device/kpm/launch.sh"));
    // The same file under the names an older install's KPM entry and startup file run,
    // so an update that copies only the noface folder still starts (device/kpm/launch.sh)
    pack_file(pack, executable, "noface/data.sh", b.path("device/kpm/launch.sh"));
    pack_file(pack, executable, "noface/autostart.sh", b.path("device/kpm/launch.sh"));
    pack_file(pack, plain, "noface/LICENSE.md", b.path("LICENSE.md"));
    pack_file(pack, plain, "noface/THIRD_PARTY_NOTICES.md", b.path("THIRD_PARTY_NOTICES.md"));
    const install_zip = b.addInstallFile(zip, zip_name);
    b.step("package", "Pack the app as zig-out/noface-<version>.zip (-Dversion=1.2.3)")
        .dependOn(&install_zip.step);
    assert(pack.argv.items.len > 2);
}

/// One file for the package: its mode, its path in the zip, and where it comes from.
fn pack_file(
    pack: *std.Build.Step.Run,
    mode: []const u8,
    zip_path: []const u8,
    source: std.Build.LazyPath,
) void {
    assert(mode.len == 3);
    assert(std.mem.startsWith(u8, zip_path, "noface/"));
    pack.addArg(mode);
    pack.addArg(zip_path);
    pack.addFileArg(source);
}

/// `zig build check`: ownership boundaries, Tiger Style and zig fmt. Also
/// `zig build style-baseline`.
fn build_checks(b: *std.Build) void {
    // Ownership boundaries: `zig build check` fails when a file imports across one.
    const host = b.graph.host;
    assert(host.result.ptrBitWidth() >= 32);
    const boundaries_module = b.createModule(.{
        .root_source_file = b.path("tools/check/boundaries.zig"),
        .target = host,
    });
    const boundaries = b.addExecutable(.{ .name = "boundaries", .root_module = boundaries_module });
    const run_boundaries = b.addRunArtifact(boundaries);
    run_boundaries.addArg("src");
    const check_step = b.step("check", "Check that files only import what their folder may use");
    check_step.dependOn(&run_boundaries.step);
    const boundary_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/check/boundaries.zig"),
        .target = host,
    }) });
    check_step.dependOn(&b.addRunArtifact(boundary_tests).step);

    // Tiger Style (docs/TIGER_STYLE.md): `zig build check` fails when a file breaks a
    // rule more than tools/check/style_baseline.txt allows, or less without the
    // baseline being lowered to match. `zig build style-baseline` lowers it.
    const style_module = b.createModule(.{
        .root_source_file = b.path("tools/check/style.zig"),
        .target = host,
    });
    const style = b.addExecutable(.{ .name = "style", .root_module = style_module });
    const run_style = b.addRunArtifact(style);
    run_style.addArgs(&.{ ".", "check" });
    run_style.has_side_effects = true; // Reads the sources itself, so always runs
    check_step.dependOn(&run_style.step);
    const style_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/check/style.zig"),
        .target = host,
    }) });
    check_step.dependOn(&b.addRunArtifact(style_tests).step);
    const write_baseline = b.addRunArtifact(style);
    write_baseline.addArgs(&.{ ".", "baseline" });
    write_baseline.has_side_effects = true;
    b.step(
        "style-baseline",
        "Lower the Tiger Style baseline to what the code breaks now (never raise it)",
    ).dependOn(&write_baseline.step);
    // Formatting, as Tiger Style asks: the code is formatted as zig fmt has it
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("src"), b.path("tools"), b.path("build.zig") },
        .check = true,
    });
    check_step.dependOn(&fmt.step);
    assert(run_style.has_side_effects); // Never skipped as cached
    assert(write_baseline.has_side_effects);
}

/// Development tools, kept out of the app. Built with `zig build tools`.
fn build_tools(b: *std.Build, target: std.Build.ResolvedTarget) void {
    assert(target.result.cpu.arch == .arm); // For the Kindle, like the app
    assert(tool_names.len > 0);
    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });

    const tools_step = b.step("tools", "Build the development tools in tools/");
    for (tool_names) |name| {
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
}

/// Scenario tests: the real app played by script on a screen in memory.
/// `zig build scenarios` builds the Kindle copy (zig-out/bin/noface-scenarios) and,
/// on a Linux or Mac computer, builds and runs one there too.
fn build_scenarios(b: *std.Build, target: std.Build.ResolvedTarget) void {
    assert(target.result.cpu.arch == .arm); // The Kindle copy
    const scenarios_step = b.step(
        "scenarios",
        "Build the scenario tests, and run them on a Linux host",
    );
    const kindle_scenarios = scenario_exe(b, target, "noface-scenarios");
    scenarios_step.dependOn(&b.addInstallArtifact(kindle_scenarios, .{}).step);
    const host_os = b.graph.host.result;
    if (host_os.os.tag == .linux and host_os.cpu.arch == .x86_64) {
        // As 32-bit x86, which a 64-bit Linux runs as is: on Linux noface makes Linux's
        // own system calls, written for the Kindle's 32-bit ARM, and this matches it
        const x86 = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl });
        assert(x86.result.ptrBitWidth() == target.result.ptrBitWidth());
        const host_scenarios = scenario_exe(b, x86, "noface-scenarios-host");
        scenarios_step.dependOn(&b.addRunArtifact(host_scenarios).step);
    } else if (host_os.os.tag == .macos) {
        // On a Mac, natively: noface's system calls go through the C library there
        const host_scenarios = scenario_exe(b, b.graph.host, "noface-scenarios-host");
        scenarios_step.dependOn(&b.addRunArtifact(host_scenarios).step);
    }
}

/// The simulator: noface on this computer, shown in a browser.
fn build_sim(b: *std.Build) void {
    const sim_step = b.step(
        "sim",
        "Run noface on this computer, in a browser (-Dbooks=<folder of EPUBs>)",
    );
    const sim_books = b.option(
        []const u8,
        "books",
        "The simulator's books: a folder of EPUBs (the test book if not given)",
    );
    const sim = b.addExecutable(.{
        .name = "noface-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sim.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
    });
    b.step("sim-build", "Build the simulator without running it")
        .dependOn(&b.addInstallArtifact(sim, .{}).step);
    const run_sim = b.addRunArtifact(sim);
    if (sim_books) |folder| run_sim.addArg(folder);
    sim_step.dependOn(&run_sim.step);
    assert(sim.root_module.link_libc == true); // Its system calls go through the C library
}

/// `zig build test`: every unit test, listed in src/tests.zig, on this computer.
fn build_tests(b: *std.Build) void {
    const test_step = b.step("test", "Run unit tests on the host");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .link_libc = true,
        }),
    });
    // So src/kindle/paths.zig can check that what starts the launcher names it
    tests.root_module.addAnonymousImport("launch_sh", .{
        .root_source_file = b.path("device/kpm/launch.sh"),
    });
    tests.root_module.addAnonymousImport("autostart_conf", .{
        .root_source_file = b.path("device/noface-autostart.conf"),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The tools that run on this computer, each with its own tests
    for (host_tool_names) |name| {
        const tool_tests = b.addTest(.{ .root_module = host_tool_module(b, name) });
        test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }
    assert(tests.root_module.link_libc == true); // Tests run on this computer, through its C library
    assert(tests.root_module.resolved_target != null);
}

fn scenario_exe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
) *std.Build.Step.Compile {
    assert(std.mem.startsWith(u8, name, "noface-scenarios"));
    assert(target.result.os.tag == .linux or target.result.os.tag == .macos);
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
    return exe;
}
