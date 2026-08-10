//! zroar vs roaring64 (CRoaring's `roaring64_bitmap_t`) microbenchmarks.
//!
//! Mechanics cloned from ~/source/roaring-zig/microbench/bench.zig: a registry
//! of named functions, each returning a marker the harness accumulates so the
//! optimizer cannot delete the work, one warm-up call, then a loop until a
//! second of wall time has passed.
//!
//! Every benchmark exists as a `-zroar` / `-r64` pair doing the same job on the
//! same data, and the two halves of a pair must return the same marker. That is
//! checked once before any timing starts: comparing timings of two libraries
//! computing different answers is worse than useless.
//!
//! The `*64` benchmarks at the end are the 64-bit half of CRoaring's own
//! microbenchmark suite, ported from the same file, working on the same
//! per-file bitmaps it uses; their `-r64` column should line up with CRoaring's
//! published tables.
//!
//! Usage: bench [data_dir] [--synthetic|--oltp|--oltp-random] [-b|--bench <substring>]

const std = @import("std");
const zroar = @import("zroar");
const roaring64 = @import("roaring64");
const datasets = @import("datasets.zig");

const DataSet = datasets.DataSet;

const default_data_dir = "/tmp/CRoaring/benchmarks/realdata/census1881";

/// Wall time each benchmark is given.
const target_total_ns: u64 = 1_000_000_000;

/// Mixed90R10W's op count, and the seed its per-iteration PRNG restarts from.
const mixed_ops = 100_000;
const mixed_seed = 0x0FFE_1A7E;

/// MixedOLTP's burst: this many transactions, each opening one posting list and
/// running this many operations against it. Its own seed, restarted per
/// iteration like Mixed90R10W's.
const oltp_txns = 100;
const oltp_ops = 100;
const oltp_seed = 0x0C71_9A5E;

const Entry = struct { name: []const u8, func: *const fn (*const DataSet) u64 };

const Measurement = struct {
    entry: Entry,
    ns_per_iteration: u64,
};

const benches = [_]Entry{
    .{ .name = "ColdOpen0-zroar", .func = coldOpenZroar(0) },
    .{ .name = "ColdOpen0-r64", .func = coldOpenR64(0) },
    .{ .name = "ColdOpen1-zroar", .func = coldOpenZroar(1) },
    .{ .name = "ColdOpen1-r64", .func = coldOpenR64(1) },
    .{ .name = "ColdOpen16-zroar", .func = coldOpenZroar(16) },
    .{ .name = "ColdOpen16-r64", .func = coldOpenR64(16) },
    .{ .name = "ColdOpen256-zroar", .func = coldOpenZroar(256) },
    .{ .name = "ColdOpen256-r64", .func = coldOpenR64(256) },
    .{ .name = "WarmContains-zroar", .func = warmContainsZroar },
    .{ .name = "WarmContains-r64", .func = warmContainsR64 },
    .{ .name = "WarmIterate-zroar", .func = warmIterateZroar },
    .{ .name = "WarmIterate-r64", .func = warmIterateR64 },
    .{ .name = "WarmCard-zroar", .func = warmCardZroar },
    .{ .name = "WarmCard-r64", .func = warmCardR64 },
    .{ .name = "Mixed90R10W-zroar", .func = mixedZroar },
    .{ .name = "Mixed90R10W-r64", .func = mixedR64 },
    .{ .name = "MixedOLTP-zroar", .func = mixedOltpZroar },
    .{ .name = "MixedOLTP-r64", .func = mixedOltpR64 },
    .{ .name = "UnionAllSer-zroar", .func = unionAllSerZroar },
    .{ .name = "UnionAllSer-r64", .func = unionAllSerR64 },
    .{ .name = "Merge10K-zroar", .func = merge10kZroar },
    .{ .name = "Merge10K-r64", .func = merge10kR64 },
    .{ .name = "BuildSer-zroar", .func = buildSerZroar },
    .{ .name = "BuildSer-r64", .func = buildSerR64 },
    .{ .name = "BuildSortedSer-zroar", .func = buildSortedSerZroar },
    .{ .name = "BuildSortedSer-r64", .func = buildSortedSerR64 },
    .{ .name = "MemcpyBaseline", .func = memcpyBaseline },

    // The CRoaring microbenchmark suite; `-b 64-` selects exactly these.
    .{ .name = "SuccessiveIntersection64-zroar", .func = successiveIntersection64Zroar },
    .{ .name = "SuccessiveIntersection64-r64", .func = successiveIntersection64R64 },
    .{ .name = "SuccessiveIntersectionCardinality64-zroar", .func = successiveIntersectionCardinality64Zroar },
    .{ .name = "SuccessiveIntersectionCardinality64-r64", .func = successiveIntersectionCardinality64R64 },
    .{ .name = "SuccessiveUnionCardinality64-zroar", .func = successiveUnionCardinality64Zroar },
    .{ .name = "SuccessiveUnionCardinality64-r64", .func = successiveUnionCardinality64R64 },
    .{ .name = "SuccessiveDifferenceCardinality64-zroar", .func = successiveDifferenceCardinality64Zroar },
    .{ .name = "SuccessiveDifferenceCardinality64-r64", .func = successiveDifferenceCardinality64R64 },
    .{ .name = "SuccessiveUnion64-zroar", .func = successiveUnion64Zroar },
    .{ .name = "SuccessiveUnion64-r64", .func = successiveUnion64R64 },
    .{ .name = "TotalUnion64-zroar", .func = totalUnion64Zroar },
    .{ .name = "TotalUnion64-r64", .func = totalUnion64R64 },
    .{ .name = "RandomAccess64-zroar", .func = randomAccess64Zroar },
    .{ .name = "RandomAccess64-r64", .func = randomAccess64R64 },
    .{ .name = "ToArray64-zroar", .func = toArray64Zroar },
    .{ .name = "ToArray64-r64", .func = toArray64R64 },
    .{ .name = "IterateAll64-zroar", .func = iterateAll64Zroar },
    .{ .name = "IterateAll64-r64", .func = iterateAll64R64 },
    .{ .name = "ComputeCardinality64-zroar", .func = computeCardinality64Zroar },
    .{ .name = "ComputeCardinality64-r64", .func = computeCardinality64R64 },
};

// ---------------------------------------------------------------------------
// ColdOpen: open U from its serialized buffer, probe it k times, close it.
// This is what zroar exists for; r64 has to parse the whole bitmap first.
// ---------------------------------------------------------------------------

fn coldOpenZroar(comptime k: usize) *const fn (*const DataSet) u64 {
    return struct {
        fn f(ds: *const DataSet) u64 {
            var bm = zroar.Bitmap.fromBuffer(ds.allocator, ds.zr_u_buf) catch unreachable;
            defer bm.deinit();
            // The open is pointer arithmetic and k may be 0, so without this the
            // whole body folds away to a constant.
            std.mem.doNotOptimizeAway(bm.data.ptr);

            var hits: u64 = 0;
            for (ds.probes[0..k]) |p| {
                if (bm.contains(p)) hits += 1;
            }
            // Markers have to match across the pair, and a probe count of 0
            // leaves nothing to count, so ColdOpen0 reports the open itself.
            return if (k == 0) 1 else hits;
        }
    }.f;
}

fn coldOpenR64(comptime k: usize) *const fn (*const DataSet) u64 {
    return struct {
        fn f(ds: *const DataSet) u64 {
            const bm = roaring64.Bitmap64.portableDeserializeSafe(ds.r64_u_buf) catch unreachable;
            defer bm.free();

            var hits: u64 = 0;
            for (ds.probes[0..k]) |p| {
                if (bm.contains(p)) hits += 1;
            }
            return if (k == 0) 1 else hits;
        }
    }.f;
}

// ---------------------------------------------------------------------------
// Warm: U is already open, so these measure the data structures alone.
// ---------------------------------------------------------------------------

fn warmContainsZroar(ds: *const DataSet) u64 {
    var hits: u64 = 0;
    for (ds.probes) |p| {
        if (ds.zr_u.contains(p)) hits += 1;
    }
    return hits;
}

fn warmContainsR64(ds: *const DataSet) u64 {
    var hits: u64 = 0;
    for (ds.probes) |p| {
        if (ds.r64_u.contains(p)) hits += 1;
    }
    return hits;
}

fn warmIterateZroar(ds: *const DataSet) u64 {
    var n: u64 = 0;
    var it = ds.zr_u.iterator();
    while (it.next()) |_| n += 1;
    return n;
}

fn warmIterateR64(ds: *const DataSet) u64 {
    // The roaring64 iterator is heap allocated, so allocating and freeing it is
    // part of what iterating costs there.
    var it = ds.r64_u.iterator() catch unreachable;
    defer it.free();

    var n: u64 = 0;
    while (it.next()) |_| n += 1;
    return n;
}

fn warmCardZroar(ds: *const DataSet) u64 {
    return ds.zr_u.getCardinality();
}

fn warmCardR64(ds: *const DataSet) u64 {
    return ds.r64_u.cardinality();
}

// ---------------------------------------------------------------------------
// Mixed90R10W: open U, run 100k reads and writes over it, close it.
// ---------------------------------------------------------------------------

fn mixedZroar(ds: *const DataSet) u64 {
    // fromBufferCopy, not fromBuffer: the writes below would otherwise land in
    // the shared setup buffer every other benchmark reads.
    var bm = zroar.Bitmap.fromBufferCopy(ds.allocator, ds.zr_u_buf) catch unreachable;
    defer bm.deinit();

    var prng = std.Random.DefaultPrng.init(mixed_seed);
    const rnd = prng.random();

    var marker: u64 = 0;
    var i: usize = 0;
    while (i < mixed_ops) : (i += 1) {
        const v = rnd.uintAtMost(u64, ds.u_max);
        if (i % 10 == 0) {
            if (bm.set(v) catch unreachable) marker += 1;
        } else {
            if (bm.contains(v)) marker += 1;
        }
    }
    return marker;
}

fn mixedR64(ds: *const DataSet) u64 {
    const bm = roaring64.Bitmap64.portableDeserializeSafe(ds.r64_u_buf) catch unreachable;
    defer bm.free();

    var prng = std.Random.DefaultPrng.init(mixed_seed);
    const rnd = prng.random();

    var marker: u64 = 0;
    var i: usize = 0;
    while (i < mixed_ops) : (i += 1) {
        const v = rnd.uintAtMost(u64, ds.u_max);
        if (i % 10 == 0) {
            if (bm.addChecked(v)) marker += 1;
        } else {
            if (bm.contains(v)) marker += 1;
        }
    }
    return marker;
}

// ---------------------------------------------------------------------------
// MixedOLTP: a burst of transactions against one secondary index.
//
// A transaction fetches a posting list from storage, reads and writes it, and
// lets it go, so the open is inside the measurement rather than amortized away
// by it: that is what separates this from Mixed90R10W. Two other things differ
// and both come from the workload. Which list a transaction touches is chosen
// in proportion to its size, because a value that matches many rows is queried
// as often as it is large. And the writes append: row-ids are handed out in
// increasing order, so index maintenance always adds a value above every value
// already there, never one in the middle.
// ---------------------------------------------------------------------------

/// Picks a posting list with probability proportional to its size: a random
/// point in the total cardinality, and the first list whose running total is
/// past it.
fn pickList(ds: *const DataSet, rnd: std.Random) usize {
    const cum = ds.file_cum;
    const point = rnd.uintLessThan(u64, cum[cum.len - 1]);

    var lo: usize = 0;
    var hi: usize = cum.len - 1;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cum[mid] <= point) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn mixedOltpZroar(ds: *const DataSet) u64 {
    var prng = std.Random.DefaultPrng.init(oltp_seed);
    const rnd = prng.random();
    var next_row = ds.row_id_next;

    var marker: u64 = 0;
    var t: usize = 0;
    while (t < oltp_txns) : (t += 1) {
        const list = pickList(ds, rnd);
        // fromBufferCopy, not fromBuffer: the writes below would otherwise land
        // in the shared setup buffer every other benchmark reads.
        var bm = zroar.Bitmap.fromBufferCopy(ds.allocator, ds.zr_file_bufs[list]) catch unreachable;

        var i: usize = 0;
        while (i < oltp_ops) : (i += 1) {
            if (i % 10 == 0) {
                if (bm.set(next_row) catch unreachable) marker += 1;
                next_row += 1;
            } else {
                const v = rnd.uintAtMost(u64, ds.row_id_max);
                if (bm.contains(v)) marker += 1;
            }
        }
        bm.deinit();
    }
    return marker;
}

fn mixedOltpR64(ds: *const DataSet) u64 {
    var prng = std.Random.DefaultPrng.init(oltp_seed);
    const rnd = prng.random();
    var next_row = ds.row_id_next;

    var marker: u64 = 0;
    var t: usize = 0;
    while (t < oltp_txns) : (t += 1) {
        const list = pickList(ds, rnd);
        const bm = roaring64.Bitmap64.portableDeserializeSafe(ds.r64_file_bufs[list]) catch unreachable;

        var i: usize = 0;
        while (i < oltp_ops) : (i += 1) {
            if (i % 10 == 0) {
                if (bm.addChecked(next_row)) marker += 1;
                next_row += 1;
            } else {
                const v = rnd.uintAtMost(u64, ds.row_id_max);
                if (bm.contains(v)) marker += 1;
            }
        }
        bm.free();
    }
    return marker;
}

// ---------------------------------------------------------------------------
// Bulk unions.
// ---------------------------------------------------------------------------

/// Open every per-file buffer, union the lot, serialize the result.
fn unionAllSerZroar(ds: *const DataSet) u64 {
    for (ds.zr_file_bufs, 0..) |buf, i| {
        ds.zr_open[i] = zroar.Bitmap.fromBuffer(ds.allocator, buf) catch unreachable;
    }
    var res = zroar.Bitmap.fastOr(ds.allocator, ds.zr_open_ptrs) catch unreachable;
    defer res.deinit();

    // fastOr can leave one dead container behind, and toBuffer hands out the
    // buffer as it stands, so compact before measuring its size.
    res.cleanup();
    std.mem.doNotOptimizeAway(res.toBuffer().len);

    const marker = res.getCardinality();
    for (ds.zr_open) |*bm| bm.deinit();
    return marker;
}

fn unionAllSerR64(ds: *const DataSet) u64 {
    for (ds.r64_file_bufs, 0..) |buf, i| {
        ds.r64_open[i] = roaring64.Bitmap64.portableDeserializeSafe(buf) catch unreachable;
    }
    const acc = ds.r64_open[0];
    for (ds.r64_open[1..]) |bm| acc._orInPlace(bm);
    std.mem.doNotOptimizeAway(acc.portableSerialize(ds.scratch));

    const marker = acc.cardinality();
    for (ds.r64_open) |bm| bm.free();
    return marker;
}

/// Union 10k small scattered bitmaps that are already open.
fn merge10kZroar(ds: *const DataSet) u64 {
    var res = zroar.Bitmap.fastOr(ds.allocator, ds.zr_merge_ptrs) catch unreachable;
    defer res.deinit();
    res.cleanup();
    return res.getCardinality();
}

fn merge10kR64(ds: *const DataSet) u64 {
    const res = roaring64.Bitmap64.create() catch unreachable;
    defer res.free();
    for (ds.r64_merge) |bm| res._orInPlace(bm);
    return res.cardinality();
}

// ---------------------------------------------------------------------------
// Build a bitmap from scratch and serialize it.
// ---------------------------------------------------------------------------

fn buildSerZroar(ds: *const DataSet) u64 {
    var bm = zroar.Bitmap.init(ds.allocator) catch unreachable;
    defer bm.deinit();
    for (ds.build_vals) |v| _ = bm.set(v) catch unreachable;

    const marker = bm.getCardinality();
    const buf = bm.toBufferCopy(ds.allocator) catch unreachable;
    ds.allocator.free(buf);
    return marker;
}

fn buildSerR64(ds: *const DataSet) u64 {
    const bm = roaring64.Bitmap64.create() catch unreachable;
    defer bm.free();
    for (ds.build_vals) |v| bm.add(v);
    _ = bm.runOptimize();
    std.mem.doNotOptimizeAway(bm.portableSerialize(ds.scratch));
    return bm.cardinality();
}

fn buildSortedSerZroar(ds: *const DataSet) u64 {
    var bm = zroar.Bitmap.fromSortedList(ds.allocator, ds.build_vals_sorted) catch unreachable;
    defer bm.deinit();

    const marker = bm.getCardinality();
    const buf = bm.toBufferCopy(ds.allocator) catch unreachable;
    ds.allocator.free(buf);
    return marker;
}

fn buildSortedSerR64(ds: *const DataSet) u64 {
    const bm = roaring64.Bitmap64.create() catch unreachable;
    defer bm.free();
    bm.addMany(ds.build_vals_sorted);
    _ = bm.runOptimize();
    std.mem.doNotOptimizeAway(bm.portableSerialize(ds.scratch));
    return bm.cardinality();
}

/// How long it takes to merely copy U's bytes, to subtract from the rest.
fn memcpyBaseline(ds: *const DataSet) u64 {
    @memcpy(ds.scratch[0..ds.zr_u_buf.len], ds.zr_u_buf);
    return ds.scratch[0];
}

// ---------------------------------------------------------------------------
// The CRoaring microbenchmark suite, 64-bit half.
//
// Bodies copied from ~/source/roaring-zig/microbench/bench.zig so the timings
// mean the same thing: consecutive pairs of the per-file bitmaps for the
// successive benchmarks, the same three probes for RandomAccess64, one pass
// over every file bitmap for the rest.
//
// CRoaring answers "how many values would this operation produce" without
// producing them (`roaring64_bitmap_and_cardinality` and friends); zroar has the
// same three fused calls, so the *Cardinality64 pairs compare like with like:
// neither side builds a result bitmap.
// ---------------------------------------------------------------------------

fn successiveIntersection64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_zroar.len) : (i += 1) {
        var tmp = zroar.Bitmap.And(ds.allocator, &ds.files_zroar[i], &ds.files_zroar[i + 1]) catch unreachable;
        marker += tmp.getCardinality();
        tmp.deinit();
    }
    return marker;
}

fn successiveIntersection64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_r64.len) : (i += 1) {
        const tmp = ds.files_r64[i]._and(ds.files_r64[i + 1]) catch unreachable;
        marker += tmp.cardinality();
        tmp.free();
    }
    return marker;
}

/// SuccessiveIntersection64 without the intersection: `andCardinality` counts
/// the overlap container by container and builds nothing.
fn successiveIntersectionCardinality64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_zroar.len) : (i += 1) {
        marker += ds.files_zroar[i].andCardinality(&ds.files_zroar[i + 1]);
    }
    return marker;
}

fn successiveIntersectionCardinality64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_r64.len) : (i += 1) {
        marker += ds.files_r64[i]._andCardinality(ds.files_r64[i + 1]);
    }
    return marker;
}

/// |a ∪ b| as |a| + |b| - |a ∩ b|, so no union is ever built.
fn successiveUnionCardinality64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_zroar.len) : (i += 1) {
        marker += ds.files_zroar[i].orCardinality(&ds.files_zroar[i + 1]);
    }
    return marker;
}

fn successiveUnionCardinality64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_r64.len) : (i += 1) {
        marker += ds.files_r64[i]._orCardinality(ds.files_r64[i + 1]);
    }
    return marker;
}

/// |a \ b| as |a| - |a ∩ b|: no clone and no difference, just the two headers
/// and the overlap.
fn successiveDifferenceCardinality64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_zroar.len) : (i += 1) {
        marker += ds.files_zroar[i].andNotCardinality(&ds.files_zroar[i + 1]);
    }
    return marker;
}

fn successiveDifferenceCardinality64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_r64.len) : (i += 1) {
        marker += ds.files_r64[i]._andnotCardinality(ds.files_r64[i + 1]);
    }
    return marker;
}

fn successiveUnion64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_zroar.len) : (i += 1) {
        var tmp = zroar.Bitmap.Or(ds.allocator, &ds.files_zroar[i], &ds.files_zroar[i + 1]) catch unreachable;
        marker += tmp.getCardinality();
        tmp.deinit();
    }
    return marker;
}

fn successiveUnion64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < ds.files_r64.len) : (i += 1) {
        const tmp = ds.files_r64[i]._or(ds.files_r64[i + 1]) catch unreachable;
        marker += tmp.cardinality();
        tmp.free();
    }
    return marker;
}

/// The union of every file bitmap. The microbench's TotalUnion uses `or_many`,
/// which CRoaring only offers for 32-bit bitmaps; folding or-in-place into a
/// copy of the first bitmap is the 64-bit equivalent.
fn totalUnion64Zroar(ds: *const DataSet) u64 {
    var res = zroar.Bitmap.fastOr(ds.allocator, ds.files_zroar_ptrs) catch unreachable;
    defer res.deinit();
    return res.getCardinality();
}

fn totalUnion64R64(ds: *const DataSet) u64 {
    const acc = ds.files_r64[0].copy() catch unreachable;
    defer acc.free();
    for (ds.files_r64[1..]) |bm| acc._orInPlace(bm);
    return acc.cardinality();
}

fn randomAccess64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    const mv = ds.files_max_value;
    for (ds.files_zroar) |*bm| {
        if (bm.contains(mv / 4)) marker += 1;
        if (bm.contains(mv / 2)) marker += 1;
        if (bm.contains(mv - mv / 4)) marker += 1;
    }
    return marker;
}

fn randomAccess64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    const mv = ds.files_max_value;
    for (ds.files_r64) |bm| {
        if (bm.contains(mv / 4)) marker += 1;
        if (bm.contains(mv / 2)) marker += 1;
        if (bm.contains(mv - mv / 4)) marker += 1;
    }
    return marker;
}

/// zroar has no fill-this-buffer variant, so every bitmap costs an allocation
/// here; r64 unpacks into the buffer set up for it.
fn toArray64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    for (ds.files_zroar) |*bm| {
        const arr = bm.toArray(ds.allocator) catch unreachable;
        defer ds.allocator.free(arr);
        if (arr.len > 0) marker += arr[0] & 0xffffffff;
    }
    return marker;
}

fn toArray64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    for (ds.files_r64) |bm| {
        const card = bm.cardinality();
        bm.toUint64Array(ds.files_array_buf[0..@intCast(card)]);
        if (card > 0) marker += ds.files_array_buf[0] & 0xffffffff;
    }
    return marker;
}

fn iterateAll64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    for (ds.files_zroar) |*bm| {
        var it = bm.iterator();
        while (it.next()) |_| marker += 1;
    }
    return marker;
}

fn iterateAll64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    for (ds.files_r64) |bm| {
        var it = bm.iterator() catch unreachable;
        defer it.free();
        while (it.hasValue()) {
            marker += 1;
            _ = it.next();
        }
    }
    return marker;
}

fn computeCardinality64Zroar(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    for (ds.files_zroar) |*bm| {
        marker += bm.getCardinality();
    }
    return marker;
}

fn computeCardinality64R64(ds: *const DataSet) u64 {
    var marker: u64 = 0;
    for (ds.files_r64) |bm| {
        marker += bm.cardinality();
    }
    return marker;
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Runs both halves of every pair once and insists they agree. A mismatch means
/// zroar and roaring64 disagree about the data, which no timing can excuse.
fn checkPairs(ds: *const DataSet) void {
    for (benches) |zr| {
        if (!std.mem.endsWith(u8, zr.name, "-zroar")) continue;
        const base = zr.name[0 .. zr.name.len - "-zroar".len];
        const r64 = findPair(base) orelse
            std.debug.panic("{s} has no -r64 counterpart", .{zr.name});

        const got = zr.func(ds);
        const want = r64.func(ds);
        if (got != want) std.debug.panic(
            "marker mismatch: {s} returned {d} but {s} returned {d}",
            .{ zr.name, got, r64.name, want },
        );
    }
}

fn findPair(base: []const u8) ?Entry {
    for (benches) |e| {
        if (e.name.len != base.len + "-r64".len) continue;
        if (!std.mem.startsWith(u8, e.name, base)) continue;
        if (!std.mem.endsWith(u8, e.name, "-r64")) continue;
        return e;
    }
    return null;
}

fn findMeasurementPair(measurements: []const Measurement, base: []const u8) ?Measurement {
    for (measurements) |measurement| {
        const name = measurement.entry.name;
        if (name.len != base.len + "-r64".len) continue;
        if (!std.mem.startsWith(u8, name, base)) continue;
        if (!std.mem.endsWith(u8, name, "-r64")) continue;
        return measurement;
    }
    return null;
}

fn printComparison(measurements: []const Measurement, ds: *const DataSet) void {
    var pair_count: usize = 0;
    var zroar_wins: usize = 0;
    var r64_wins: usize = 0;
    var ties: usize = 0;
    for (measurements) |zr| {
        if (!std.mem.endsWith(u8, zr.entry.name, "-zroar")) continue;

        const base = zr.entry.name[0 .. zr.entry.name.len - "-zroar".len];
        const r64 = findMeasurementPair(measurements, base) orelse continue;

        if (pair_count == 0) {
            std.debug.print("\n", .{});
            std.debug.print("Comparison: zroar vs CRoaring roaring64 (lower time is better)\n", .{});
            std.debug.print("-------------------------------------------------------------------------------------------\n", .{});
            std.debug.print("Benchmark                                      zroar            r64  Result\n", .{});
            std.debug.print("-------------------------------------------------------------------------------------------\n", .{});
        }

        const zr_ns: f64 = @floatFromInt(zr.ns_per_iteration);
        const r64_ns: f64 = @floatFromInt(r64.ns_per_iteration);
        if (zr.ns_per_iteration < r64.ns_per_iteration) {
            std.debug.print(
                "{s:<40}{d:12} ns {d:12} ns  zroar {d:.2}x faster\n",
                .{ base, zr.ns_per_iteration, r64.ns_per_iteration, r64_ns / zr_ns },
            );
            zroar_wins += 1;
        } else if (zr.ns_per_iteration > r64.ns_per_iteration) {
            std.debug.print(
                "{s:<40}{d:12} ns {d:12} ns  CRoaring {d:.2}x faster\n",
                .{ base, zr.ns_per_iteration, r64.ns_per_iteration, zr_ns / r64_ns },
            );
            r64_wins += 1;
        } else {
            std.debug.print(
                "{s:<40}{d:12} ns {d:12} ns  tie\n",
                .{ base, zr.ns_per_iteration, r64.ns_per_iteration },
            );
            ties += 1;
        }
        pair_count += 1;
    }

    if (pair_count == 0) return;

    std.debug.print(
        "\nBenchmark wins: zroar {d}, r64 {d}, ties {d} ({d} comparable pairs)\n",
        .{ zroar_wins, r64_wins, ties, pair_count },
    );

    const zr_size: f64 = @floatFromInt(ds.zr_u_buf.len);
    const r64_size: f64 = @floatFromInt(ds.r64_u_buf.len);
    if (ds.zr_u_buf.len >= ds.r64_u_buf.len) {
        std.debug.print(
            "\nSerialized union: zroar {d} bytes, r64 {d} bytes (zroar {d:.2}x larger)\n",
            .{ ds.zr_u_buf.len, ds.r64_u_buf.len, zr_size / r64_size },
        );
    } else {
        std.debug.print(
            "\nSerialized union: zroar {d} bytes, r64 {d} bytes (zroar {d:.2}x smaller)\n",
            .{ ds.zr_u_buf.len, ds.r64_u_buf.len, r64_size / zr_size },
        );
    }
}

fn run(io: std.Io, ds: *const DataSet, filter: ?[]const u8) void {
    std.debug.print("---------------------------------------------------------------------\n", .{});
    std.debug.print("Benchmark                                  Time            Iterations\n", .{});
    std.debug.print("---------------------------------------------------------------------\n", .{});

    var matched: usize = 0;
    var measurements: [benches.len]Measurement = undefined;
    for (benches) |b| {
        if (filter) |f| if (std.mem.indexOf(u8, b.name, f) == null) continue;

        var marker_sum: u64 = 0;
        var iterations: u64 = 0;
        var total_ns: u64 = 0;

        marker_sum +%= b.func(ds); // one warm-up, not timed

        const start = std.Io.Clock.Timestamp.now(io, .awake);
        while (true) {
            marker_sum +%= b.func(ds);
            iterations += 1;
            total_ns = @intCast(start.untilNow(io).raw.toNanoseconds());
            if (total_ns >= target_total_ns) break;
        }
        const ns_per_iteration = total_ns / iterations;
        std.debug.print("{s:<36}{d:12} ns {d:12}\n", .{ b.name, ns_per_iteration, iterations });

        measurements[matched] = .{
            .entry = b,
            .ns_per_iteration = ns_per_iteration,
        };

        // Keeps the accumulated markers, and with them the benchmark bodies, alive.
        if (marker_sum == 0xDEADBEEFDEADBEEF) @panic("impossible");
        matched += 1;
    }
    if (filter != null and matched == 0) {
        std.debug.print("No benchmarks matched filter: '{s}'\n", .{filter.?});
    }
    printComparison(measurements[0..matched], ds);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // CRoaring allocates through libc, so zroar has to as well: otherwise the
    // comparison includes a difference in allocators.
    const allocator = std.heap.c_allocator;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var dir_path: []const u8 = default_data_dir;
    var mode: datasets.Mode = .realdata;
    var filter: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "--bench")) {
            if (i + 1 < args.len) {
                filter = args[i + 1];
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--synthetic")) {
            mode = .synthetic;
            continue;
        }
        if (std.mem.eql(u8, a, "--oltp")) {
            mode = .oltp;
            continue;
        }
        if (std.mem.eql(u8, a, "--oltp-random")) {
            mode = .oltp_random;
            continue;
        }
        if (a.len > 0 and a[0] != '-') dir_path = a;
    }

    const source: []const u8 = switch (mode) {
        .realdata => dir_path,
        .synthetic => "synthetic",
        .oltp => "oltp (auto-increment row-ids)",
        .oltp_random => "oltp (scattered u64 row-ids)",
    };
    std.debug.print("data source: {s}\n", .{source});
    var ds = datasets.load(io, allocator, dir_path, mode) catch |err| {
        std.debug.print("failed to load the data set: {s}\n", .{@errorName(err)});
        std.debug.print(
            "usage: bench [data_dir] [--synthetic|--oltp|--oltp-random] [-b|--bench <substring>]\n",
            .{},
        );
        return err;
    };
    defer ds.deinit();

    datasets.checkUnions(&ds);
    checkPairs(&ds);

    run(io, &ds, filter);
}
