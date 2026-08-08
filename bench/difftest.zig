//! Differential test: identical operation streams into a zroar `Bitmap` and a
//! CRoaring `roaring64.Bitmap64`.
//!
//! Every individual set/remove/contains result is compared as it happens, the
//! cardinalities every 1k operations, and the full contents every 10k. The
//! first disagreement prints everything needed to reproduce it — seed, index,
//! operation, value and both cardinalities — and exits 1.
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
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("difftest FAILED: " ++ fmt ++ "\n", args);
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
fn runSortedPass(allocator: std.mem.Allocator, stats: *Stats) !void {
    const seed: u64 = 0x5EA1_DA7A;
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
        var z2 = try Bitmap.fromBuffer(allocator, zbuf);
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

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stats = Stats{};

    for (stream_seeds, 0..) |seed, i| {
        const dist: Distribution = if (i % 2 == 0) .clustered else .scattered;
        try runStream(allocator, &stats, seed, dist);
    }
    try runSortedPass(allocator, &stats);

    std.debug.print(
        "difftest OK: {d} ops over {d} streams, {d} cardinality checkpoints, {d} content checkpoints\n",
        .{ stats.ops, stream_seeds.len, stats.card_checks, stats.content_checks },
    );
}
