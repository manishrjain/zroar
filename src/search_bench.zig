// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! Benchmarks for the two search paths: `Keys.search` over the keys node, and
//! `container.array.find` over an array container's values.
//!
//! Both bisect down to a small window and then scan it, and how well that pays
//! depends on something a single number would hide: how predictable the lookups
//! are. Bisecting is a chain of dependent loads, so its cost is latency that
//! speculation erases once the branch predictor has learnt the path. A scan has
//! no chain, but its comparisons are work that cannot be speculated away. So a
//! repetitive probe stream favours bisecting and a random one favours scanning,
//! and the cutoffs are a compromise between them.
//!
//! Each search is therefore measured under three probe streams:
//!
//!   random    a new value every probe -- an index lookup driven by query
//!             values the cache and predictor have not seen
//!   hot-1024  a fixed 1024-value array, replayed
//!   hot-3     three fixed values, replayed -- the degenerate best case for
//!             bisecting, and the worst case for scanning
//!
//! Every table also reports a plain bisect, compiled in here as a reference, so
//! a run shows directly whether the cutoffs are still earning their keep on the
//! machine in front of you.
//!
//! Several scan windows are swept side by side, the shipping one among them
//! and marked, so a run answers both "is the scan still worth it" and "is the
//! cutoff still right" without rebuilding.
//!
//! Everything is reported in nanoseconds rather than ratios. A ratio makes
//! speeding up a cheap lookup look as valuable as speeding up an expensive
//! one, and it is not: 1.5x on a 7 ns lookup saves 4 ns, while 1.7x on a 27 ns
//! lookup saves 12 ns. Only nanoseconds accumulate into a workload.
//!
//! Run with `zig build searchbench`. Use `-Doptimize=ReleaseFast`; the numbers
//! are meaningless otherwise.

const std = @import("std");
const zroar = @import("zroar.zig");
const keys_mod = @import("keys.zig");
const container = @import("container.zig");
const stats_mod = @import("stats.zig");

const probes = 200_000;

var io_g: std.Io = undefined;

fn now() std.Io.Clock.Timestamp {
    return std.Io.Clock.Timestamp.now(io_g, .awake);
}

fn since(t: std.Io.Clock.Timestamp) u64 {
    return @intCast(t.untilNow(io_g).raw.toNanoseconds());
}

fn nsPer(ns: u64, count: usize) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(count));
}

const Regime = enum {
    fresh,
    cyc1024,
    cyc3,

    fn label(self: Regime) []const u8 {
        return switch (self) {
            .fresh => "random",
            .cyc1024 => "hot-1024",
            .cyc3 => "hot-3",
        };
    }
};

/// Signed nanoseconds, e.g. "-8.03" or "+4.04".
fn deltaStr(buf: []u8, d: f64) []const u8 {
    const sign: u8 = if (d < 0) '-' else '+';
    return std.fmt.bufPrint(buf, "{c}{d:.2}", .{ sign, @abs(d) }) catch "?";
}

/// Scan windows swept side by side. The shipping constant is among them, and
/// is marked in the output, so a run answers both "is the scan still worth it"
/// and "is the cutoff still the right one" without rebuilding.
const key_windows = [_]usize{ 8, 16, 32 };
const value_windows = [_]usize{ 64, 128, 256 };

/// Per-window delta totals, one instance per swept window.
///
/// Accumulates nanoseconds gained or lost against a plain bisect, NOT ratios.
/// A ratio treats speeding up an already-cheap lookup as equal to speeding up
/// an expensive one, which is the wrong way round: 1.5x on a 7 ns lookup is
/// 4 ns, while 1.7x on a 27 ns lookup is 12 ns. Only nanoseconds accumulate
/// into a workload.
///
/// Deliberately no grand total across streams. Summing them would assert that
/// the workload is a third random, a third hot-1024 and a third hot-3 — a
/// made-up workload wearing the clothes of a measurement, when hot-3 is a
/// stress case no index actually sees. What can be said without inventing a
/// workload is where the boundary lies, which is what "flips at" reports.
///
/// The means weight every size equally, which no real posting-list
/// distribution does, so read them as a summary of the columns above rather
/// than a prediction.
const WindowStats = struct {
    sum: [3]f64 = .{ 0, 0, 0 }, // per-stream delta totals, indexed by Regime
    n: [3]usize = .{ 0, 0, 0 },

    fn note(self: *WindowStats, delta: f64, r: Regime) void {
        self.sum[@intFromEnum(r)] += delta;
        self.n[@intFromEnum(r)] += 1;
    }

    fn mean(self: *const WindowStats, r: Regime) f64 {
        const i = @intFromEnum(r);
        if (self.n[i] == 0) return 0;
        return self.sum[i] / @as(f64, @floatFromInt(self.n[i]));
    }
};

/// One table header, listing a column per swept window and marking the one
/// this build ships.
fn printHeader(
    name: []const u8,
    what: []const u8,
    unit: []const u8,
    shipping: usize,
    windows: []const usize,
) void {
    std.debug.print("\n{s} — {s}\n  windows swept:", .{ name, what });
    for (windows) |w| {
        const mark: []const u8 = if (w == shipping) " (this build)" else "";
        std.debug.print(" {d}{s}", .{ w, mark });
    }
    std.debug.print(
        "\n\n{s:>7} {s:>10} {s:>14}",
        .{ unit, "lookups", "bisect" },
    );
    var b: [16]u8 = undefined;
    for (windows) |w| {
        const h = std.fmt.bufPrint(&b, "win={d}", .{w}) catch "win";
        std.debug.print(" {s:>11}", .{h});
    }
    std.debug.print("   {s}\n", .{"best"});
}

/// One row: the reference, then each window's time, then which window won.
/// Times carry their delta against the reference, since that is the figure
/// that accumulates.
fn printRow(size: usize, r: Regime, ref: f64, res: []const f64) void {
    std.debug.print("{d:>7} {s:>10} {d:>11.2} ns", .{ size, r.label(), ref });
    var best: usize = 0;
    for (res, 0..) |v, i| {
        if (v < res[best]) best = i;
    }
    var b: [24]u8 = undefined;
    for (res) |v| {
        const s = std.fmt.bufPrint(&b, "{d:.2}", .{v}) catch "?";
        std.debug.print(" {s:>11}", .{s});
    }
    var db: [32]u8 = undefined;
    std.debug.print("   {s} ns\n", .{deltaStr(&db, res[best] - ref)});
}

/// Per-window summaries, so the cutoff choice is visible as a curve rather
/// than a single verdict.
fn reportWindows(
    ext: []const WindowStats,
    unit: []const u8,
    shipping: usize,
    windows: []const usize,
) void {
    std.debug.print(
        "\n  {s:>6} {s:>12} {s:>12} {s:>12} {s:>10}\n",
        .{ "window", "random", "hot-1024", "hot-3", "flips at" },
    );
    for (windows, ext) |w, e| {
        const rnd = e.mean(.fresh);
        const hot = e.mean(.cyc3);
        var fb: [16]u8 = undefined;
        const flip = if (rnd >= 0)
            "never"
        else if (hot <= 0)
            "always"
        else
            std.fmt.bufPrint(&fb, "{d:.0}%", .{
                -rnd / (hot - rnd) * 100.0,
            }) catch
                "?";
        const mark: []const u8 = if (w == shipping) " <- this build" else "";
        std.debug.print(
            "  {d:>6} {d:>9.2} ns {d:>9.2} ns {d:>9.2} ns {s:>10}{s}\n",
            .{ w, rnd, e.mean(.cyc1024), hot, flip, mark },
        );
    }
    std.debug.print(
        "  mean ns/lookup against a plain bisect, over all {s} sizes;" ++
            " lower is better.\n" ++
            "  \"flips at\" is the share of lookups that would have to" ++
            " repeat" ++
            " a 3-value\n  hot set before that window is a net loss.\n",
        .{unit},
    );
}

/// The probe array a regime replays. The cyclic regimes deliberately return a
/// *small* slice for the caller to walk repeatedly: expanding the repeats into
/// one long array would change the memory behaviour of the probe stream itself
/// and measure something else.
fn cycleU64(buf: []u64, rnd: std.Random, num_keys: usize, r: Regime) []u64 {
    switch (r) {
        .fresh => {
            for (buf) |*p| p.* = rnd.uintLessThan(u64, num_keys) << 16;
            return buf;
        },
        .cyc1024 => {
            const c = buf[0..1024];
            for (c) |*p| p.* = rnd.uintLessThan(u64, num_keys) << 16;
            return c;
        },
        .cyc3 => {
            const max = (num_keys - 1) << 16;
            const c = buf[0..3];
            c[0] = (max / 4) & keys_mod.key_mask;
            c[1] = (max / 2) & keys_mod.key_mask;
            c[2] = (max - max / 4) & keys_mod.key_mask;
            return c;
        },
    }
}

fn cycleU16(buf: []u16, rnd: std.Random, r: Regime) []u16 {
    switch (r) {
        .fresh => {
            for (buf) |*p| p.* = rnd.int(u16);
            return buf;
        },
        .cyc1024 => {
            const c = buf[0..1024];
            for (c) |*p| p.* = rnd.int(u16);
            return c;
        },
        .cyc3 => {
            const c = buf[0..3];
            c[0] = 0xFFFF / 4;
            c[1] = 0xFFFF / 2;
            c[2] = 0xFFFF - 0xFFFF / 4;
            return c;
        },
    }
}

// ---------------------------------------------------------------------------
// Keys node.
// ---------------------------------------------------------------------------

/// Plain bisect over the keys node, as `Keys.search` was before the scan
/// window. Kept only as the reference the table compares against.
fn keysBisect(ks: keys_mod.Keys, k: u64) usize {
    var lo: usize = 0;
    var hi: usize = ks.numKeys();
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (ks.n[keys_mod.index_node_start + 2 * mid] < k) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

// Primes, not powers of two: a round size divides evenly by the scan's vector
// width and halves cleanly all the way down, so the tail loop never runs and
// every bisect lands on a boundary. That flatters both searches and hides the
// remainder handling. 153 is the exception, kept because it is the real shape
// — a posting list spread over a 10M-row table, which is what the OLTP
// benchmarks build.
const key_counts = [_]usize{
    17,   61,    153,   1021,  4099,
    8191, 16381, 32749, 65521,
};

fn benchKeys(a: std.mem.Allocator, rnd: std.Random, buf: []u64) !void {
    printHeader(
        "Keys.search",
        "locate a key in the keys node",
        "keys",
        keys_mod.scan_max_keys,
        &key_windows,
    );

    // Rows are grouped by lookup stream, so every node is visited once per
    // stream. Building them up front keeps that from rebuilding each one three
    // times.
    var bms: [key_counts.len]zroar.Bitmap = undefined;
    var built: usize = 0;
    defer for (bms[0..built]) |*bm| bm.deinit();
    for (key_counts, 0..) |nk, i| {
        bms[i] = try zroar.Bitmap.init(a);
        built = i + 1;
        var j: u64 = 0;
        while (j < nk) : (j += 1) _ = try bms[i].set(j << 16);
    }

    var ext = [_]WindowStats{.{}} ** key_windows.len;
    for ([_]Regime{ .fresh, .cyc1024, .cyc3 }, 0..) |r, ri| {
        if (ri > 0) std.debug.print("\n", .{});
        for (key_counts, 0..) |nk, bi| {
            const ks = bms[bi].keys();
            const num = ks.numKeys();
            const cycle = cycleU64(buf, rnd, nk, r);
            const reps = probes / cycle.len;
            const total = reps * cycle.len;

            var sink: usize = 0;
            var t = now();
            for (0..reps) |_| {
                for (cycle) |p| sink +%= keysBisect(ks, p);
            }
            const ref = nsPer(since(t), total);

            var res: [key_windows.len]f64 = undefined;
            inline for (key_windows, 0..) |w, wi| {
                for (cycle) |p| {
                    if (ks.searchWindow(w, p) != keysBisect(ks, p)) {
                        std.debug.print("MISMATCH at key {d}\n", .{p});
                        return error.SearchMismatch;
                    }
                }
                t = now();
                for (0..reps) |_| {
                    for (cycle) |p| sink +%= ks.searchWindow(w, p);
                }
                res[wi] = nsPer(since(t), total);
                ext[wi].note(res[wi] - ref, r);
            }
            std.mem.doNotOptimizeAway(sink);
            printRow(num, r, ref, &res);
        }
    }
    reportWindows(&ext, "keys", keys_mod.scan_max_keys, &key_windows);
}

// ---------------------------------------------------------------------------
// Array container.
// ---------------------------------------------------------------------------

/// Plain bisect over an array container's values, as `array.find` was before
/// the scan window.
fn arrayBisect(c: []const u16, x: u16) usize {
    const vals = container.array.values(c);
    var lo: usize = 0;
    var hi: usize = vals.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (vals[mid] < x) lo = mid + 1 else hi = mid;
    }
    return lo;
}

/// A real array container holding `n` values spread over the 16-bit range,
/// built through the shipping API so header and payload are exactly what the
/// library would produce.
fn buildArray(a: std.mem.Allocator, n: usize) ![]u16 {
    // The counters are not what this benchmark measures; discard them.
    var sink: stats_mod.Sink = .{};
    const words = container.start_idx + n + 1; // +1 for the free slot
    const c = try a.alignedAlloc(u16, .@"8", words);
    @memset(c, 0);
    c[container.index_size] = @intCast(words);
    container.setType(c, .array);
    container.setCardinality(c, 0);
    const stride = @as(usize, 1 << 16) / n;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        std.debug.assert(container.array.add(c, @intCast(i * stride), &sink));
    }
    return c;
}

// Primes again, for the reason above — and here it matters more, since the
// scan is 16 values wide and a round cardinality would never exercise the
// remainder. 2039 is the largest prime that still fits an array container,
// which converts to a bitmap past max_array_values.
const card_counts = [_]usize{ 5, 17, 61, 127, 251, 509, 1021, 2039 };

fn benchArray(a: std.mem.Allocator, rnd: std.Random, buf: []u16) !void {
    printHeader(
        "array.find",
        "locate a value inside one array container",
        "values",
        container.array.scan_max_values,
        &value_windows,
    );

    var cs: [card_counts.len][]u16 = undefined;
    var built: usize = 0;
    defer for (cs[0..built]) |c| a.free(c);
    for (card_counts, 0..) |n, i| {
        cs[i] = try buildArray(a, n);
        built = i + 1;
    }

    var ext = [_]WindowStats{.{}} ** value_windows.len;
    for ([_]Regime{ .fresh, .cyc1024, .cyc3 }, 0..) |r, ri| {
        if (ri > 0) std.debug.print("\n", .{});
        // One probe stream per regime, shared by every cardinality, so the
        // rows in a group differ only in container size.
        const cycle = cycleU16(buf, rnd, r);
        const reps = probes / cycle.len;
        const total = reps * cycle.len;
        for (card_counts, 0..) |n, ci| {
            const c = cs[ci];

            var sink: usize = 0;
            var t = now();
            for (0..reps) |_| {
                for (cycle) |p| sink +%= arrayBisect(c, p);
            }
            const ref = nsPer(since(t), total);

            var res: [value_windows.len]f64 = undefined;
            inline for (value_windows, 0..) |w, wi| {
                for (cycle) |p| {
                    if (container.array.findWindow(w, c, p) !=
                        arrayBisect(c, p))
                    {
                        std.debug.print("MISMATCH at value {d}\n", .{p});
                        return error.FindMismatch;
                    }
                }
                t = now();
                for (0..reps) |_| {
                    for (cycle) |p| {
                        sink +%= container.array.findWindow(w, c, p);
                    }
                }
                res[wi] = nsPer(since(t), total);
                ext[wi].note(res[wi] - ref, r);
            }
            std.mem.doNotOptimizeAway(sink);
            printRow(n, r, ref, &res);
        }
    }
    reportWindows(
        &ext,
        "values",
        container.array.scan_max_values,
        &value_windows,
    );
}

pub fn main(init: std.process.Init) !void {
    io_g = init.io;
    const a = std.heap.c_allocator;

    var prng = std.Random.DefaultPrng.init(0x5EA5_C4ED);
    const rnd = prng.random();

    const u64_buf = try a.alloc(u64, probes);
    defer a.free(u64_buf);
    const u16_buf = try a.alloc(u16, probes);
    defer a.free(u16_buf);

    std.debug.print(
        \\zroar search benchmark
        \\
        \\Both searches bisect until few enough entries remain, then scan them.
        \\Each row times that against a plain bisect over the same data, so a
        \\run shows directly whether the scan window still pays here.
        \\
        \\Which one wins depends on whether lookups repeat. Bisecting is a chain
        \\of dependent loads, and the CPU only runs that chain fast when it can
        \\predict which way each step goes — which it learns from repetition.
        \\Scanning has no chain, but its comparisons are work no prediction can
        \\skip. So the "lookups" column is the thing that decides each row:
        \\
        \\  random     a different lookup value every time, never repeating
        \\  hot-1024   1024 distinct values, looked up over and over
        \\  hot-3      3 values, looked up over and over
        \\
        \\random and hot-3 are the extremes, not predictions: a real query
        \\stream sits between them. hot-3 is deliberately the best possible
        \\case for bisecting and the worst for scanning.
        \\
        \\Times are nanoseconds per lookup; the best column is the winning
        \\window's saving against the bisect. Speeding up a lookup that was
        \\already cheap is worth less than speeding up an expensive one, so
        \\weigh nanoseconds rather than ratios.
        \\
    , .{});

    try benchKeys(a, rnd, u64_buf);
    try benchArray(a, rnd, u16_buf);
}
