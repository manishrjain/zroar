// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! Differential test: identical operation streams into a zroar `Bitmap` and a
//! CRoaring `roaring64.Bitmap64`.
//!
//! Every individual set/remove/contains result is compared as it happens, the
//! cardinalities every 1k operations, and the full contents every 10k. On top
//! of the op streams, a bulk-build pass (sorted build, both serialized round
//! trips, random removes) and a set-algebra pass (And/Or/AndNot materialized,
//! in place and as fused cardinalities, plus fastOr and compact) run against
//! CRoaring's equivalents. The first disagreement prints everything needed to
//! reproduce it — seed, index, operation, value and both cardinalities — and
//! exits 1.
//!
//! With no arguments one fixed-seed pass runs (~2s, what `zig build difftest`
//! does). `--soak <seconds>` repeats the whole pass with fresh seeds derived
//! from a printed base until the time is up, reporting progress every
//! `--progress <seconds>` (default 10):
//!
//!     zig build difftest -- --soak 600
//!     zig build difftest -- --soak 3600 --progress 60 --seed 0xC0FFEE
//!
//! Lives under bench/ rather than src/ because it links croaring.

const std = @import("std");
const zroar = @import("zroar");
const roaring64 = @import("roaring64");

const Bitmap = zroar.Bitmap;
const Bitmap64 = roaring64.Bitmap64;

/// Seeds of the random operation streams; even ones run clustered, odd ones
/// scattered. Fixed, so a failure replays exactly.
const stream_seeds = [_]u64{
    0x0000_0001, 0xDEAD_BEEF, 0x5EED_5EED, 0x00C0_FFEE,
    0x1234_5678, 0xFEED_FACE, 0x0BAD_C0DE, 0xA5A5_A5A5,
};

const ops_per_stream: usize = 100_000;
const card_check_every: usize = 1_000;
const content_check_every: usize = 10_000;

/// The counts the summary line reports.
const Stats = struct {
    ops: usize = 0,
    card_checks: usize = 0,
    content_checks: usize = 0,
    rounds: usize = 0,
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("difftest FAILED: " ++ fmt ++ "\n", args);
    if (current_round_seed != 0) std.debug.print(
        "replay with: difftest --seed 0x{X}\n",
        .{current_round_seed},
    );
    std.process.exit(1);
}

/// Booleans as text, so the failure messages need no format-specifier games.
fn yn(b: bool) []const u8 {
    return if (b) "true" else "false";
}

// ---------------------------------------------------------------------------
// Value generators (the same shapes src/prop_test.zig uses)
// ---------------------------------------------------------------------------

const Distribution = enum {
    /// Four 64k-wide regions: containers fill up and cross the array-to-bitmap
    /// conversion on the zroar side.
    clustered,
    /// The whole u64 range: almost every value gets a key of its own.
    /// roaring64 is a 48-bit-keyed structure like zroar, so nothing is capped.
    scattered,
};

/// The four 64k-aligned bases of a clustered run. Two sit below 2^32, one above
/// 2^32 and one above 2^48, so keys of every level are exercised.
fn clusterBases(rnd: std.Random) [4]u64 {
    return .{
        rnd.uintLessThan(u64, 64) << 16,
        rnd.uintLessThan(u64, 1 << 16) << 16,
        (1 << 32) | (rnd.uintLessThan(u64, 1 << 16) << 16),
        (1 << 48) | (rnd.uintLessThan(u64, 1 << 16) << 16),
    };
}

fn nextValue(rnd: std.Random, dist: Distribution, bases: [4]u64) u64 {
    return switch (dist) {
        .clustered => bases[rnd.uintLessThan(usize, bases.len)] | rnd.uintLessThan(u64, 1 << 16),
        .scattered => rnd.int(u64),
    };
}

/// A value to probe or to remove. Half the time it is one that was set at some
/// point, so hits and misses are both common even in the scattered runs.
fn probeValue(rnd: std.Random, dist: Distribution, bases: [4]u64, seen: []const u64) u64 {
    if (seen.len > 0 and rnd.boolean()) return seen[rnd.uintLessThan(usize, seen.len)];
    return nextValue(rnd, dist, bases);
}

// ---------------------------------------------------------------------------
// Comparison
// ---------------------------------------------------------------------------

fn compareCardinality(z: *const Bitmap, r: *const Bitmap64, stage: []const u8, seed: u64, op: usize) void {
    const zc = z.getCardinality();
    const rc = r.cardinality();
    if (zc != rc) fail(
        "{s}: seed 0x{X} op {d}: cardinality zroar={d} roaring64={d}",
        .{ stage, seed, op, zc, rc },
    );
}

/// Compares the two bitmaps value for value, plus cardinality, minimum and
/// maximum. roaring64 leaves min/max undefined on an empty bitmap, so they are
/// only checked when there is something to compare.
fn compareContents(
    allocator: std.mem.Allocator,
    z: *const Bitmap,
    r: *const Bitmap64,
    stage: []const u8,
    seed: u64,
    op: usize,
) !void {
    compareCardinality(z, r, stage, seed, op);

    const zvals = try z.toArray(allocator);
    defer allocator.free(zvals);
    const rvals = try allocator.alloc(u64, zvals.len);
    defer allocator.free(rvals);
    r.toUint64Array(rvals);

    for (zvals, rvals, 0..) |zv, rv, i| {
        if (zv != rv) fail(
            "{s}: seed 0x{X} op {d}: value {d} of {d} differs: zroar={d} roaring64={d}",
            .{ stage, seed, op, i, zvals.len, zv, rv },
        );
    }
    if (zvals.len == 0) return;

    const zmin = z.minimum() orelse fail(
        "{s}: seed 0x{X} op {d}: zroar has no minimum but holds {d} values",
        .{ stage, seed, op, zvals.len },
    );
    const rmin = r.minimum();
    if (zmin != rmin) fail(
        "{s}: seed 0x{X} op {d}: minimum zroar={d} roaring64={d}",
        .{ stage, seed, op, zmin, rmin },
    );

    const zmax = z.maximum() orelse fail(
        "{s}: seed 0x{X} op {d}: zroar has no maximum but holds {d} values",
        .{ stage, seed, op, zvals.len },
    );
    const rmax = r.maximum();
    if (zmax != rmax) fail(
        "{s}: seed 0x{X} op {d}: maximum zroar={d} roaring64={d}",
        .{ stage, seed, op, zmax, rmax },
    );
}

// ---------------------------------------------------------------------------
// The passes
// ---------------------------------------------------------------------------

fn runStream(allocator: std.mem.Allocator, stats: *Stats, seed: u64, dist: Distribution) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const bases = clusterBases(rnd);

    var z = try Bitmap.init(allocator);
    defer z.deinit();
    const r = try Bitmap64.create();
    defer r.free();

    // Every value ever set, duplicates included, so probes can pick one.
    const seen = try allocator.alloc(u64, ops_per_stream);
    defer allocator.free(seen);
    var num_seen: usize = 0;

    var i: usize = 0;
    while (i < ops_per_stream) : (i += 1) {
        const roll = rnd.uintLessThan(u8, 100);
        if (roll < 60) {
            const x = nextValue(rnd, dist, bases);
            const zr = try z.set(x);
            const rr = r.addChecked(x);
            if (zr != rr) fail(
                "seed 0x{X} op {d}: set({d}) zroar={s} roaring64={s} (cardinality zroar={d} roaring64={d})",
                .{ seed, i, x, yn(zr), yn(rr), z.getCardinality(), r.cardinality() },
            );
            seen[num_seen] = x;
            num_seen += 1;
        } else if (roll < 85) {
            const x = probeValue(rnd, dist, bases, seen[0..num_seen]);
            const zr = z.contains(x);
            const rr = r.contains(x);
            if (zr != rr) fail(
                "seed 0x{X} op {d}: contains({d}) zroar={s} roaring64={s} (cardinality zroar={d} roaring64={d})",
                .{ seed, i, x, yn(zr), yn(rr), z.getCardinality(), r.cardinality() },
            );
        } else {
            const x = probeValue(rnd, dist, bases, seen[0..num_seen]);
            const zr = z.remove(x);
            const rr = r.removeChecked(x);
            if (zr != rr) fail(
                "seed 0x{X} op {d}: remove({d}) zroar={s} roaring64={s} (cardinality zroar={d} roaring64={d})",
                .{ seed, i, x, yn(zr), yn(rr), z.getCardinality(), r.cardinality() },
            );
        }
        stats.ops += 1;

        if ((i + 1) % card_check_every == 0) {
            compareCardinality(&z, r, "op stream", seed, i);
            stats.card_checks += 1;
        }
        if ((i + 1) % content_check_every == 0) {
            try compareContents(allocator, &z, r, "op stream", seed, i);
            stats.content_checks += 1;
        }
    }
}

/// A realdata-shaped pass: one sorted list of 100k values spread over sixteen
/// high-32 buckets, built in bulk on both sides, round tripped through both
/// serialized forms, then thinned by 10k random removes.
fn runSortedPass(allocator: std.mem.Allocator, stats: *Stats, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    const n: usize = 100_000;
    const buckets: usize = 16;
    const vals = try allocator.alloc(u64, n);
    defer allocator.free(vals);

    // Bucket i holds a run of u32s, as the realdata files do once widened.
    for (vals, 0..) |*v, i| {
        const bucket: u64 = @intCast(i * buckets / n);
        v.* = (bucket << 32) | rnd.uintLessThan(u64, 1 << 24);
    }
    std.mem.sort(u64, vals, {}, std.sort.asc(u64));

    var z = try Bitmap.fromSortedList(allocator, vals);
    defer z.deinit();
    const r = try Bitmap64.fromSlice(vals);
    defer r.free();

    try compareContents(allocator, &z, r, "sorted build", seed, 0);
    stats.content_checks += 1;

    // Both serialized forms must reopen to the same set.
    {
        const zbuf = try z.toBufferCopy(allocator);
        defer allocator.free(zbuf);
        var z2 = try Bitmap.fromBuffer(allocator, zbuf, .borrow);
        defer z2.deinit();

        const rbuf = try allocator.alloc(u8, r.portableSizeInBytes());
        defer allocator.free(rbuf);
        const written = r.portableSerialize(rbuf);
        if (written != rbuf.len) fail(
            "round trip: portableSerialize wrote {d} of {d} bytes",
            .{ written, rbuf.len },
        );
        const r2 = try Bitmap64.portableDeserializeSafe(rbuf);
        defer r2.free();

        try compareContents(allocator, &z2, r2, "round trip", seed, 0);
        stats.content_checks += 1;
    }

    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const x = vals[rnd.uintLessThan(usize, vals.len)];
        const zr = z.remove(x);
        const rr = r.removeChecked(x);
        if (zr != rr) fail(
            "sorted removes: seed 0x{X} op {d}: remove({d}) zroar={s} roaring64={s} (cardinality zroar={d} roaring64={d})",
            .{ seed, i, x, yn(zr), yn(rr), z.getCardinality(), r.cardinality() },
        );
        stats.ops += 1;

        if ((i + 1) % card_check_every == 0) {
            compareCardinality(&z, r, "sorted removes", seed, i);
            stats.card_checks += 1;
        }
    }

    try compareContents(allocator, &z, r, "after removes", seed, i);
    stats.content_checks += 1;

    // Compacting the emptied containers must not change what zroar holds.
    z.cleanup();
    try compareContents(allocator, &z, r, "after cleanup", seed, i);
    stats.content_checks += 1;
}

/// A pair of equal bitmaps built from one value stream: every value goes into
/// both sides. The stream mixes a dense run (bitmap containers), clustered
/// values (partly shared regions, so keys overlap without being equal) and
/// scattered values (keys the other operand of an algebra op will not have).
fn buildPair(
    allocator: std.mem.Allocator,
    rnd: std.Random,
    bases: [4]u64,
    dense_base: u64,
    dense_stride: u64,
) !struct { z: Bitmap, r: *Bitmap64 } {
    var z = try Bitmap.init(allocator);
    errdefer z.deinit();
    const r = try Bitmap64.create();
    errdefer r.free();

    var v: u64 = dense_base;
    while (v < dense_base + 60_000) : (v += dense_stride) {
        _ = try z.set(v);
        r.add(v);
    }
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        const x = nextValue(rnd, .clustered, bases);
        _ = try z.set(x);
        r.add(x);
    }
    i = 0;
    while (i < 2_000) : (i += 1) {
        const x = rnd.int(u64);
        _ = try z.set(x);
        r.add(x);
    }
    return .{ .z = z, .r = r };
}

/// Set algebra against CRoaring: And/Or/AndNot materialized, the same three
/// as fused cardinalities, And/Or in place, fastOr over three bitmaps, and
/// compact on a result. Operands overlap partly and each holds keys the other
/// lacks, so shared, one-sided and emptied containers all occur.
fn runAlgebraPass(allocator: std.mem.Allocator, stats: *Stats, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const bases = clusterBases(rnd);

    // All three dense runs sit on the same region at strides 1, 3 and 7, so
    // every pair overlaps by construction: a holds the whole region, so
    // a ⊇ b's and c's runs, and b ∩ c is the multiples of 21. The cluster
    // bases are shared by a and b but fresh for c, and every operand's
    // scattered values are its own, so each pair also has keys the other
    // side lacks.
    var a = try buildPair(allocator, rnd, bases, bases[1], 1);
    defer a.z.deinit();
    defer a.r.free();
    var b = try buildPair(allocator, rnd, bases, bases[1], 3);
    defer b.z.deinit();
    defer b.r.free();
    var c = try buildPair(allocator, rnd, clusterBases(rnd), bases[1], 7);
    defer c.z.deinit();
    defer c.r.free();

    // Guard the pass's own strength: ops over disjoint sets would still all
    // agree, while exercising much less.
    for ([_][2]*const Bitmap{
        .{ &a.z, &b.z }, .{ &a.z, &c.z }, .{ &b.z, &c.z },
    }) |pair| {
        if (pair[0].andCardinality(pair[1]) == 0) fail(
            "algebra operands do not overlap (seed 0x{X}); the pass is not testing what it should",
            .{seed},
        );
    }

    try compareContents(allocator, &a.z, a.r, "algebra build", seed, 0);
    stats.content_checks += 1;

    // Materialized results, each against CRoaring's, then the fused
    // cardinality against both.
    {
        var zi = try Bitmap.And(allocator, &a.z, &b.z);
        defer zi.deinit();
        const ri = try a.r._and(b.r);
        defer ri.free();
        try compareContents(allocator, &zi, ri, "And", seed, 0);
        if (a.z.andCardinality(&b.z) != a.r._andCardinality(b.r)) fail(
            "andCardinality: seed 0x{X}: zroar={d} roaring64={d}",
            .{ seed, a.z.andCardinality(&b.z), a.r._andCardinality(b.r) },
        );

        // In place must agree with the materialized result.
        var zc = try a.z.clone();
        defer zc.deinit();
        zc.andInPlace(&b.z);
        try compareContents(allocator, &zc, ri, "andInPlace", seed, 0);
        stats.content_checks += 2;
    }
    {
        var zu = try Bitmap.Or(allocator, &a.z, &b.z);
        defer zu.deinit();
        const ru = try a.r._or(b.r);
        defer ru.free();
        try compareContents(allocator, &zu, ru, "Or", seed, 0);
        if (a.z.orCardinality(&b.z) != a.r._orCardinality(b.r)) fail(
            "orCardinality: seed 0x{X}: zroar={d} roaring64={d}",
            .{ seed, a.z.orCardinality(&b.z), a.r._orCardinality(b.r) },
        );

        var zc = try a.z.clone();
        defer zc.deinit();
        try zc.orInPlace(&b.z);
        try compareContents(allocator, &zc, ru, "orInPlace", seed, 0);

        // Compacting a result must not change what it holds, and the compact
        // buffer must round trip.
        try zu.compact();
        try compareContents(allocator, &zu, ru, "compacted Or", seed, 0);
        const buf = try zu.toBufferCopy(allocator);
        defer allocator.free(buf);
        var zre = try Bitmap.fromBuffer(allocator, buf, .borrow);
        defer zre.deinit();
        try compareContents(allocator, &zre, ru, "reopened Or", seed, 0);
        stats.content_checks += 4;
    }
    {
        const rd = try a.r._andnot(b.r);
        defer rd.free();
        var zc = try a.z.clone();
        defer zc.deinit();
        zc.andNotInPlace(&b.z);
        try compareContents(allocator, &zc, rd, "andNotInPlace", seed, 0);
        if (a.z.andNotCardinality(&b.z) != a.r._andnotCardinality(b.r)) fail(
            "andNotCardinality: seed 0x{X}: zroar={d} roaring64={d}",
            .{ seed, a.z.andNotCardinality(&b.z), a.r._andnotCardinality(b.r) },
        );
        stats.content_checks += 1;
    }
    {
        var zf = try Bitmap.fastOr(allocator, &.{ &a.z, &b.z, &c.z });
        defer zf.deinit();
        const rf = try a.r.copy();
        defer rf.free();
        rf._orInPlace(b.r);
        rf._orInPlace(c.r);
        try compareContents(allocator, &zf, rf, "fastOr", seed, 0);
        stats.content_checks += 1;
    }
}

/// One whole pass: the op streams, the bulk-build pass and the algebra pass,
/// all seeded from `base`.
fn runRound(allocator: std.mem.Allocator, stats: *Stats, base: u64) !void {
    for (stream_seeds, 0..) |seed, i| {
        const dist: Distribution = if (i % 2 == 0) .clustered else .scattered;
        try runStream(allocator, stats, seed ^ base, dist);
    }
    try runSortedPass(allocator, stats, base ^ 0x5EA1_DA7A);
    try runAlgebraPass(allocator, stats, base ^ 0xA19E_B4A5);
    stats.rounds += 1;
}

fn parseArg(args: []const [:0]const u8, i: *usize, name: []const u8) u64 {
    i.* += 1;
    if (i.* >= args.len) fail("{s} needs a value", .{name});
    return std.fmt.parseInt(u64, args[i.*], 0) catch
        fail("{s}: not a number: {s}", .{ name, args[i.*] });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var soak_s: u64 = 0;
    var progress_s: u64 = 10;
    var base_seed: u64 = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.sliceTo(args[i], 0);
        if (std.mem.eql(u8, arg, "--soak")) {
            soak_s = parseArg(args, &i, "--soak");
        } else if (std.mem.eql(u8, arg, "--progress")) {
            progress_s = parseArg(args, &i, "--progress");
        } else if (std.mem.eql(u8, arg, "--seed")) {
            base_seed = parseArg(args, &i, "--seed");
        } else {
            fail("unknown argument {s}; usage: difftest [--soak <sec>] [--progress <sec>] [--seed <n>]", .{arg});
        }
    }

    var stats = Stats{};

    if (soak_s == 0) {
        // The quick pass: fixed seeds, so a failure replays exactly.
        try runRound(allocator, &stats, base_seed);
        std.debug.print(
            "difftest OK: {d} ops over {d} streams, {d} cardinality checkpoints, {d} content checkpoints\n",
            .{ stats.ops, stream_seeds.len, stats.card_checks, stats.content_checks },
        );
        return;
    }

    // Soak: fresh seeds every round until the time is up. Every seed is
    // derived from the base printed here, so any failure replays with
    // `--seed` and patience — the failing round's base is printed too.
    std.debug.print("difftest soak: {d}s, base seed 0x{X}\n", .{ soak_s, base_seed });
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var last_report: u64 = 0;
    while (true) {
        const elapsed_ns: u64 = @intCast(start.untilNow(io).raw.toNanoseconds());
        const elapsed = elapsed_ns / std.time.ns_per_s;
        if (elapsed >= soak_s) break;
        if (elapsed - last_report >= progress_s) {
            last_report = elapsed;
            std.debug.print(
                "  {d}s/{d}s: {d} rounds, {d} ops, {d} cardinality checkpoints, {d} content checkpoints\n",
                .{ elapsed, soak_s, stats.rounds, stats.ops, stats.card_checks, stats.content_checks },
            );
        }
        // splitmix64 step, so round seeds share no obvious structure.
        const round: u64 = @intCast(stats.rounds);
        var x = base_seed +% (round +% 1) *% 0x9E37_79B9_7F4A_7C15;
        x = (x ^ (x >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        x = (x ^ (x >> 27)) *% 0x94D0_49BB_1331_11EB;
        x ^= x >> 31;
        current_round_seed = x; // printed by fail(), so any failure replays
        try runRound(allocator, &stats, x);
    }
    std.debug.print(
        "difftest OK (soak {d}s): {d} rounds, {d} ops, {d} cardinality checkpoints, {d} content checkpoints\n",
        .{ soak_s, stats.rounds, stats.ops, stats.card_checks, stats.content_checks },
    );
}

/// The base seed of the round in flight, printed by `fail` so a soak failure
/// can be replayed directly with `--seed`.
var current_round_seed: u64 = 0;
