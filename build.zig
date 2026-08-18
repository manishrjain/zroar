const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library module, for dependents.
    _ = b.addModule("zroar", .{
        .root_source_file = b.path("src/zroar.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Every test lives in its own `*_test.zig` file, and Zig silently skips the
    // tests in a file nothing references, so src/tests.zig imports all of them
    // and is the single root of the test build.
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    addSearchBench(b, target, optimize);

    // b.option panics if an option is declared twice, so anything shared by
    // the bench and difftest wiring is resolved exactly once, here.
    const croaring = Croaring.resolve(b, target);
    addBench(b, target, optimize, croaring);
    addDifftest(b, target, optimize, croaring);
}

/// The CRoaring checkout the bench and difftest compare against, as
/// `-Dcroaring=<dir>` (default /tmp/CRoaring, which is where
/// bench/fetch_croaring.sh puts it). Resolved once at configure time; a
/// missing checkout is reported from the steps that need it, and only from
/// there — `zig build test` never looks for it.
const Croaring = union(enum) {
    found: Found,
    /// A step that needs CRoaring depends on this and nothing else, so the
    /// message surfaces on `zig build bench` alone, with no compile errors
    /// around it.
    missing: *std.Build.Step.Fail,

    const Found = struct {
        /// From `<root>/include/roaring/roaring_version.h`, for the bench's
        /// report header.
        version: []const u8,
        /// `<root>/include`, which the C sources include from.
        include: std.Build.LazyPath,
        /// `<root>/src`, and every `.c` under it, found by walking the tree
        /// so a checkout of another CRoaring version needs no list kept in
        /// step.
        src_root: std.Build.LazyPath,
        src_files: []const []const u8,
        /// Passed when compiling those files.
        c_flags: []const []const u8,
    };

    fn resolve(b: *std.Build, target: std.Build.ResolvedTarget) Croaring {
        const opt = b.option(
            []const u8,
            "croaring",
            "Path to a CRoaring checkout (default /tmp/CRoaring; see bench/fetch_croaring.sh)",
        ) orelse "/tmp/CRoaring";
        const root = if (std.fs.path.isAbsolute(opt))
            opt
        else
            b.pathResolve(&.{ b.build_root.path orelse ".", opt });

        // Declared whether or not the checkout is there, so the option set
        // does not depend on the state of /tmp.
        const c_flags = croaringFlags(b, target);

        // Files over there are outside the build root, and `b.path` refuses to
        // escape it, so every one is named by absolute path instead.
        const src_dir = b.pathJoin(&.{ root, "src" });
        const src_files = listCSources(b, src_dir) catch |err| {
            return .{ .missing = b.addFail(b.fmt(
                "no usable CRoaring checkout at {s} ({s}): run bench/fetch_croaring.sh, or pass -Dcroaring=<dir>",
                .{ root, @errorName(err) },
            )) };
        };
        return .{ .found = .{
            .version = croaringVersion(b, root) catch "unknown",
            .include = .{ .cwd_relative = b.pathJoin(&.{ root, "include" }) },
            .src_root = .{ .cwd_relative = src_dir },
            .src_files = src_files,
            .c_flags = c_flags,
        } };
    }

    /// Gives `mod` the `roaring64` import (bench/roaring64.zig, which
    /// declares what it calls itself, so it needs no headers), compiles
    /// CRoaring into it, links libc, and passes the CRoaring version along as
    /// the `croaring` options module.
    fn attach(
        self: Found,
        b: *std.Build,
        mod: *std.Build.Module,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    ) void {
        const wrapper = b.createModule(.{
            .root_source_file = b.path("bench/roaring64.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("roaring64", wrapper);

        const info = b.addOptions();
        info.addOption([]const u8, "version", self.version);
        mod.addImport("croaring", info.createModule());

        // CRoaring's sources `#include <roaring/...>` and are compiled as part
        // of the importing module, so it needs the include path.
        mod.addIncludePath(self.include);
        mod.addCSourceFiles(.{
            .root = self.src_root,
            .files = self.src_files,
            .flags = self.c_flags,
        });
        mod.link_libc = true;
    }
};

/// The `ROARING_VERSION` string from the checkout's version header.
fn croaringVersion(b: *std.Build, root: []const u8) ![]const u8 {
    const io = b.graph.io;
    var dir = try std.Io.Dir.openDirAbsolute(io, root, .{});
    defer dir.close(io);
    const text = try dir.readFileAlloc(io, "include/roaring/roaring_version.h", b.allocator, .limited(1 << 16));

    const key = "#define ROARING_VERSION \"";
    const start = (std.mem.indexOf(u8, text, key) orelse return error.NoVersion) + key.len;
    const end = std.mem.indexOfScalarPos(u8, text, start, '"') orelse return error.NoVersion;
    return text[start..end];
}

/// Every `.c` file under `dir`, as paths relative to it, sorted so the build
/// graph is the same from run to run.
fn listCSources(b: *std.Build, dir: []const u8) ![]const []const u8 {
    const io = b.graph.io;
    var d = try std.Io.Dir.openDirAbsolute(io, dir, .{ .iterate = true });
    defer d.close(io);

    var files: std.ArrayListUnmanaged([]const u8) = .empty;
    var walker = try d.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;
        try files.append(b.allocator, b.dupe(entry.path));
    }
    if (files.items.len == 0) return error.NoCSources;
    std.mem.sort([]const u8, files.items, {}, lessThanPath);
    return files.items;
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Wires up `zig build searchbench`: the keys-node and array-container search
/// paths against a plain bisect, under probe streams of varying predictability.
/// Needs neither CRoaring nor a dataset, so it stays independent of the main
/// bench wiring and runs in a couple of seconds.
fn addSearchBench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    // Timings from an unoptimized build would only mislead, so default to
    // ReleaseFast whatever the build's own mode is.
    const bench_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseFast else optimize;

    const exe = b.addExecutable(.{
        .name = "search_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/search_bench.zig"),
            .target = target,
            .optimize = bench_optimize,
            .link_libc = true, // std.heap.c_allocator
        }),
    });

    const step = b.step(
        "searchbench",
        "Benchmark Keys.search and array.find against a plain bisect",
    );
    step.dependOn(&b.addRunArtifact(exe).step);
}

/// Wires up `zig build difftest`: identical op streams through zroar and
/// roaring64, exit 0 only if they never disagree.
fn addDifftest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    croaring: Croaring,
) void {
    // Debug is ~18s (keys-node insertion under scattered streams); ReleaseSafe
    // keeps every safety check and runs in ~2s, so it's the default.
    const diff_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseSafe else optimize;

    const step = b.step(
        "difftest",
        "Run the zroar vs roaring64 differential test",
    );
    const found = switch (croaring) {
        .found => |f| f,
        .missing => |fail| {
            step.dependOn(&fail.step);
            return;
        },
    };

    const zroar_mod = b.createModule(.{
        .root_source_file = b.path("src/zroar.zig"),
        .target = target,
        .optimize = diff_optimize,
    });

    const exe = b.addExecutable(.{
        .name = "difftest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/difftest.zig"),
            .target = target,
            .optimize = diff_optimize,
        }),
    });
    exe.root_module.addImport("zroar", zroar_mod);
    Croaring.attach(found, b, exe.root_module, target, diff_optimize);
    step.dependOn(&b.addRunArtifact(exe).step);
}

/// Wires up `zig build bench`, which compares zroar against CRoaring's
/// `roaring64_bitmap_t`.
fn addBench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    croaring: Croaring,
) void {
    // Benchmark numbers taken in Debug measure the safety checks, not the code,
    // so the bench defaults to ReleaseFast. An explicit -Doptimize still wins.
    const bench_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseFast else optimize;

    const step = b.step(
        "bench",
        "Run the zroar vs roaring64 benchmarks (pass a data dir after --)",
    );
    const found = switch (croaring) {
        .found => |f| f,
        .missing => |fail| {
            step.dependOn(&fail.step);
            return;
        },
    };

    // The library module registered above carries the build's own optimize
    // mode; the bench needs zroar built the same way the bench itself is.
    const zroar_mod = b.createModule(.{
        .root_source_file = b.path("src/zroar.zig"),
        .target = target,
        .optimize = bench_optimize,
    });

    const exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = bench_optimize,
        }),
    });
    exe.root_module.addImport("zroar", zroar_mod);
    Croaring.attach(found, b, exe.root_module, target, bench_optimize);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    step.dependOn(&run.step);
}

/// Mirrors CRoaring's own CMake option: its AVX512 kernels are compiled in
/// only when the target CPU actually has the features.
fn croaringFlags(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) []const []const u8 {
    const disable_avx512 = b.option(
        bool,
        "ROARING_DISABLE_AVX512",
        "Disable AVX512 in CRoaring",
    ) orelse blk: {
        const resolved_target = b.resolveTargetQuery(target.query);
        const cpu_arch = resolved_target.result.cpu.arch;

        // AVX512 is only available on x86_64 architecture
        if (cpu_arch != .x86_64) {
            std.log.info("Non-x86_64 target detected ({s}), disabling " ++
                "AVX512 in CRoaring", .{@tagName(cpu_arch)});
            break :blk true; // disable AVX512
        }

        // For x86_64, check if the CPU supports the required AVX512 features
        const cpu_features = resolved_target.result.cpu.features;
        const Feature = std.Target.x86.Feature;
        const has_avx512f =
            cpu_features.isEnabled(@intFromEnum(Feature.avx512f));
        const has_avx512dq =
            cpu_features.isEnabled(@intFromEnum(Feature.avx512dq));
        const has_avx512bw =
            cpu_features.isEnabled(@intFromEnum(Feature.avx512bw));

        // CRoaring requires multiple AVX512 features, not just AVX512F
        const has_required_avx512 =
            has_avx512f and has_avx512dq and has_avx512bw;

        if (!has_required_avx512) {
            std.log.info("AVX512 features not detected on x86_64 target " ++
                "CPU, disabling AVX512 in CRoaring", .{});
        } else {
            std.log.info("AVX512 features detected on x86_64 target CPU, " ++
                "enabling AVX512 optimizations", .{});
        }

        break :blk !has_required_avx512;
    };

    return if (disable_avx512)
        &[_][]const u8{"-DCROARING_COMPILER_SUPPORTS_AVX512=0"}
    else
        &[_][]const u8{};
}
