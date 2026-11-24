const std = @import("std");
const models = @import("src/model/models.zig");
const assert = std.debug.assert;

/// The development tools in tools/, each built from tools/<name>.zig.
const tool_names = [_][]const u8{
    "panelshot",
    "touchsim",
    "e2e",
    "fbcap",
    "fbrec",
    "xtap",
};

/// The tools in tools/ that run on this computer, each built from tools/<name>.zig.
const host_tool_names = [_][]const u8{
    "build_dictionary",
    "pgm2png",
    "package",
    "kindles",
    "strip",
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
    noface: Noface,
    launcher: *std.Build.Step.Compile,
    jxr: *std.Build.Step.Compile,
};

/// The app, built once with its symbols and lines, and stripped of them for the Kindle:
/// the same code at the same addresses, so the addresses a crash logs (main.zig
/// `panic`) are read in `symbols` (docs/DEVELOPING.md).
const Noface = struct { app: std.Build.LazyPath, symbols: std.Build.LazyPath };

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

    // A name of no Kindle is refused here, the names it could be listed
    const chosen = b.option(
        Layout,
        "layout",
        "The Kindle to lay the interface out for, and run on (device.Model)",
    ) orelse default_layout;
    layout_model = @tagName(chosen);
    // The app, with Zig's own bounds and overflow checks on: they cost page turns
    // nothing measurable. `-Dfast=true` builds without them.
    const fast = b.option(
        bool,
        "fast",
        "Build the app without Zig's runtime safety checks",
    ) orelse false;
    // The computer's tools, each built once whatever asks for it
    const host = HostTools.init(b);
    const app = build_app(b, &host, target, fast);
    const check = build_checks(b);
    const tools = build_tools(b, target);
    const host_tools = build_host_tools(b, &host);
    build_package(b, &host, target, app.jxr);
    const scenarios = build_scenarios(b, target);
    const tests = build_tests(b, &host);
    build_clean(b);
    const layouts = build_layouts(b, target);
    // The computer's tools built whole too: their tests alone compile only what they reach,
    // so a broken `main` would first show at a release's `zig build package`
    const gates = .{ b.getInstallStep(), check, tools, host_tools, scenarios, tests, layouts };
    build_gates(b, &gates);
}

/// The Kindle the interface is laid out for (src/model/device.zig `target`), set once
/// from `-Dlayout` as the build starts: the Paperwhite noface runs on, unless asked.
const default_layout: Layout = .paperwhite_12;
var layout_model: []const u8 = @tagName(default_layout);

/// Every Kindle noface knows, the app's own declaration of them (src/model/models.zig):
/// `zig build layouts` lays the interface out for each but the one built.
const Layout = models.Model;
const all_layouts = std.meta.fieldNames(Layout);

/// The Kindles a release carries a zip for: each only once `e2e all` has passed on a
/// real one (docs/DEVELOPING.md, "Which Kindles"). A layout that merely builds
/// (`zig build layouts`) isn't shipped.
const shipped = [_]Layout{.paperwhite_12};

comptime {
    for (shipped, 0..) |model, index| {
        for (shipped[index + 1 ..]) |other| assert(model != other); // One zip each
    }
}

/// The fields of Unicode's tables noface asks of uucode, its one dependency (pinned in
/// build.zig.zon), which src/text/unicode.zig alone imports: only these are built in.
const unicode_fields = [_][]const u8{
    "general_category",
    "bidi_class",
    "case_folding_simple",
    "simple_lowercase_mapping",
    "simple_uppercase_mapping",
    "is_default_ignorable",
    "decomposition_type",
    "decomposition_mapping",
    "script",
};

/// Gives `module`, rooted in src/, what src/ imports by name: the layout option
/// src/model/device.zig reads (which Kindle's screen the interface is laid out for),
/// and uucode, Unicode's tables, built for the module's target.
fn src_imports(b: *std.Build, module: *std.Build.Module, model: []const u8) void {
    assert(model.len > 0);
    const uucode = b.dependency("uucode", .{
        .target = module.resolved_target.?,
        .optimize = module.optimize orelse .debug,
        .fields = @as([]const []const u8, &unicode_fields),
    });
    module.addImport("uucode", uucode.module("uucode"));
    const options = b.addOptions();
    options.addOption([]const u8, "model", model);
    module.addOptions("layout", options);
    assert(module.import_table.get("layout") != null);
    assert(module.import_table.get("uucode") != null);
}

/// `zig build layouts`: the whole interface laid out for every other Kindle's screen,
/// built, with the unit tests and the scenarios run on each (where this computer runs
/// scenarios), so none holds only on the Kindle built for.
/// Every layout checks itself as it's built (nothing overlaps,
/// nothing runs off the screen, every control takes a fingertip, every named place is
/// a tap on its control: screens/places.zig), so a build that passes is a layout
/// that fits that Kindle.
fn build_layouts(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    assert(target.result.cpu.arch == .arm); // For a Kindle, like the app
    assert(all_layouts.len > 1);
    const layouts_step = b.step("layouts", "Lay out and test for every other Kindle's screen");
    for (all_layouts) |model| {
        if (std.mem.eql(u8, model, layout_model)) continue; // Built and tested already
        const module = b.createModule(.{
            .root_source_file = b.path("src/layouts.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .strip = true,
            .link_libc = true,
        });
        src_imports(b, module, model);
        const laid_out = b.addExecutable(.{
            .name = b.fmt("noface-{s}", .{model}),
            .root_module = module,
        });
        layouts_step.dependOn(&laid_out.step);
        layouts_step.dependOn(&b.addRunArtifact(unit_tests(b, b.graph.host, model)).step);
        const name = b.fmt("noface-scenarios-{s}", .{model});
        if (host_scenarios(b, name, model)) |run| layouts_step.dependOn(&run.step);
    }
    // Built and tested for every Kindle but the one built, which must be one of them
    assert(layouts_step.dependencies.items.len >= 2 * (all_layouts.len - 1));
    assert(layouts_step.dependencies.items.len <= 3 * (all_layouts.len - 1));
    return layouts_step;
}

/// `zig build gates`: every check a change passes before it's committed, the app and
/// the tools built, the checks, the unit tests and the scenarios, as one step whose exit
/// status alone says whether all passed: nothing is read off what they print.
fn build_gates(b: *std.Build, gates: []const *std.Build.Step) void {
    assert(gates.len > 0);
    const gates_step = b.step("gates", "Build everything and run every check and test");
    for (gates) |gate| gates_step.dependOn(gate);
    assert(gates_step.dependencies.items.len == gates.len);
}

/// `zig build clean`: empties the build cache. Zig keeps every version of everything
/// it has built there and never gives one up, so it grows by gigabytes as the code
/// changes; all of it is built again as it's next needed.
fn build_clean(b: *std.Build) void {
    const remove = b.addSystemCommand(&.{ "rm", "-rf" });
    // Zig's own idea of where its cache is, so nothing else can be named here
    remove.addDirectoryArg(.cache_root);
    remove.has_side_effects = true; // Runs every time it's asked for
    const clean_step = b.step("clean", "Empty the build cache, which grows with every change");
    clean_step.dependOn(&remove.step);
    assert(clean_step.dependencies.items.len == 1);
    assert(remove.argv.items.len == 3); // rm, its flags and the cache
}

/// The app, its launcher, and the picture helper it runs.
fn build_app(
    b: *std.Build,
    host: *const HostTools,
    target: std.Build.ResolvedTarget,
    fast: bool,
) App {
    assert(target.result.os.tag == .linux);
    assert(target.result.abi == .musleabihf); // Static: it runs on any Kindle
    const app = App{
        .noface = noface_for(b, host, target, layout_model, fast),
        .launcher = launcher_for(b, target, layout_model),
        .jxr = jxr_helper(b),
    };
    b.getInstallStep().dependOn(&b.addInstallBinFile(app.noface.app, "noface").step);
    // Beside it, the same build with its symbols, to read a crash of this one in
    const symbols = b.addInstallBinFile(app.noface.symbols, "noface-symbols");
    b.getInstallStep().dependOn(&symbols.step);
    b.installArtifact(app.launcher);
    b.installArtifact(app.jxr);
    return app;
}

/// The app laid out for `model`'s screen, with Zig's runtime safety checks unless
/// asked to be `fast`.
fn noface_for(
    b: *std.Build,
    host: *const HostTools,
    target: std.Build.ResolvedTarget,
    model: []const u8,
    fast: bool,
) Noface {
    assert(model.len > 0);
    const noface = b.addExecutable(.{
        .name = "noface",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = if (fast) .ReleaseFast else .ReleaseSafe,
            .strip = false, // A copy is stripped below, so the symbols match its code
            .link_libc = true,
            // So a crash can walk back through the calls that led to it
            .omit_frame_pointer = false,
        }),
    });
    src_imports(b, noface.root_module, model);
    // An ID of this very build, which a crash logs and its symbols carry too, so a
    // crash is never read against another build's symbols (sys/crash.zig)
    noface.build_id = .fast;
    assert(noface.root_module.link_libc.?); // Asked for, as set above
    const strip = b.addRunArtifact(host.tool("strip"));
    strip.addFileArg(noface.getEmittedBin());
    const stripped = strip.addOutputFileArg("noface");
    assert(strip.argv.items.len == 3); // The tool, the program, the copy
    return .{ .app = stripped, .symbols = noface.getEmittedBin() };
}

/// The launcher, for `model`: starts the app and always puts the Kindle's own screens
/// back. Small, and apart from the app, so nothing the app does can take it down.
fn launcher_for(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    model: []const u8,
) *std.Build.Step.Compile {
    assert(model.len > 0);
    const launcher = b.addExecutable(.{
        .name = "noface-launch",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/launch.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .strip = true,
        }),
    });
    src_imports(b, launcher.root_module, model);
    // Static, and needing nothing but Linux: libc not asked for (unset is not linked)
    assert(!(launcher.root_module.link_libc orelse false));
    return launcher;
}

/// The picture helper, the same for every Kindle.
fn jxr_helper(b: *std.Build) *std.Build.Step.Compile {
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
    assert(jxr.root_module.link_libc.?); // The Kindle's glibc, as set above
    assert(jxr.root_module.resolved_target.?.result.abi == .gnueabihf);
    return jxr;
}

/// Tools that run on this computer: the dictionary builder, the snapshot converter, the
/// packer, the release's table and the stripper. Built into zig-out/bin with
/// `zig build host-tools`.
fn build_host_tools(b: *std.Build, host: *const HostTools) *std.Build.Step {
    assert(host_tool_names.len > 0);
    const host_tools_step = b.step("host-tools", "Build the tools that run on this computer");
    for (host.tools) |tool| host_tools_step.dependOn(&b.addInstallArtifact(tool, .{}).step);
    assert(host_tools_step.dependencies.items.len == host_tool_names.len);
    return host_tools_step;
}

/// The tools that run on this computer, each compiled once with src/ to hand as `core`,
/// itself made once: the dictionary builder folds words as the app's search does, and
/// the release's table names the Kindles (the same on any layout, so the one built).
const HostTools = struct {
    tools: [host_tool_names.len]*std.Build.Step.Compile,

    fn init(b: *std.Build) HostTools {
        const core = b.createModule(.{
            .root_source_file = b.path("src/core.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        });
        src_imports(b, core, layout_model);
        var host: HostTools = undefined;
        for (&host.tools, host_tool_names) |*made, name| {
            made.* = b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
                    .target = b.graph.host,
                    .optimize = .ReleaseSafe,
                    .imports = &.{.{ .name = "core", .module = core }},
                }),
            });
        }
        return host;
    }

    /// The tool `name` names: one of `host_tool_names`, or the build stops.
    fn tool(host: *const HostTools, comptime name: []const u8) *std.Build.Step.Compile {
        inline for (host_tool_names, 0..) |known, index| {
            if (comptime std.mem.eql(u8, known, name)) return host.tools[index];
        }
        @compileError("no host tool is named " ++ name);
    }
};

/// `zig build package -Dversion=1.2.3`: everything built, then packed for each shipped
/// Kindle as zig-out/noface-1.2.3-<model>.zip (see tools/package.zig), the zips a
/// release carries, with zig-out/KINDLES.md, the table of them its notes open with
/// (tools/kindles.zig), and zig-out/noface-1.2.3-<model>-symbols: the same app with its
/// symbols and lines kept, to read a crash's addresses in (docs/DEVELOPING.md). The app
/// and launcher are laid out for each Kindle, always with runtime safety checks (Zig's
/// cache reuses what `zig build` made alike).
fn build_package(
    b: *std.Build,
    host: *const HostTools,
    target: std.Build.ResolvedTarget,
    jxr: *std.Build.Step.Compile,
) void {
    const version_help = "The version a package is for, like 1.2.3";
    const version = b.option([]const u8, "version", version_help) orelse "dev";
    assert(version.len > 0);
    const package_step = b.step(
        "package",
        "Pack the app as zig-out/noface-<version>-<model>.zip for each shipped Kindle",
    );
    const table = b.addRunArtifact(host.tool("kindles"));
    const table_file = table.addOutputFileArg("KINDLES.md");
    table.addArg(version);
    for (shipped) |layout| {
        const model = @tagName(layout);
        const laid_out: App = .{
            .noface = noface_for(b, host, target, model, false),
            .launcher = launcher_for(b, target, model),
            .jxr = jxr,
        };
        const zip_name = b.fmt("noface-{s}-{s}.zip", .{ version, model });
        const version_for = b.fmt("{s} for {s}", .{ version, model });
        const zip = pack_for(b, host, laid_out, zip_name, version_for);
        package_step.dependOn(&b.addInstallFile(zip, zip_name).step);
        const symbols_name = b.fmt("noface-{s}-{s}-symbols", .{ version, model });
        package_step.dependOn(&b.addInstallFile(laid_out.noface.symbols, symbols_name).step);
        table.addArg(model);
    }
    package_step.dependOn(&b.addInstallFile(table_file, "KINDLES.md").step);
    assert(package_step.dependencies.items.len == 2 * shipped.len + 1);
}

/// `app` packed as `zip_name`, its VERSION file saying `version`.
fn pack_for(
    b: *std.Build,
    host: *const HostTools,
    app: App,
    zip_name: []const u8,
    version: []const u8,
) std.Build.LazyPath {
    assert(std.mem.endsWith(u8, zip_name, ".zip"));
    const pack = b.addRunArtifact(host.tool("package"));
    const zip = pack.addOutputFileArg(zip_name);
    pack.addArg(version);
    const executable = "755";
    const plain = "644";
    pack_file(pack, executable, "noface/noface", app.noface.app);
    pack_file(pack, executable, "noface/noface-launch", app.launcher.getEmittedBin());
    pack_file(pack, executable, "noface/jxr2pgm", app.jxr.getEmittedBin());
    pack_file(pack, plain, "noface/noface-autostart.conf", b.path("device/noface-autostart.conf"));
    pack_file(pack, executable, "noface/kpm/noface/launch.sh", b.path("device/kpm/launch.sh"));
    pack_file(pack, plain, "noface/LICENSE.md", b.path("LICENSE.md"));
    pack_file(pack, plain, "noface/THIRD_PARTY_NOTICES.md", b.path("THIRD_PARTY_NOTICES.md"));
    assert(pack.argv.items.len > 2);
    return zip;
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

/// `zig build check`: ownership boundaries, Tiger Style and zig fmt.
fn build_checks(b: *std.Build) *std.Build.Step {
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

    // Tiger Style (docs/TIGER_STYLE.md): `zig build check` fails on any break of a rule
    // anywhere, short of an exception marked in the code with its reason.
    const style_module = b.createModule(.{
        .root_source_file = b.path("tools/check/style.zig"),
        .target = host,
    });
    const style = b.addExecutable(.{ .name = "style", .root_module = style_module });
    const run_style = b.addRunArtifact(style);
    run_style.addArg(".");
    run_style.has_side_effects = true; // Reads the sources itself, so always runs
    check_step.dependOn(&run_style.step);
    const style_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/check/style.zig"),
        .target = host,
    }) });
    check_step.dependOn(&b.addRunArtifact(style_tests).step);
    // Formatting, as Tiger Style asks: the code is formatted as zig fmt has it
    const fmt = b.addFmt(.{
        .paths = &.{ b.path("src"), b.path("tools"), b.path("build.zig") },
        .check = true,
    });
    check_step.dependOn(&fmt.step);
    // The tests compile for CI's Linux and the Kindle's too, not only this computer:
    // code only Linux builds (system calls by architecture) is checked before a push
    const linux_targets = [_]std.Target.Query{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .arm, .os_tag = .linux, .abi = .musleabihf },
    };
    for (linux_targets) |query| {
        check_step.dependOn(&unit_tests(b, b.resolveTargetQuery(query), layout_model).step);
    }
    assert(run_style.has_side_effects); // Never skipped as cached
    return check_step;
}

/// Development tools, kept out of the app. Built with `zig build tools`.
fn build_tools(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    assert(target.result.cpu.arch == .arm); // For the Kindle, like the app
    assert(tool_names.len > 0);
    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    src_imports(b, core, layout_model);

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
    return tools_step;
}

/// Scenario tests: the real app played by script on a screen in memory.
/// `zig build scenarios` builds the Kindle copy (zig-out/bin/noface-scenarios) and,
/// on a Linux or Mac computer, builds and runs one there too.
fn build_scenarios(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step {
    assert(target.result.cpu.arch == .arm); // The Kindle copy
    const scenarios_step = b.step(
        "scenarios",
        "Build the scenario tests, and run them on a Linux host",
    );
    const kindle_scenarios = scenario_exe(b, target, "noface-scenarios", layout_model);
    scenarios_step.dependOn(&b.addInstallArtifact(kindle_scenarios, .{}).step);
    // On Linux as 32-bit x86, which a 64-bit Linux runs as is: noface makes Linux's own
    // system calls there, written for the Kindle's 32-bit ARM, and this matches it. On a
    // Mac natively: its system calls go through the C library
    assert(target.result.ptrBitWidth() == 32);
    if (host_scenarios(b, "noface-scenarios-host", layout_model)) |run| {
        scenarios_step.dependOn(&run.step);
        // Installed too, to write reference screens on this computer (DEVELOPING.md)
        scenarios_step.dependOn(&b.addInstallArtifact(run.producer.?, .{}).step);
    }
    const host_os = b.graph.host.result;
    if (host_os.os.tag == .linux and host_os.cpu.arch == .x86_64) {
        // Built too, not run, for this computer's own 64 bits, as a Mac builds it: code
        // that compiles only where a usize is 32 bits fails here as well
        const wide = scenario_exe(b, b.graph.host, "noface-scenarios-64", layout_model);
        scenarios_step.dependOn(&wide.step);
    }
    return scenarios_step;
}

/// `zig build test`: every unit test, listed in src/tests.zig, on this computer.
fn build_tests(b: *std.Build, host: *const HostTools) *std.Build.Step {
    const test_step = b.step("test", "Run unit tests on the host");
    const tests = unit_tests(b, b.graph.host, layout_model);
    test_step.dependOn(&b.addRunArtifact(tests).step);
    // The tools that run on this computer, each with its own tests
    for (host.tools) |tool| {
        const tool_tests = b.addTest(.{ .root_module = tool.root_module });
        test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }
    // The Kindle's tools, built for this computer to run their own tests: only what a
    // test reaches is compiled, so their device code needn't build here
    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = b.graph.host,
        .link_libc = true,
    });
    src_imports(b, core, layout_model);
    for (tool_names) |name| {
        const tool_tests = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tools/{s}.zig", .{name})),
            .target = b.graph.host,
            .link_libc = true,
            .imports = &.{.{ .name = "core", .module = core }},
        }) });
        test_step.dependOn(&b.addRunArtifact(tool_tests).step);
    }
    // Tests run on this computer, through its C library
    assert(tests.root_module.link_libc.?); // Asked for, as set above
    assert(tests.root_module.resolved_target != null);
    return test_step;
}

/// Every unit test, listed in src/tests.zig, built for `target` and laid out for `model`.
fn unit_tests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    model: []const u8,
) *std.Build.Step.Compile {
    assert(model.len > 0);
    const tests = b.addTest(.{
        // Named for the Kindle it's laid out for, so a failure says which
        .name = b.fmt("test-{s}", .{model}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .link_libc = true,
        }),
    });
    src_imports(b, tests.root_module, model);
    // So src/kindle/paths.zig can check that what starts the launcher names it
    tests.root_module.addAnonymousImport("launch_sh", .{
        .root_source_file = b.path("device/kpm/launch.sh"),
    });
    tests.root_module.addAnonymousImport("autostart_conf", .{
        .root_source_file = b.path("device/noface-autostart.conf"),
    });
    assert(tests.root_module.link_libc.?); // Asked for, as set above
    return tests;
}

fn scenario_exe(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    model: []const u8,
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
    src_imports(b, exe.root_module, model);
    return exe;
}

/// The scenarios laid out for `model`, run on this computer, where it can run them:
/// natively on a Mac, as 32-bit x86 on a 64-bit Linux, as a Kindle's system calls
/// need. Null on any other computer.
fn host_scenarios(b: *std.Build, name: []const u8, model: []const u8) ?*std.Build.Step.Run {
    assert(name.len > 0);
    assert(model.len > 0);
    const host_os = b.graph.host.result;
    if (host_os.os.tag == .linux and host_os.cpu.arch == .x86_64) {
        const x86 = b.resolveTargetQuery(.{ .cpu_arch = .x86, .os_tag = .linux, .abi = .musl });
        assert(x86.result.ptrBitWidth() == 32);
        return b.addRunArtifact(scenario_exe(b, x86, name, model));
    }
    if (host_os.os.tag == .macos) {
        return b.addRunArtifact(scenario_exe(b, b.graph.host, name, model));
    }
    return null;
}
