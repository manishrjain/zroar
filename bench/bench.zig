// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! zroar vs roaring64 (CRoaring's `roaring64_bitmap_t`) benchmarks.
//!
//! The comparison rests on CRoaring's own benchmarks, ported row for row so a
//! reader can hold our numbers next to theirs — that is the only way to make
//! a statement about how zroar compares to CRoaring without tilting the field.
//! Two of their suites have 64-bit rows:
//!
//!   * `microbenchmarks/bench.cpp` (suite `realdata`): the per-file bitmaps of
//!     a CRoaring data set, `run_optimize`d, and the `*64` benchmarks over
//!     them — pairwise set operations on consecutive files, three probes per
//!     file, unpack, iterate, cardinality. Bodies are copied line for line;
//!     `RandomAccess64Cpp` (their C++ `Roaring64Map`) is the one omission,
//!     since it is not reachable from Zig.
//!   * `microbenchmarks/synthetic_bench.cpp` (suite `synthetic`): the `r64*`
//!     rows — contains hit/miss, insert, remove, serialize, deserialize over a
//!     grid of `count` values `i * step`, and contains / insert+remove under
//!     ten bitmasks. Their per-op rows do one operation per Google Benchmark
//!     iteration; here a call does one pass over the whole sequence and the
//!     time is divided by the pass length, so the columns still read as time
//!     per operation. Row `X/count/step` here is their `r64X/count/step`,
//!     with the step written as a power of two; the `Serialize` and
//!     `Deserialize` rows carry both of their formats as columns.
//!
//! On top of that, one axis of our own (suite `cold`): every realdata row again
//! with the bitmaps opened from their serialized form inside the measurement
//! (`Cold*`), plus `MixedOLTP`, a transaction against a secondary index. Both
//! serialized formats CRoaring offers get a column wherever a buffer is
//! opened or written: portable, the interchange format, and frozen, its memory
//! layout written out and viewed in place — which is the class zroar's format
//! belongs to. Frozen views are read-only, so the one row that writes after
//! opening (`MixedOLTP`) opens its frozen column as a view plus a copy.
//!
//! Harness: every row is measured through the same loop, one warm-up call and
//! then calls until the row's time budget is spent, for every implementation
//! in turn. Before any timing, each implementation runs once and the markers
//! it returns must agree — comparing timings of two libraries computing
//! different answers is worse than useless. Setup is untimed and shared; a
//! row that must exclude part of itself (`Remove` rebuilds its input every
//! call, as CRoaring's does under `PauseTiming`) reports that time and it is
//! subtracted.
//!
//! Usage: bench [data_dir] [--oltp] [--suite <name>]...
//!              [-b|--bench <substring>] [--time <ms>] [--out <tsv>]
//!
//! `--out` writes the same results as tab-separated lines (`meta key value`
//! and `row suite name impl us_per_op`) for bench/report.py to render. Times
//! are microseconds, in the table and in the file.

const std = @import("std");
const builtin = @import("builtin");
const zroar = @import("zroar");
const roaring64 = @import("roaring64");
const croaring = @import("croaring");
const datasets = @import("datasets.zig");

const DataSet = datasets.DataSet;
const Bitmap64 = roaring64.Bitmap64;

const default_data_dir = "/tmp/CRoaring/benchmarks/realdata/census1881";

/// Wall time each implementation of each row is given. Google Benchmark's
/// default minimum, so a row here and a row there run about as long.
const default_target_ms: u64 = 500;

/// MixedOLTP's burst: this many transactions, each opening one posting list and
/// running this many operations against it, from a PRNG that restarts from
/// this seed every call.
const oltp_txns = 100;
const oltp_ops = 100;
const oltp_seed = 0x0C71_9A5E;

/// One call of a Random row draws this many probes (or add/remove pairs).
const random_probes = 1 << 16;

// ---------------------------------------------------------------------------
// Rows
// ---------------------------------------------------------------------------

/// A column of the results table.
const Impl = enum {
    zroar,
    /// CRoaring roaring64; where a format is involved, the portable one.
    r64,
    /// CRoaring roaring64 through its frozen format.
    r64_frozen,

    fn label(self: Impl) []const u8 {
        return switch (self) {
            .zroar => "zroar",
            .r64 => "r64",
            .r64_frozen => "r64 frozen",
        };
    }
};

const Suite = enum { realdata, synthetic, cold };

const Func = *const fn (*DataSet) u64;

const Variant = struct { impl: Impl, func: Func };

/// A synthetic row's shape, handed to its setup hook.
const Params = struct { count: usize = 0, step: u64 = 0, mask: u64 = 0 };

const Row = struct {
    name: []const u8,
    suite: Suite,
    variants: []const Variant,
    /// Operations per call, so per-op rows report per-op time.
    ops: u64 = 1,
    params: Params = .{},
    setup: ?*const fn (*DataSet, Params) void = null,
    teardown: ?*const fn (*DataSet) void = null,
};

const rows: []const Row = realdata_rows ++ synthetic_rows ++ open_rows;

// ---------------------------------------------------------------------------
// Suite `realdata`: CRoaring's bench.cpp, 64-bit rows.
//
// Every body takes the bitmaps it works on as a slice, so the same body serves
// the warm row (the per-file set, open since setup) and its cold twin (opened
// from the serialized buffers inside the call).
//
// CRoaring answers "how many values would this operation produce" without
// producing them (`roaring64_bitmap_and_cardinality` and friends); zroar has the
// same three fused calls, so the *Cardinality64 rows compare like with like:
// neither side builds a result bitmap.
// ---------------------------------------------------------------------------

const ZOp = *const fn (*const DataSet, []zroar.Bitmap) u64;
const ROp = *const fn (*const DataSet, []const *Bitmap64) u64;

const RealdataOp = struct { name: []const u8, zroar: ZOp, r64: ROp };

const realdata_ops = [_]RealdataOp{
    .{ .name = "SuccessiveIntersection64", .zroar = successiveIntersection64Zroar, .r64 = successiveIntersection64R64 },
    .{ .name = "SuccessiveIntersectionCardinality64", .zroar = successiveIntersectionCardinality64Zroar, .r64 = successiveIntersectionCardinality64R64 },
    .{ .name = "SuccessiveUnionCardinality64", .zroar = successiveUnionCardinality64Zroar, .r64 = successiveUnionCardinality64R64 },
    .{ .name = "SuccessiveDifferenceCardinality64", .zroar = successiveDifferenceCardinality64Zroar, .r64 = successiveDifferenceCardinality64R64 },
    .{ .name = "SuccessiveUnion64", .zroar = successiveUnion64Zroar, .r64 = successiveUnion64R64 },
    .{ .name = "RandomAccess64", .zroar = randomAccess64Zroar, .r64 = randomAccess64R64 },
    .{ .name = "ToArray64", .zroar = toArray64Zroar, .r64 = toArray64R64 },
    .{ .name = "IterateAll64", .zroar = iterateAll64Zroar, .r64 = iterateAll64R64 },
    .{ .name = "ComputeCardinality64", .zroar = computeCardinality64Zroar, .r64 = computeCardinality64R64 },
};

const realdata_rows: []const Row = blk: {
    var out: []const Row = &.{};
    for (realdata_ops) |op| {
        out = out ++ &[_]Row{.{
            .name = op.name,
            .suite = .realdata,
            .variants = &.{
                .{ .impl = .zroar, .func = warmZroar(op.zroar) },
                .{ .impl = .r64, .func = warmR64(op.r64) },
            },
        }};
    }
    break :blk out;
};

fn warmZroar(comptime op: ZOp) Func {
    return struct {
        fn f(ds: *DataSet) u64 {
            return op(ds, ds.zr_bms);
        }
    }.f;
}

fn warmR64(comptime op: ROp) Func {
    return struct {
        fn f(ds: *DataSet) u64 {
            return op(ds, ds.r64_bms);
        }
    }.f;
}

fn successiveIntersection64Zroar(ds: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        var tmp = zroar.Bitmap.And(ds.allocator, &bms[i], &bms[i + 1]) catch unreachable;
        marker += tmp.getCardinality();
        tmp.deinit();
    }
    return marker;
}

fn successiveIntersection64R64(_: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        const tmp = bms[i]._and(bms[i + 1]) catch unreachable;
        marker += tmp.cardinality();
        tmp.free();
    }
    return marker;
}

/// SuccessiveIntersection64 without the intersection: `andCardinality` counts
/// the overlap container by container and builds nothing.
fn successiveIntersectionCardinality64Zroar(_: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        marker += bms[i].andCardinality(&bms[i + 1]);
    }
    return marker;
}

fn successiveIntersectionCardinality64R64(_: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        marker += bms[i]._andCardinality(bms[i + 1]);
    }
    return marker;
}

/// |a ∪ b| as |a| + |b| - |a ∩ b|, so no union is ever built.
fn successiveUnionCardinality64Zroar(_: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        marker += bms[i].orCardinality(&bms[i + 1]);
    }
    return marker;
}

fn successiveUnionCardinality64R64(_: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        marker += bms[i]._orCardinality(bms[i + 1]);
    }
    return marker;
}

/// |a \ b| as |a| - |a ∩ b|: no clone and no difference, just the two headers
/// and the overlap.
fn successiveDifferenceCardinality64Zroar(_: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        marker += bms[i].andNotCardinality(&bms[i + 1]);
    }
    return marker;
}

fn successiveDifferenceCardinality64R64(_: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        marker += bms[i]._andnotCardinality(bms[i + 1]);
    }
    return marker;
}

fn successiveUnion64Zroar(ds: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        var tmp = zroar.Bitmap.Or(ds.allocator, &bms[i], &bms[i + 1]) catch unreachable;
        marker += tmp.getCardinality();
        tmp.deinit();
    }
    return marker;
}

fn successiveUnion64R64(_: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    var i: usize = 0;
    while (i + 1 < bms.len) : (i += 1) {
        const tmp = bms[i]._or(bms[i + 1]) catch unreachable;
        marker += tmp.cardinality();
        tmp.free();
    }
    return marker;
}

fn randomAccess64Zroar(ds: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    const mv = ds.max_value;
    for (bms) |*bm| {
        if (bm.contains(mv / 4)) marker += 1;
        if (bm.contains(mv / 2)) marker += 1;
        if (bm.contains(mv - mv / 4)) marker += 1;
    }
    return marker;
}

fn randomAccess64R64(ds: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    const mv = ds.max_value;
    for (bms) |bm| {
        if (bm.contains(mv / 4)) marker += 1;
        if (bm.contains(mv / 2)) marker += 1;
        if (bm.contains(mv - mv / 4)) marker += 1;
    }
    return marker;
}

/// zroar has no fill-this-buffer variant, so every bitmap costs an allocation
/// here; r64 unpacks into the buffer set up for it.
fn toArray64Zroar(ds: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    for (bms) |*bm| {
        const arr = bm.toArray(ds.allocator) catch unreachable;
        defer ds.allocator.free(arr);
        if (arr.len > 0) marker += arr[0] & 0xffffffff;
    }
    return marker;
}

fn toArray64R64(ds: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    for (bms) |bm| {
        const card = bm.cardinality();
        bm.toUint64Array(ds.array_buf[0..@intCast(card)]);
        if (card > 0) marker += ds.array_buf[0] & 0xffffffff;
    }
    return marker;
}

fn iterateAll64Zroar(_: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    for (bms) |*bm| {
        var it = bm.iterator();
        while (it.next()) |_| marker += 1;
    }
    return marker;
}

fn iterateAll64R64(_: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    for (bms) |bm| {
        var it = bm.iterator() catch unreachable;
        defer it.free();
        while (it.hasValue()) {
            marker += 1;
            _ = it.next();
        }
    }
    return marker;
}

fn computeCardinality64Zroar(_: *const DataSet, bms: []zroar.Bitmap) u64 {
    var marker: u64 = 0;
    for (bms) |*bm| marker += bm.getCardinality();
    return marker;
}

fn computeCardinality64R64(_: *const DataSet, bms: []const *Bitmap64) u64 {
    var marker: u64 = 0;
    for (bms) |bm| marker += bm.cardinality();
    return marker;
}

// ---------------------------------------------------------------------------
// Suite `synthetic`: CRoaring's synthetic_bench.cpp, r64 rows.
//
// The stepped rows run over the same grid as theirs: `count` in 1e3..1e6 by
// tens, `step` in 1..2^48 by 256. A shape is `count` values `i * step`, so a
// wide step spreads one value per container and one container per key, and
// the widest ones walk the deep end of the key space. The random rows use
// their ten bitmasks, indexed as their DenseRange indexes them.
// ---------------------------------------------------------------------------

const grid_counts = [_]usize{ 1_000, 10_000, 100_000, 1_000_000 };
const grid_steps = [_]u64{ 1, 1 << 8, 1 << 16, 1 << 24, 1 << 32, 1 << 40, 1 << 48 };

/// The step as CRoaring's row names would spell it if they were readable:
/// `1`, `2^8`, ... rather than `1099511627776`. Their `r64X/c/1099511627776`
/// is our `X/c/2^40`.
fn stepLabel(comptime step: u64) []const u8 {
    if (step == 1) return "1";
    return std.fmt.comptimePrint("2^{d}", .{@ctz(step)});
}

// `i * step` wraps past 2^64 once `i` reaches 65536 at the widest step, so the
// 100k and 1M rows there hold 65536 distinct values, written over and over.
// C's unsigned arithmetic wraps the same way in their bench, so the rows are
// kept as they are; the wrapping multiply just makes the wrap defined here.

/// Bitmasks with 20 bits set, spread over 20, 32, 48 and 64 bits, verbatim
/// from synthetic_bench.cpp: the set size is bounded and the hit rate high
/// (~63% after 2^20 draws), while the density changes with the spread.
const bitmasks = [_]u64{
    0x00000000000FFFFF,
    0x0000000FFFFF0000,
    0x000FFFFF00000000,
    0xFFFFF00000000000,
    0x000000005DBFC83E,
    0x00005DBFC83E0000,
    0x5DBFC83E00000000,
    0x0000493B189604B6,
    0x493B189604B60000,
    0x420C684950A2D088,
};

const Stepped = struct {
    name: []const u8,
    variants: []const Variant,
    /// Whether a call is `count` operations, or one.
    per_value: bool,
    setup: *const fn (*DataSet, Params) void,
};

const stepped_families = [_]Stepped{
    .{ .name = "ContainsHit", .per_value = true, .setup = setupStepped, .variants = &.{
        .{ .impl = .zroar, .func = containsHitZroar },
        .{ .impl = .r64, .func = containsHitR64 },
    } },
    .{ .name = "ContainsMiss", .per_value = true, .setup = setupStepped, .variants = &.{
        .{ .impl = .zroar, .func = containsMissZroar },
        .{ .impl = .r64, .func = containsMissR64 },
    } },
    .{ .name = "Insert", .per_value = false, .setup = setupParams, .variants = &.{
        .{ .impl = .zroar, .func = insertZroar },
        .{ .impl = .r64, .func = insertR64 },
    } },
    .{ .name = "Remove", .per_value = false, .setup = setupParams, .variants = &.{
        .{ .impl = .zroar, .func = removeZroar },
        .{ .impl = .r64, .func = removeR64 },
    } },
    .{ .name = "Serialize", .per_value = false, .setup = setupSerialized, .variants = &.{
        .{ .impl = .zroar, .func = serializeZroar },
        .{ .impl = .r64, .func = serializeR64 },
        .{ .impl = .r64_frozen, .func = serializeR64Frozen },
    } },
    .{ .name = "Deserialize", .per_value = false, .setup = setupSerialized, .variants = &.{
        .{ .impl = .zroar, .func = deserializeZroar },
        .{ .impl = .r64, .func = deserializeR64 },
        .{ .impl = .r64_frozen, .func = deserializeR64Frozen },
    } },
};

const Masked = struct { name: []const u8, variants: []const Variant };

const masked_families = [_]Masked{
    .{ .name = "ContainsRandom", .variants = &.{
        .{ .impl = .zroar, .func = containsRandomZroar },
        .{ .impl = .r64, .func = containsRandomR64 },
    } },
    .{ .name = "InsertRemoveRandom", .variants = &.{
        .{ .impl = .zroar, .func = insertRemoveRandomZroar },
        .{ .impl = .r64, .func = insertRemoveRandomR64 },
    } },
};

const synthetic_rows: []const Row = blk: {
    // Two hundred names formatted at comptime outrun the default quota.
    @setEvalBranchQuota(1_000_000);
    var out: []const Row = &.{};
    for (stepped_families) |fam| {
        for (grid_counts) |count| {
            for (grid_steps) |step| {
                out = out ++ &[_]Row{.{
                    .name = std.fmt.comptimePrint("{s}/{d}/{s}", .{ fam.name, count, stepLabel(step) }),
                    .suite = .synthetic,
                    .variants = fam.variants,
                    .ops = if (fam.per_value) count else 1,
                    .params = .{ .count = count, .step = step },
                    .setup = fam.setup,
                    .teardown = teardownSynth,
                }};
            }
        }
    }
    for (masked_families) |fam| {
        for (bitmasks, 0..) |mask, i| {
            out = out ++ &[_]Row{.{
                .name = std.fmt.comptimePrint("{s}/{d}", .{ fam.name, i }),
                .suite = .synthetic,
                .variants = fam.variants,
                .ops = random_probes,
                .params = .{ .mask = mask },
                .setup = setupRandom,
                .teardown = teardownSynth,
            }};
        }
    }
    break :blk out;
};

fn setupParams(ds: *DataSet, p: Params) void {
    ds.synth.reset();
    ds.synth.count = p.count;
    ds.synth.step = p.step;
}

fn setupStepped(ds: *DataSet, p: Params) void {
    ds.synth.buildStepped(p.count, p.step) catch @panic("out of memory");
}

fn setupSerialized(ds: *DataSet, p: Params) void {
    ds.synth.buildStepped(p.count, p.step) catch @panic("out of memory");
    ds.synth.serialize() catch @panic("out of memory");
    ds.synth.checkSerialized() catch |err|
        std.debug.panic("synthetic shape {d}/{d} does not round-trip: {s}", .{ p.count, p.step, @errorName(err) });
}

fn setupRandom(ds: *DataSet, p: Params) void {
    ds.synth.buildRandom(p.mask) catch @panic("out of memory");
}

fn teardownSynth(ds: *DataSet) void {
    ds.synth.reset();
}

/// One pass over the shape's own values, in order, as their loop cycles.
fn containsHitZroar(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = &s.zr.?;
    var hits: u64 = 0;
    for (0..s.count) |i| {
        if (bm.contains(@as(u64, i) *% s.step)) hits += 1;
    }
    return hits;
}

fn containsHitR64(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = s.r64.?;
    var hits: u64 = 0;
    for (0..s.count) |i| {
        if (bm.contains(@as(u64, i) *% s.step)) hits += 1;
    }
    return hits;
}

/// Probes `(i + 1) * step - 1`: the value just below each present one. With
/// step 1 that is the present value itself, so that column of the grid hits;
/// theirs does too, and the row is kept as they wrote it.
fn containsMissZroar(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = &s.zr.?;
    var hits: u64 = 0;
    for (0..s.count) |i| {
        if (bm.contains((@as(u64, i) + 1) *% s.step -% 1)) hits += 1;
    }
    return hits;
}

fn containsMissR64(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = s.r64.?;
    var hits: u64 = 0;
    for (0..s.count) |i| {
        if (bm.contains((@as(u64, i) + 1) *% s.step -% 1)) hits += 1;
    }
    return hits;
}

/// Build the shape from nothing, one value at a time, and drop it.
fn insertZroar(ds: *DataSet) u64 {
    const s = &ds.synth;
    var bm = zroar.Bitmap.init(ds.allocator) catch unreachable;
    defer bm.deinit();
    for (0..s.count) |i| _ = bm.set(@as(u64, i) *% s.step) catch unreachable;
    return bm.getCardinality();
}

fn insertR64(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = Bitmap64.create() catch unreachable;
    defer bm.free();
    for (0..s.count) |i| bm.add(@as(u64, i) *% s.step);
    return bm.cardinality();
}

/// Remove every value from a freshly built shape. Building it and dropping it
/// are excluded from the timing, as they are under CRoaring's PauseTiming.
fn removeZroar(ds: *DataSet) u64 {
    const s = &ds.synth;
    var t = excludeStart(ds);
    var bm = zroar.Bitmap.init(ds.allocator) catch unreachable;
    for (0..s.count) |i| _ = bm.set(@as(u64, i) *% s.step) catch unreachable;
    excludeEnd(ds, t);

    for (0..s.count) |i| _ = bm.remove(@as(u64, i) *% s.step);
    const marker = bm.getCardinality();

    t = excludeStart(ds);
    bm.deinit();
    excludeEnd(ds, t);
    return marker;
}

fn removeR64(ds: *DataSet) u64 {
    const s = &ds.synth;
    var t = excludeStart(ds);
    const bm = Bitmap64.create() catch unreachable;
    for (0..s.count) |i| bm.add(@as(u64, i) *% s.step);
    excludeEnd(ds, t);

    for (0..s.count) |i| bm.remove(@as(u64, i) *% s.step);
    const marker = bm.cardinality();

    t = excludeStart(ds);
    bm.free();
    excludeEnd(ds, t);
    return marker;
}

/// Write the shape into a buffer that already holds its serialized size.
/// zroar's serialized form is its buffer, so this is a copy of it; borrowing
/// it (`toBuffer`) would be O(1) and is not what CRoaring's rows measure.
fn serializeZroar(ds: *DataSet) u64 {
    const s = &ds.synth;
    const dest = s.zr_dest.?;
    @memcpy(dest, s.zr.?.toBuffer());
    std.mem.doNotOptimizeAway(dest[0]);
    return 1;
}

fn serializeR64(ds: *DataSet) u64 {
    const s = &ds.synth;
    std.mem.doNotOptimizeAway(s.r64.?.portableSerialize(s.r64_portable_dest.?));
    return 1;
}

fn serializeR64Frozen(ds: *DataSet) u64 {
    const s = &ds.synth;
    std.mem.doNotOptimizeAway(s.r64.?.frozenSerialize(s.r64_frozen_dest.?));
    return 1;
}

/// Open the serialized shape and drop it again. This is the row zroar exists
/// for: `fromBuffer` is a pointer cast, so the marker keeps it from folding
/// away entirely.
fn deserializeZroar(ds: *DataSet) u64 {
    var bm = zroar.Bitmap.fromBuffer(ds.allocator, ds.synth.zr_buf.?) catch unreachable;
    std.mem.doNotOptimizeAway(bm.data.ptr);
    bm.deinit();
    return 1;
}

fn deserializeR64(ds: *DataSet) u64 {
    const bm = Bitmap64.portableDeserializeSafe(ds.synth.r64_portable_buf.?) catch unreachable;
    bm.free();
    return 1;
}

fn deserializeR64Frozen(ds: *DataSet) u64 {
    const bm = Bitmap64.frozenView(ds.synth.r64_frozen_buf.?) catch unreachable;
    bm.free();
    return 1;
}

/// `random_probes` draws under the mask against the 2^20-draw shape. Each side
/// draws from its own generator; the two are seeded alike, so the k-th call
/// on either side asks the same questions.
fn containsRandomZroar(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = &s.zr.?;
    const rnd = s.prng_zr.random();
    var hits: u64 = 0;
    for (0..random_probes) |_| {
        if (bm.contains(rnd.int(u64) & s.mask)) hits += 1;
    }
    return hits;
}

fn containsRandomR64(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = s.r64.?;
    const rnd = s.prng_r64.random();
    var hits: u64 = 0;
    for (0..random_probes) |_| {
        if (bm.contains(rnd.int(u64) & s.mask)) hits += 1;
    }
    return hits;
}

/// `random_probes` pairs of add one draw, remove another, against the shape,
/// which keeps changing across calls as theirs does. The marker is the
/// cardinality afterwards, which the two sides must agree on.
fn insertRemoveRandomZroar(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = &s.zr.?;
    const rnd = s.prng_zr.random();
    for (0..random_probes) |_| {
        const v1 = rnd.int(u64) & s.mask;
        const v2 = rnd.int(u64) & s.mask;
        _ = bm.set(v1) catch unreachable;
        _ = bm.remove(v2);
    }
    return bm.getCardinality();
}

fn insertRemoveRandomR64(ds: *DataSet) u64 {
    const s = &ds.synth;
    const bm = s.r64.?;
    const rnd = s.prng_r64.random();
    for (0..random_probes) |_| {
        const v1 = rnd.int(u64) & s.mask;
        const v2 = rnd.int(u64) & s.mask;
        bm.add(v1);
        bm.remove(v2);
    }
    return bm.cardinality();
}

// ---------------------------------------------------------------------------
// Suite `cold`: the open axis.
//
// `Cold<row>` is the realdata row with every bitmap opened from its serialized
// form inside the call and released after: what a posting-list store does per
// query. zroar opens by pointer cast; r64 through `portable_deserialize_safe`
// (parse into fresh heap structures) in the `r64` column and `frozen_view`
// (bookkeeping over the buffer, read-only) in the `r64 frozen` column.
// ---------------------------------------------------------------------------

const Format = enum { portable, frozen };

const cold_rows: []const Row = blk: {
    var out: []const Row = &.{};
    for (realdata_ops) |op| {
        out = out ++ &[_]Row{.{
            .name = "Cold" ++ op.name,
            .suite = .cold,
            .variants = &.{
                .{ .impl = .zroar, .func = coldZroar(op.zroar) },
                .{ .impl = .r64, .func = coldR64(op.r64, .portable) },
                .{ .impl = .r64_frozen, .func = coldR64(op.r64, .frozen) },
            },
        }};
    }
    break :blk out;
};

fn coldZroar(comptime op: ZOp) Func {
    return struct {
        fn f(ds: *DataSet) u64 {
            for (ds.zr_open, ds.zr_bufs) |*slot, buf| {
                slot.* = zroar.Bitmap.fromBuffer(ds.allocator, buf) catch unreachable;
            }
            const marker = op(ds, ds.zr_open);
            for (ds.zr_open) |*bm| bm.deinit();
            return marker;
        }
    }.f;
}

fn coldR64(comptime op: ROp, comptime format: Format) Func {
    return struct {
        fn f(ds: *DataSet) u64 {
            switch (format) {
                .portable => for (ds.r64_open, ds.r64_portable_bufs) |*slot, buf| {
                    slot.* = Bitmap64.portableDeserializeSafe(buf) catch unreachable;
                },
                .frozen => for (ds.r64_open, ds.r64_frozen_bufs) |*slot, buf| {
                    slot.* = Bitmap64.frozenView(buf) catch unreachable;
                },
            }
            const marker = op(ds, ds.r64_open);
            for (ds.r64_open) |bm| bm.free();
            return marker;
        }
    }.f;
}

// MixedOLTP: a burst of transactions against one secondary index.
//
// A transaction fetches a posting list from storage, reads and writes it, and
// lets it go, so the open is inside the measurement. Which list a transaction
// touches is chosen in proportion to its size, because a value that matches
// many rows is queried as often as it is large. And the writes append: row-ids
// are handed out in increasing order, so index maintenance always adds a value
// above every value already there, never one in the middle.
//
// A frozen view is read-only, so the frozen column here is the writable
// bitmap a frozen-format user has to make before appending: `frozen_view`
// then `roaring64_bitmap_copy`. That builds the tree and copies the
// containers, as the portable path does, but skips the portable parser —
// whether that is cheaper is what the column measures.

const open_rows: []const Row = cold_rows ++ &[_]Row{.{
    .name = "MixedOLTP",
    .suite = .cold,
    .variants = &.{
        .{ .impl = .zroar, .func = mixedOltpZroar },
        .{ .impl = .r64, .func = mixedOltpR64(.portable) },
        .{ .impl = .r64_frozen, .func = mixedOltpR64(.frozen) },
    },
}};

/// Picks a posting list with probability proportional to its size: a random
/// point in the total cardinality, and the first list whose running total is
/// past it.
fn pickList(ds: *const DataSet, rnd: std.Random) usize {
    const cum = ds.cum_card;
    const point = rnd.uintLessThan(u64, cum[cum.len - 1]);

    var lo: usize = 0;
    var hi: usize = cum.len - 1;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cum[mid] <= point) lo = mid + 1 else hi = mid;
    }
    return lo;
}

fn mixedOltpZroar(ds: *DataSet) u64 {
    var prng = std.Random.DefaultPrng.init(oltp_seed);
    const rnd = prng.random();
    var next_row = ds.row_id_next;

    var marker: u64 = 0;
    var t: usize = 0;
    while (t < oltp_txns) : (t += 1) {
        const list = pickList(ds, rnd);
        // fromBufferCopy, not fromBuffer: the writes below would otherwise land
        // in the shared setup buffer every other row reads.
        var bm = zroar.Bitmap.fromBufferCopy(ds.allocator, ds.zr_bufs[list]) catch unreachable;

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

fn mixedOltpR64(comptime format: Format) Func {
    return struct {
        fn f(ds: *DataSet) u64 {
            var prng = std.Random.DefaultPrng.init(oltp_seed);
            const rnd = prng.random();
            var next_row = ds.row_id_next;

            var marker: u64 = 0;
            var t: usize = 0;
            while (t < oltp_txns) : (t += 1) {
                const list = pickList(ds, rnd);
                const bm = switch (format) {
                    .portable => Bitmap64.portableDeserializeSafe(ds.r64_portable_bufs[list]) catch unreachable,
                    .frozen => blk: {
                        // The view is read-only; the copy is what gets written.
                        const view = Bitmap64.frozenView(ds.r64_frozen_bufs[list]) catch unreachable;
                        defer view.free();
                        break :blk view.copy() catch unreachable;
                    },
                };

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
    }.f;
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// Time a body has asked to keep out of its measurement, accumulated across
/// the calls of one timing loop and subtracted at the end.
var excluded_ns: u64 = 0;

fn excludeStart(ds: *const DataSet) std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(ds.io, .awake);
}

fn excludeEnd(ds: *const DataSet, start: std.Io.Clock.Timestamp) void {
    excluded_ns += @intCast(start.untilNow(ds.io).raw.toNanoseconds());
}

/// One warm-up call, then calls until `target_ns` of wall time have passed;
/// nanoseconds per call, with any excluded time taken out.
fn measure(ds: *DataSet, func: Func, target_ns: u64) f64 {
    var marker_sum: u64 = 0;
    marker_sum +%= func(ds);
    excluded_ns = 0;

    var iterations: u64 = 0;
    var total_ns: u64 = 0;
    const start = std.Io.Clock.Timestamp.now(ds.io, .awake);
    while (true) {
        marker_sum +%= func(ds);
        iterations += 1;
        total_ns = @intCast(start.untilNow(ds.io).raw.toNanoseconds());
        if (total_ns >= target_ns) break;
    }
    // Keeps the accumulated markers, and with them the bodies, alive.
    if (marker_sum == 0xDEADBEEFDEADBEEF) @panic("impossible");

    const measured = total_ns - @min(total_ns, excluded_ns);
    return @as(f64, @floatFromInt(measured)) / @as(f64, @floatFromInt(iterations));
}

const Options = struct {
    suites: std.EnumSet(Suite),
    filter: ?[]const u8,
    target_ns: u64,
    /// Where to write the machine-readable copy of the results, if anywhere.
    out: ?[]const u8,
    /// What the data source is called in that copy.
    dataset: []const u8,
    mode: datasets.Mode,
    machine: Machine,
};

/// What the numbers were taken under. Recorded, not enforced: pinning and
/// frequency policy are the runner's business (bench/run_all.sh pins; the
/// governor and boost need root and are left to the operator). Linux sysfs
/// is the source; elsewhere everything reads "unknown".
const Machine = struct {
    cpu: []const u8 = "unknown",
    governor: []const u8 = "unknown",
    boost: []const u8 = "unknown",
    smt: []const u8 = "unknown",
    /// The CPUs this process may run on, as `taskset` would print them.
    cpus: []const u8 = "unknown",

    fn read(io: std.Io, allocator: std.mem.Allocator) Machine {
        var m: Machine = .{};
        if (builtin.os.tag != .linux) return m;

        if (readTrimmed(io, allocator, "/proc/cpuinfo")) |info| {
            if (std.mem.indexOf(u8, info, "model name")) |i| {
                const line = info[i..];
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse 0;
                const end = std.mem.indexOfScalar(u8, line, '\n') orelse line.len;
                m.cpu = std.mem.trim(u8, line[colon + 1 .. end], " \t");
            }
        }

        var first_cpu: usize = 0;
        if (std.posix.sched_getaffinity(0)) |set| {
            m.cpus = formatCpuSet(allocator, set) catch "unknown";
            first_cpu = firstBit(set);
        } else |_| {}

        const gov_path = std.fmt.allocPrint(
            allocator,
            "/sys/devices/system/cpu/cpu{d}/cpufreq/scaling_governor",
            .{first_cpu},
        ) catch "";
        if (readTrimmed(io, allocator, gov_path)) |g| m.governor = g;
        if (readTrimmed(io, allocator, "/sys/devices/system/cpu/cpufreq/boost")) |b| {
            m.boost = if (std.mem.eql(u8, b, "1")) "on" else "off";
        }
        if (readTrimmed(io, allocator, "/sys/devices/system/cpu/smt/active")) |v| {
            m.smt = if (std.mem.eql(u8, v, "1")) "on" else "off";
        }
        return m;
    }

    /// Streamed rather than size-hinted: /proc and /sys files report size 0.
    fn readTrimmed(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
        if (path.len == 0) return null;
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return null;
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &buf);
        const bytes = reader.interface.allocRemaining(allocator, .limited(1 << 20)) catch return null;
        return std.mem.trim(u8, bytes, " \t\r\n");
    }

    fn firstBit(set: std.posix.cpu_set_t) usize {
        for (set, 0..) |word, w| {
            if (word != 0) return w * @bitSizeOf(usize) + @ctz(word);
        }
        return 0;
    }

    /// "3", "0-31", "2,4-7": runs of set bits, comma separated.
    fn formatCpuSet(allocator: std.mem.Allocator, set: std.posix.cpu_set_t) ![]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        const total = set.len * @bitSizeOf(usize);
        var i: usize = 0;
        while (i < total) : (i += 1) {
            if (!isSet(set, i)) continue;
            var j = i;
            while (j + 1 < total and isSet(set, j + 1)) j += 1;
            if (out.items.len > 0) try out.append(allocator, ',');
            var buf: [32]u8 = undefined;
            const piece = if (j == i)
                try std.fmt.bufPrint(&buf, "{d}", .{i})
            else
                try std.fmt.bufPrint(&buf, "{d}-{d}", .{ i, j });
            try out.appendSlice(allocator, piece);
            i = j;
        }
        return out.items;
    }

    fn isSet(set: std.posix.cpu_set_t, i: usize) bool {
        const bits = @bitSizeOf(usize);
        return (set[i / bits] >> @intCast(i % bits)) & 1 == 1;
    }
};

/// Per-row results, microseconds per operation, in the table's column order.
const Result = struct {
    row: *const Row,
    us: [3]?f64 = .{ null, null, null },

    fn get(self: Result, impl: Impl) ?f64 {
        return self.us[@intFromEnum(impl)];
    }
};

fn run(ds: *DataSet, opts: Options) !void {
    var results: [rows.len]Result = undefined;
    var n: usize = 0;
    var current: ?Suite = null;

    var out = try Out.open(ds, opts);
    defer out.close();
    try out.meta(ds, opts);

    for (rows) |*row| {
        if (!opts.suites.contains(row.suite)) continue;
        if (opts.filter) |f| if (std.mem.indexOf(u8, row.name, f) == null) continue;

        if (current != row.suite) {
            current = row.suite;
            printHeader(row.suite);
        }

        if (row.setup) |setup| setup(ds, row.params);
        defer if (row.teardown) |teardown| teardown(ds);

        // Every implementation must compute the same answer before any of
        // them is timed.
        const want = row.variants[0].func(ds);
        for (row.variants[1..]) |v| {
            const got = v.func(ds);
            if (got != want) std.debug.panic(
                "{s}: {s} returned {d} but {s} returned {d}",
                .{ row.name, row.variants[0].impl.label(), want, v.impl.label(), got },
            );
        }

        var result: Result = .{ .row = row };
        for (row.variants) |v| {
            const per_call_ns = measure(ds, v.func, opts.target_ns);
            result.us[@intFromEnum(v.impl)] = per_call_ns / @as(f64, @floatFromInt(row.ops)) / std.time.ns_per_us;
        }
        printResult(result);
        try out.result(result);
        results[n] = result;
        n += 1;
    }

    if (n == 0) {
        std.debug.print("no rows selected\n", .{});
        return;
    }
    printSummary(results[0..n], ds);
}

/// The `--out` file: tab-separated, one `meta` line per fact about the run
/// and one `row` line per measurement, so a report can be assembled from any
/// number of runs without parsing the table meant for eyes.
const Out = struct {
    file: ?std.Io.File,
    io: std.Io,
    buf: [4096]u8 = undefined,
    w: std.Io.File.Writer = undefined,

    fn open(ds: *const DataSet, opts: Options) !Out {
        var self: Out = .{ .file = null, .io = ds.io };
        const path = opts.out orelse return self;
        self.file = try std.Io.Dir.cwd().createFile(ds.io, path, .{});
        return self;
    }

    fn close(self: *Out) void {
        const file = self.file orelse return;
        self.w.interface.flush() catch {};
        file.close(self.io);
    }

    fn meta(self: *Out, ds: *const DataSet, opts: Options) !void {
        const file = self.file orelse return;
        self.w = file.writer(self.io, &self.buf);
        const w = &self.w.interface;
        try w.print("meta\tzig\t{s}\n", .{builtin.zig_version_string});
        try w.print("meta\tcroaring\t{s}\n", .{croaring.version});
        try w.print("meta\tcpu\t{s}\n", .{opts.machine.cpu});
        try w.print("meta\tgovernor\t{s}\n", .{opts.machine.governor});
        try w.print("meta\tboost\t{s}\n", .{opts.machine.boost});
        try w.print("meta\tsmt\t{s}\n", .{opts.machine.smt});
        try w.print("meta\tcpus\t{s}\n", .{opts.machine.cpus});
        try w.print("meta\tdataset\t{s}\n", .{opts.dataset});
        try w.print("meta\tmode\t{s}\n", .{@tagName(opts.mode)});
        try w.print("meta\tbitmaps\t{d}\n", .{ds.zr_bms.len});
        try w.print("meta\tvalues\t{d}\n", .{ds.values});
        try w.print("meta\ttarget_ms\t{d}\n", .{opts.target_ns / std.time.ns_per_ms});
        try w.print("meta\tbytes_zroar\t{d}\n", .{ds.zr_bytes});
        try w.print("meta\tbytes_r64\t{d}\n", .{ds.r64_portable_bytes});
        try w.print("meta\tbytes_r64_norun\t{d}\n", .{ds.r64_portable_bytes_norun});
        try w.print("meta\tbytes_r64_frozen\t{d}\n", .{ds.r64_frozen_bytes});
    }

    fn result(self: *Out, r: Result) !void {
        if (self.file == null) return;
        const w = &self.w.interface;
        for (r.row.variants) |v| {
            try w.print("row\t{s}\t{s}\t{s}\t{d}\n", .{
                @tagName(r.row.suite), r.row.name, @tagName(v.impl), r.get(v.impl).?,
            });
        }
    }
};

fn printHeader(suite: Suite) void {
    // What the r64 column holds differs per suite: the bitmaps as CRoaring's
    // bench builds them in memory, or — wherever a buffer is opened or written
    // — CRoaring through its portable format, with frozen alongside.
    const title: []const u8 = switch (suite) {
        .realdata => "CRoaring bench.cpp, 64-bit rows (bitmaps in memory; r64 = as CRoaring's bench builds them)",
        .synthetic => "CRoaring synthetic_bench.cpp, r64 rows (per op where the row is per-op; Serialize/Deserialize: r64 = portable, frozen alongside)",
        .cold => "Open axis: realdata rows with every bitmap opened inside the call (r64 = via portable deserialize, frozen = via frozen_view), and MixedOLTP",
    };
    const r64_label: []const u8 = switch (suite) {
        .realdata => "r64 µs",
        .synthetic, .cold => "portable µs",
    };
    std.debug.print("\n{s}\n", .{title});
    std.debug.print("{s:<44}{s:>14}{s:>14}{s:>11}{s:>14}{s:>11}\n", .{
        "row",
        "zroar µs",
        r64_label,
        "r64/zr",
        "frozen µs",
        "fr/zr",
    });
    std.debug.print("{s}\n", .{"-" ** 108});
}

fn printResult(r: Result) void {
    const zr = r.get(.zroar).?;
    std.debug.print("{s:<44}{d:>14.3}", .{ r.row.name, zr });
    inline for (.{ Impl.r64, Impl.r64_frozen }) |impl| {
        if (r.get(impl)) |us| {
            const ratio = us / zr;
            // Two decimals matter around 1x and only clutter at 1000x.
            if (ratio < 100) {
                std.debug.print("{d:>14.3}{d:>10.2}x", .{ us, ratio });
            } else {
                std.debug.print("{d:>14.3}{d:>10.0}x", .{ us, ratio });
            }
        } else {
            std.debug.print("{s:>14}{s:>11}", .{ "-", "" });
        }
    }
    std.debug.print("\n", .{});
}

/// Rows where zroar was faster than each r64 column, out of the rows that had
/// that column, and the serialized sizes of the per-file set.
fn printSummary(results: []const Result, ds: *const DataSet) void {
    std.debug.print("\n", .{});
    inline for (.{ Impl.r64, Impl.r64_frozen }) |impl| {
        var faster: usize = 0;
        var total: usize = 0;
        for (results) |r| {
            const other = r.get(impl) orelse continue;
            total += 1;
            if (r.get(.zroar).? < other) faster += 1;
        }
        if (total > 0) std.debug.print(
            "zroar faster than {s} on {d} of {d} rows\n",
            .{ impl.label(), faster, total },
        );
    }
    const zr: f64 = @floatFromInt(ds.zr_bytes);
    std.debug.print(
        "per-file set serialized: zroar {d} bytes; r64 portable {d} ({d:.2}x of zroar); r64 frozen {d} ({d:.2}x)\n",
        .{
            ds.zr_bytes,
            ds.r64_portable_bytes,
            @as(f64, @floatFromInt(ds.r64_portable_bytes)) / zr,
            ds.r64_frozen_bytes,
            @as(f64, @floatFromInt(ds.r64_frozen_bytes)) / zr,
        },
    );
}

const usage =
    \\usage: bench [data_dir] [--oltp] [--suite realdata|synthetic|cold]...
    \\             [-b|--bench <substring>] [--time <ms>] [--out <tsv>]
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // CRoaring allocates through libc, so zroar has to as well: otherwise the
    // comparison includes a difference in allocators.
    const allocator = std.heap.c_allocator;

    const args = try init.minimal.args.toSlice(allocator);
    defer allocator.free(args);

    var dir_path: []const u8 = default_data_dir;
    var mode: datasets.Mode = .realdata;
    var opts: Options = .{
        .suites = std.EnumSet(Suite).initEmpty(),
        .filter = null,
        .target_ns = default_target_ms * std.time.ns_per_ms,
        .out = null,
        .dataset = undefined,
        .mode = undefined,
        .machine = Machine.read(io, allocator),
    };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "-b") or std.mem.eql(u8, a, "--bench")) {
            i += 1;
            if (i >= args.len) return fail("-b needs a substring");
            opts.filter = args[i];
        } else if (std.mem.eql(u8, a, "--suite")) {
            i += 1;
            if (i >= args.len) return fail("--suite needs a name");
            const suite = std.meta.stringToEnum(Suite, args[i]) orelse
                return fail("unknown suite; one of realdata, synthetic, cold");
            opts.suites.insert(suite);
        } else if (std.mem.eql(u8, a, "--time")) {
            i += 1;
            if (i >= args.len) return fail("--time needs milliseconds");
            const ms = std.fmt.parseInt(u64, args[i], 10) catch return fail("--time needs milliseconds");
            opts.target_ns = ms * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, a, "--out")) {
            i += 1;
            if (i >= args.len) return fail("--out needs a path");
            opts.out = args[i];
        } else if (std.mem.eql(u8, a, "--oltp")) {
            mode = .oltp;
        } else if (a.len > 0 and a[0] == '-') {
            return fail("unknown option");
        } else {
            dir_path = a;
        }
    }
    if (opts.suites.count() == 0) opts.suites = std.EnumSet(Suite).initFull();
    opts.mode = mode;
    opts.dataset = switch (mode) {
        .realdata => std.fs.path.basename(dir_path),
        .oltp => "oltp",
    };

    const source: []const u8 = switch (mode) {
        .realdata => dir_path,
        .oltp => "oltp (auto-increment row-ids)",
    };
    std.debug.print(
        "zroar bench: zig {s}, CRoaring {s}\nmachine: {s}; governor {s}, boost {s}, smt {s}, cpus {s}\ndata source: {s}\n",
        .{
            builtin.zig_version_string, croaring.version, opts.machine.cpu,  opts.machine.governor,
            opts.machine.boost,         opts.machine.smt, opts.machine.cpus, source,
        },
    );
    var ds = datasets.load(io, allocator, dir_path, mode) catch |err| {
        std.debug.print("failed to load the data set: {s}\n{s}", .{ @errorName(err), usage });
        return err;
    };
    defer ds.deinit();

    datasets.checkFiles(&ds);
    try run(&ds, opts);
}

fn fail(msg: []const u8) error{BadArguments} {
    std.debug.print("{s}\n{s}", .{ msg, usage });
    return error.BadArguments;
}
