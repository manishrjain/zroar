//! Property tests for zroar: long random operation streams and set algebra,
//! both checked against a `std.AutoHashMapUnmanaged(u64, void)` reference
//! model.
//!
//! Every seed is fixed, so a failure reproduces exactly: the test name and the
//! seed printed with it are enough to replay the run.
//!
//! Runs standalone: `zig test src/prop_test.zig`.

const std = @import("std");
const zroar = @import("zroar.zig");
const test_util = @import("test_util.zig");

const Bitmap = zroar.Bitmap;
const testing = std.testing;

// The reference model and the helpers built on it are shared with
// zroar_test.zig.
const RefSet = test_util.RefSet;
const checkInvariants = test_util.checkInvariants;
const bitmapOf = test_util.testBitmap;
const refSetOf = test_util.testRefSet;
const refAnd = test_util.refAnd;
const refAndNot = test_util.refAndNot;
const refOr = test_util.refOr;
const expectFusedCardinalities = test_util.expectFusedCardinalities;

// ---------------------------------------------------------------------------
// Invariants and model comparison
// ---------------------------------------------------------------------------

/// The reference set's values in ascending order. The caller owns the slice.
fn refSorted(ref: *const RefSet) ![]u64 {
    const out = try testing.allocator.alloc(u64, ref.count());
    errdefer testing.allocator.free(out);

    var i: usize = 0;
    var it = ref.keyIterator();
    while (it.next()) |k| : (i += 1) out[i] = k.*;
    std.mem.sort(u64, out, {}, std.sort.asc(u64));
    return out;
}

/// The full checkpoint: the bitmap holds exactly the model's values, reports
/// them in ascending order through both `toArray` and the iterator, agrees on
/// cardinality, minimum and maximum, and still satisfies the layout invariants.
fn expectMatches(ref: *const RefSet, bm: *const Bitmap) !void {
    try testing.expectEqual(@as(u64, ref.count()), bm.getCardinality());
    try testing.expectEqual(ref.count() == 0, bm.isEmpty());

    const want = try refSorted(ref);
    defer testing.allocator.free(want);

    if (want.len == 0) {
        try testing.expectEqual(@as(?u64, null), bm.minimum());
        try testing.expectEqual(@as(?u64, null), bm.maximum());
    } else {
        try testing.expectEqual(@as(?u64, want[0]), bm.minimum());
        try testing.expectEqual(@as(?u64, want[want.len - 1]), bm.maximum());
    }

    const got = try bm.toArray(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u64, want, got);

    // toArray drains the iterator, so this only proves the two stay consistent;
    // `contains` below is the independent check that the values are really
    // there.
    var seen: usize = 0;
    var it = bm.iterator();
    while (it.next()) |v| : (seen += 1) {
        try testing.expectEqual(got[seen], v);
    }
    try testing.expectEqual(got.len, seen);

    for (want) |v| try testing.expect(bm.contains(v));
    try checkInvariants(bm);
}

// ---------------------------------------------------------------------------
// Value generators
// ---------------------------------------------------------------------------

const Distribution = enum {
    /// Values drawn from four 64k-wide regions: containers fill up and cross
    /// the array-to-bitmap conversion.
    clustered,
    /// Values spread over 2^56: almost every value gets a key of its own, so
    /// the keys node grows over and over.
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
        .clustered => bases[rnd.uintLessThan(usize, bases.len)] |
            rnd.uintLessThan(u64, 1 << 16),
        .scattered => rnd.int(u64) >> 8,
    };
}

/// A value to probe or to remove. Half the time it is one that was set at some
/// point, so hits and misses are both common even in the scattered runs.
fn probeValue(
    rnd: std.Random,
    dist: Distribution,
    bases: [4]u64,
    seen: []const u64,
) u64 {
    if (seen.len > 0 and rnd.boolean())
        return seen[rnd.uintLessThan(usize, seen.len)];
    return nextValue(rnd, dist, bases);
}

/// Values from a mix of the distributions: a dense run on key 0 that crosses
/// into a bitmap container, a spread over the four clustered bases, values from
/// a `pool` shared by both operands, and values unique to this bitmap.
fn mixedValues(
    rnd: std.Random,
    bases: [4]u64,
    pool: []const u64,
    out: []u64,
) void {
    for (out) |*v| {
        v.* = switch (rnd.uintLessThan(u8, 8)) {
            0, 1, 2, 3 => rnd.uintLessThan(u64, 1 << 16),
            4 => bases[rnd.uintLessThan(usize, bases.len)] |
                rnd.uintLessThan(u64, 1 << 16),
            5, 6 => pool[rnd.uintLessThan(usize, pool.len)],
            else => rnd.int(u64) >> 8,
        };
    }
}

// ---------------------------------------------------------------------------
// Random operation streams
// ---------------------------------------------------------------------------

/// One checkpoint every this many operations.
const checkpoint_every: usize = 2_000;

/// Runs `ops` random set/contains/remove operations against both the bitmap and
/// the reference model, checkpointing as it goes. At three of the checkpoints
/// the bitmap is serialized and reopened, and the stream carries on mutating
/// the reopened bitmap: two through `fromBuffer`, which borrows the buffer and
/// must copy out the first time it grows, and one through `fromBufferCopy`.
fn runOpStream(seed: u64, dist: Distribution, ops: usize) !void {
    errdefer std.debug.print(
        "\nop stream failed: seed=0x{X} dist={s}\n",
        .{ seed, @tagName(dist) },
    );

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const bases = clusterBases(rnd);

    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();

    var ref = RefSet.empty;
    defer ref.deinit(testing.allocator);

    // Every value ever set, duplicates included, so probes can pick one.
    const seen = try testing.allocator.alloc(u64, ops);
    defer testing.allocator.free(seen);
    var num_seen: usize = 0;

    // Buffers the bitmap borrowed after a mid-stream reopen. They must outlive
    // it, and they stay ours to free whether or not the bitmap copied out.
    var borrowed: [2]?zroar.AlignedU8 = .{ null, null };
    defer {
        for (borrowed) |maybe| {
            if (maybe) |buf| testing.allocator.free(buf);
        }
    }

    var i: usize = 0;
    while (i < ops) : (i += 1) {
        const roll = rnd.uintLessThan(u8, 100);
        if (roll < 60) {
            const x = nextValue(rnd, dist, bases);
            const added = try bm.set(x);
            const gop = try ref.getOrPut(testing.allocator, x);
            try testing.expectEqual(!gop.found_existing, added);
            seen[num_seen] = x;
            num_seen += 1;
        } else if (roll < 85) {
            const x = probeValue(rnd, dist, bases, seen[0..num_seen]);
            try testing.expectEqual(ref.contains(x), bm.contains(x));
        } else {
            const x = probeValue(rnd, dist, bases, seen[0..num_seen]);
            const want = ref.remove(x);
            // Infallible mutators need ownership; a no-op when already owned.
            try bm.ensureOwned();
            try testing.expectEqual(want, bm.remove(x));
        }

        if ((i + 1) % checkpoint_every != 0) continue;
        try expectMatches(&ref, &bm);

        const cp = (i + 1) / checkpoint_every;
        if (cp == 3 or cp == 7) {
            // Reopen borrowing the buffer, then keep mutating it: the first
            // mutation must copy out and leave `buf` alone.
            const buf = try bm.toBufferCopy(testing.allocator);
            const reopened = try Bitmap.fromBuffer(testing.allocator, buf);
            bm.deinit();
            bm = reopened;
            borrowed[if (cp == 3) 0 else 1] = buf;
            try expectMatches(&ref, &bm);
        } else if (cp == 5) {
            const copied = try Bitmap.fromBufferCopy(
                testing.allocator,
                bm.toBuffer(),
            );
            bm.deinit();
            bm = copied;
            try expectMatches(&ref, &bm);
        }
    }
    try expectMatches(&ref, &bm);
}

test "random operation streams agree with a hashmap reference" {
    const seeds = [_]u64{ 0x0000_0001, 0xDEAD_BEEF, 0x5EED_5EED, 0x00C0_FFEE };
    for (seeds) |seed| {
        for ([_]Distribution{ .clustered, .scattered }) |dist| {
            try runOpStream(seed, dist, 20_000);
        }
    }
}

// ---------------------------------------------------------------------------
// Set algebra
// ---------------------------------------------------------------------------

test "fused cardinalities match the materialized operations" {
    const seeds = [_]u64{ 0x0000_CA4D, 0xBEEF_CA4D, 0x0FA5_CA4D };
    for (seeds) |seed| {
        for ([_]Distribution{ .clustered, .scattered }) |dist| {
            errdefer std.debug.print(
                "\nfused cardinality failed: seed=0x{X} dist={s}\n",
                .{ seed, @tagName(dist) },
            );

            var prng = std.Random.DefaultPrng.init(seed);
            const rnd = prng.random();
            const bases = clusterBases(rnd);

            // Both operands draw from one stream, so they overlap heavily in
            // the clustered runs and hardly at all in the scattered ones.
            const av = try testing.allocator.alloc(u64, 4_000);
            defer testing.allocator.free(av);
            const bv = try testing.allocator.alloc(u64, 4_000);
            defer testing.allocator.free(bv);
            for (av) |*v| v.* = nextValue(rnd, dist, bases);
            for (bv) |*v| v.* = nextValue(rnd, dist, bases);
            // A guaranteed overlap even under .scattered, where two independent
            // draws over 2^56 would otherwise almost never meet.
            for (av[0..500], bv[0..500]) |x, *v| v.* = x;

            var a = try bitmapOf(av);
            defer a.deinit();
            var b = try bitmapOf(bv);
            defer b.deinit();

            try expectFusedCardinalities(&a, &b);
            try expectFusedCardinalities(&b, &a);

            // A compacted operand has a different key list but the same values.
            var compacted = try a.clone();
            defer compacted.deinit();
            compacted.andNotInPlace(&b);
            compacted.cleanup();
            try expectFusedCardinalities(&compacted, &b);
            try expectFusedCardinalities(&b, &compacted);
        }
    }
}

/// Builds one pair of bitmaps of mixed density and checks every set operation
/// against reference sets, including that `cleanup` preserves the contents and
/// that the two-operand forms leave their operands alone.
fn checkAlgebra(seed: u64, n: usize) !void {
    errdefer std.debug.print("\nset algebra failed: seed=0x{X}\n", .{seed});

    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();
    const bases = clusterBases(rnd);

    // A pool both operands draw from, so they also overlap on the sparse keys
    // that hold a single value.
    const pool = try testing.allocator.alloc(u64, 2_000);
    defer testing.allocator.free(pool);
    for (pool) |*v| v.* = rnd.int(u64) >> 8;

    const av = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(av);
    const bv = try testing.allocator.alloc(u64, n);
    defer testing.allocator.free(bv);
    mixedValues(rnd, bases, pool, av);
    mixedValues(rnd, bases, pool, bv);

    var a = try bitmapOf(av);
    defer a.deinit();
    var b = try bitmapOf(bv);
    defer b.deinit();
    var ra = try refSetOf(av);
    defer ra.deinit(testing.allocator);
    var rb = try refSetOf(bv);
    defer rb.deinit(testing.allocator);

    try expectFusedCardinalities(&a, &b);
    try expectFusedCardinalities(&b, &a);

    {
        var want = try refAnd(&ra, &rb);
        defer want.deinit(testing.allocator);

        var in_place = try a.clone();
        defer in_place.deinit();
        in_place.andInPlace(&b);
        try expectMatches(&want, &in_place);

        // Compacting the emptied containers must not change the contents.
        in_place.cleanup();
        try expectMatches(&want, &in_place);

        var two_op = try Bitmap.And(testing.allocator, &a, &b);
        defer two_op.deinit();
        try expectMatches(&want, &two_op);
    }

    {
        var want = try refAndNot(&ra, &rb);
        defer want.deinit(testing.allocator);

        var in_place = try a.clone();
        defer in_place.deinit();
        in_place.andNotInPlace(&b);
        try expectMatches(&want, &in_place);

        in_place.cleanup();
        try expectMatches(&want, &in_place);
    }

    {
        var want = try refOr(&ra, &rb);
        defer want.deinit(testing.allocator);

        var in_place = try a.clone();
        defer in_place.deinit();
        try in_place.orInPlace(&b);
        try expectMatches(&want, &in_place);

        in_place.cleanup();
        try expectMatches(&want, &in_place);

        // Union the other way round: same set.
        var flipped = try b.clone();
        defer flipped.deinit();
        try flipped.orInPlace(&a);
        try expectMatches(&want, &flipped);

        var two_op = try Bitmap.Or(testing.allocator, &a, &b);
        defer two_op.deinit();
        try expectMatches(&want, &two_op);
    }

    // Nothing above was allowed to touch the operands.
    try expectMatches(&ra, &a);
    try expectMatches(&rb, &b);
}

test "set algebra agrees with reference sets" {
    const seeds = [_]u64{
        0x000A_11CE,
        0x0000_0B0B,
        0x1234_5678,
        0xFEED_FACE,
        0x0000_9999,
        0x0000_0002,
    };
    for (seeds) |seed| try checkAlgebra(seed, 5_000);
}

test "fastOr over many bitmaps matches folded orInPlace and a reference union" {
    var prng = std.Random.DefaultPrng.init(0x00FA_570F);
    const rnd = prng.random();
    const bases = clusterBases(rnd);

    const pool = try testing.allocator.alloc(u64, 500);
    defer testing.allocator.free(pool);
    for (pool) |*v| v.* = rnd.int(u64) >> 8;

    const count = 50;
    var bitmaps: [count]Bitmap = undefined;
    var made: usize = 0;
    defer {
        var k: usize = 0;
        while (k < made) : (k += 1) bitmaps[k].deinit();
    }

    var want = RefSet.empty;
    defer want.deinit(testing.allocator);

    var vals: [200]u64 = undefined;
    while (made < count) : (made += 1) {
        mixedValues(rnd, bases, pool, &vals);
        bitmaps[made] = try bitmapOf(&vals);
        for (vals) |v| try want.put(testing.allocator, v, {});
    }

    var ptrs: [count]*const Bitmap = undefined;
    for (&bitmaps, 0..) |*bm, k| ptrs[k] = bm;

    var fast = try Bitmap.fastOr(testing.allocator, &ptrs);
    defer fast.deinit();
    try expectMatches(&want, &fast);

    var folded = try Bitmap.init(testing.allocator);
    defer folded.deinit();
    for (ptrs) |p| try folded.orInPlace(p);
    try expectMatches(&want, &folded);

    // The two unions must agree value for value, not just with the model.
    const fast_vals = try fast.toArray(testing.allocator);
    defer testing.allocator.free(fast_vals);
    const folded_vals = try folded.toArray(testing.allocator);
    defer testing.allocator.free(folded_vals);
    try testing.expectEqualSlices(u64, folded_vals, fast_vals);

    fast.cleanup();
    try expectMatches(&want, &fast);
}

// ---------------------------------------------------------------------------
// Serialization round trips
// ---------------------------------------------------------------------------

/// Serializing and reopening must reproduce the buffer bit for bit, through
/// both the borrowing and the copying entry points.
fn checkRoundTrip(ref: *const RefSet, bm: *const Bitmap) !void {
    const buf = try bm.toBufferCopy(testing.allocator);
    defer testing.allocator.free(buf);

    var borrowed = try Bitmap.fromBuffer(testing.allocator, buf);
    defer borrowed.deinit();
    try testing.expectEqualSlices(u16, bm.data, borrowed.data);
    try expectMatches(ref, &borrowed);

    var copied = try Bitmap.fromBufferCopy(testing.allocator, buf);
    defer copied.deinit();
    try testing.expectEqualSlices(u16, bm.data, copied.data);
    try expectMatches(ref, &copied);
}

test "serialized bitmaps reopen bit for bit" {
    var prng = std.Random.DefaultPrng.init(0x00B1_7B17);
    const rnd = prng.random();
    const bases = clusterBases(rnd);

    const pool = try testing.allocator.alloc(u64, 1_000);
    defer testing.allocator.free(pool);
    for (pool) |*v| v.* = rnd.int(u64) >> 8;

    // Empty, tiny, and three sizes that reach into bitmap containers and many
    // keys; the last two also go through cleanup first, since a compacted
    // buffer is a different shape.
    for ([_]usize{ 0, 1, 64, 4_000, 20_000 }) |n| {
        const vals = try testing.allocator.alloc(u64, n);
        defer testing.allocator.free(vals);
        mixedValues(rnd, bases, pool, vals);

        var bm = try bitmapOf(vals);
        defer bm.deinit();
        var ref = try refSetOf(vals);
        defer ref.deinit(testing.allocator);

        try checkRoundTrip(&ref, &bm);

        // Empty a few containers, compact, and round trip the compacted shape.
        var it = ref.keyIterator();
        var dropped: usize = 0;
        while (it.next()) |k| {
            if (dropped >= n / 4) break;
            _ = bm.remove(k.*);
            dropped += 1;
        }
        var kept = RefSet.empty;
        defer kept.deinit(testing.allocator);
        var vit = bm.iterator();
        while (vit.next()) |v| try kept.put(testing.allocator, v, {});

        bm.cleanup();
        try checkRoundTrip(&kept, &bm);
    }
}

test "a bitmap reopened from a buffer keeps growing correctly" {
    var prng = std.Random.DefaultPrng.init(0x0000_0C0C);
    const rnd = prng.random();

    var bm = try Bitmap.init(testing.allocator);
    defer bm.deinit();
    var ref = RefSet.empty;
    defer ref.deinit(testing.allocator);

    // Reopen repeatedly, each time from a buffer the previous round produced,
    // so growth alternates between an owned and a borrowed buffer.
    var buffers: [8]?zroar.AlignedU8 = @splat(null);
    defer {
        for (buffers) |maybe| {
            if (maybe) |buf| testing.allocator.free(buf);
        }
    }

    for (&buffers) |*slot| {
        var i: usize = 0;
        while (i < 2_000) : (i += 1) {
            const x = rnd.int(u64) >> 12;
            _ = try bm.set(x);
            try ref.put(testing.allocator, x, {});
        }
        try expectMatches(&ref, &bm);

        const buf = try bm.toBufferCopy(testing.allocator);
        const reopened = try Bitmap.fromBuffer(testing.allocator, buf);
        bm.deinit();
        bm = reopened;
        slot.* = buf;
        try expectMatches(&ref, &bm);
    }
}
