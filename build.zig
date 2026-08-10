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

    // b.option panics if an option is declared twice, so anything shared by
    // the bench and difftest wiring is resolved exactly once, here.
    const roaring_zig = roaringZigRoot(b);
    const c_flags = croaringFlags(b, target);
    addBench(b, target, optimize, roaring_zig, c_flags);
    addDifftest(b, target, optimize, roaring_zig, c_flags);
}

/// Wires up `zig build difftest`: identical op streams through zroar and
/// roaring64, exit 0 only if they never disagree.
fn addDifftest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    roaring_zig: []const u8,
    c_flags: []const []const u8,
) void {
    // Debug is ~18s (keys-node insertion under scattered streams); ReleaseSafe
    // keeps every safety check and runs in ~2s, so it's the default.
    const diff_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseSafe else optimize;

    const croaring_include: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ roaring_zig, "croaring" }),
    };
    const croaring_source: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ roaring_zig, "croaring", "roaring.c" }),
    };
    const roaring64_source: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ roaring_zig, "src", "roaring64.zig" }),
    };

    const roaring64_mod = b.createModule(.{
        .root_source_file = roaring64_source,
        .target = target,
        .optimize = diff_optimize,
    });
    roaring64_mod.addIncludePath(croaring_include);

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
    exe.root_module.addImport("roaring64", roaring64_mod);
    exe.root_module.addIncludePath(croaring_include);
    exe.root_module.addCSourceFile(.{
        .file = croaring_source,
        .flags = c_flags,
    });
    exe.root_module.link_libc = true;

    const step = b.step(
        "difftest",
        "Run the zroar vs roaring64 differential test",
    );
    step.dependOn(&b.addRunArtifact(exe).step);
}

/// Wires up `zig build bench`, which compares zroar against CRoaring's
/// `roaring64_bitmap_t` through the Zig wrapper in a roaring-zig checkout.
fn addBench(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    roaring_zig: []const u8,
    c_flags: []const []const u8,
) void {
    // Benchmark numbers taken in Debug measure the safety checks, not the code,
    // so the bench defaults to ReleaseFast. An explicit -Doptimize still wins.
    const bench_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseFast else optimize;

    // roaring-zig lives outside this build root and `b.path` refuses to escape
    // it, so every file over there is named by absolute path instead.
    const croaring_include: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ roaring_zig, "croaring" }),
    };
    const croaring_source: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ roaring_zig, "croaring", "roaring.c" }),
    };
    const roaring64_source: std.Build.LazyPath = .{
        .cwd_relative = b.pathJoin(&.{ roaring_zig, "src", "roaring64.zig" }),
    };

    const roaring64_mod = b.createModule(.{
        .root_source_file = roaring64_source,
        .target = target,
        .optimize = bench_optimize,
    });
    roaring64_mod.addIncludePath(croaring_include);

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
    exe.root_module.addImport("roaring64", roaring64_mod);
    // The bench's root module is what compiles CRoaring, so it needs the
    // headers as well as the roaring64 wrapper module that @cImport's them.
    exe.root_module.addIncludePath(croaring_include);
    exe.root_module.addCSourceFile(.{
        .file = croaring_source,
        .flags = c_flags,
    });
    exe.root_module.link_libc = true;

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);

    const step = b.step(
        "bench",
        "Run the zroar vs roaring64 benchmarks (pass a data dir after --)",
    );
    step.dependOn(&run.step);
}

/// Absolute path of the roaring-zig checkout to build against.
fn roaringZigRoot(b: *std.Build) []const u8 {
    const opt = b.option(
        []const u8,
        "roaring-zig",
        "Path to a roaring-zig checkout (default ../roaring-zig)",
    ) orelse "../roaring-zig";
    if (std.fs.path.isAbsolute(opt)) return opt;
    return b.pathResolve(&.{ b.build_root.path orelse ".", opt });
}

/// The AVX512 auto-detect block from roaring-zig/build.zig: CRoaring's AVX512
/// kernels are compiled in only when the target CPU actually has the features.
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
