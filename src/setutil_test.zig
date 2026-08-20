// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! Unit tests for `setutil.zig`: the union, intersection and difference kernels
//! over the sorted u16 payloads of array containers.

const std = @import("std");
const setutil = @import("setutil.zig");

const testing = std.testing;

// The kernels under test, aliased so the test bodies read as they would inside
// setutil.zig itself.
const union2by2 = setutil.union2by2;
const intersection2by2 = setutil.intersection2by2;
const localintersect2by2 = setutil.localintersect2by2;
const onesidedgallopingintersect2by2 = setutil.onesidedgallopingintersect2by2;
const intersection2by2Cardinality = setutil.intersection2by2Cardinality;
const localintersect2by2Cardinality = setutil.localintersect2by2Cardinality;
const onesidedgallopingintersect2by2Cardinality =
    setutil.onesidedgallopingintersect2by2Cardinality;
const advanceUntil = setutil.advanceUntil;
const difference = setutil.difference;

test "union2by2 empty inputs" {
    var buf: [8]u16 = undefined;
    const a = [_]u16{ 1, 3, 5 };

    try testing.expectEqual(@as(usize, 0), union2by2(&.{}, &.{}, &buf));
    try testing.expectEqual(@as(usize, 3), union2by2(&a, &.{}, &buf));
    try testing.expectEqualSlices(u16, &a, buf[0..3]);
    try testing.expectEqual(@as(usize, 3), union2by2(&.{}, &a, &buf));
    try testing.expectEqualSlices(u16, &a, buf[0..3]);
}

test "union2by2 disjoint, identical, subset" {
    var buf: [16]u16 = undefined;
    const a = [_]u16{ 1, 3, 5, 7 };
    const b = [_]u16{ 2, 4, 6, 8 };

    try testing.expectEqual(@as(usize, 8), union2by2(&a, &b, &buf));
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, buf[0..8]);

    try testing.expectEqual(@as(usize, 4), union2by2(&a, &a, &buf));
    try testing.expectEqualSlices(u16, &a, buf[0..4]);

    const sub = [_]u16{ 3, 7 };
    try testing.expectEqual(@as(usize, 4), union2by2(&a, &sub, &buf));
    try testing.expectEqualSlices(u16, &a, buf[0..4]);
    try testing.expectEqual(@as(usize, 4), union2by2(&sub, &a, &buf));
    try testing.expectEqualSlices(u16, &a, buf[0..4]);
}

test "union2by2 exhausts one side mid-run" {
    var buf: [16]u16 = undefined;
    const a = [_]u16{ 1, 2 };
    const b = [_]u16{ 2, 3, 4, 5 };
    try testing.expectEqual(@as(usize, 5), union2by2(&a, &b, &buf));
    try testing.expectEqualSlices(u16, &.{ 1, 2, 3, 4, 5 }, buf[0..5]);
}

test "intersection2by2 empty, disjoint, identical, subset" {
    var buf: [16]u16 = undefined;
    const a = [_]u16{ 1, 3, 5, 7 };
    const b = [_]u16{ 2, 4, 6, 8 };

    try testing.expectEqual(@as(usize, 0), intersection2by2(&a, &.{}, &buf));
    try testing.expectEqual(@as(usize, 0), intersection2by2(&.{}, &a, &buf));
    try testing.expectEqual(@as(usize, 0), intersection2by2(&a, &b, &buf));

    try testing.expectEqual(@as(usize, 4), intersection2by2(&a, &a, &buf));
    try testing.expectEqualSlices(u16, &a, buf[0..4]);

    const sub = [_]u16{ 3, 7 };
    try testing.expectEqual(@as(usize, 2), intersection2by2(&a, &sub, &buf));
    try testing.expectEqualSlices(u16, &sub, buf[0..2]);
    try testing.expectEqual(@as(usize, 2), intersection2by2(&sub, &a, &buf));
    try testing.expectEqualSlices(u16, &sub, buf[0..2]);
}

test "intersection2by2 crosses the galloping threshold both ways" {
    // 3 * 64 = 192 < 500, so the dispatcher picks the galloping variant.
    var large: [500]u16 = undefined;
    for (&large, 0..) |*v, i| v.* = @intCast(i * 3);
    const small = [_]u16{ 0, 600, 1497 }; // 1497 == large[499]
    var buf: [500]u16 = undefined;

    try testing.expectEqual(
        @as(usize, 3),
        intersection2by2(&small, &large, &buf),
    );
    try testing.expectEqualSlices(u16, &small, buf[0..3]);
    try testing.expectEqual(
        @as(usize, 3),
        intersection2by2(&large, &small, &buf),
    );
    try testing.expectEqualSlices(u16, &small, buf[0..3]);

    // A small set with no matches at all, and one that runs past the large set.
    const miss = [_]u16{ 1, 2, 1498 };
    try testing.expectEqual(
        @as(usize, 0),
        intersection2by2(&miss, &large, &buf),
    );
}

test "galloping and local intersection agree" {
    var large: [1000]u16 = undefined;
    for (&large, 0..) |*v, i| v.* = @intCast(i * 5);
    const small = [_]u16{ 5, 6, 500, 4995, 4996 };
    var gallop_buf: [1000]u16 = undefined;
    var local_buf: [1000]u16 = undefined;

    const g = onesidedgallopingintersect2by2(&small, &large, &gallop_buf);
    const l = localintersect2by2(&small, &large, &local_buf);
    try testing.expectEqual(l, g);
    try testing.expectEqualSlices(u16, local_buf[0..l], gallop_buf[0..g]);
    try testing.expectEqualSlices(u16, &.{ 5, 500, 4995 }, gallop_buf[0..g]);
}

test "intersection2by2Cardinality agrees with intersection2by2" {
    var buf: [1000]u16 = undefined;
    const a = [_]u16{ 1, 3, 5, 7 };
    const b = [_]u16{ 2, 4, 6, 8 };
    const sub = [_]u16{ 3, 7 };

    // Empty, disjoint, identical, subset — both argument orders.
    for ([_][2][]const u16{
        .{ &.{}, &.{} },
        .{ &a, &.{} },
        .{ &.{}, &a },
        .{ &a, &b },
        .{ &a, &a },
        .{ &a, &sub },
        .{ &sub, &a },
    }) |pair| {
        const want = intersection2by2(pair[0], pair[1], &buf);
        try testing.expectEqual(
            want,
            intersection2by2Cardinality(pair[0], pair[1]),
        );
    }

    // Past the 64x skew threshold, where both dispatchers pick galloping.
    var large: [500]u16 = undefined;
    for (&large, 0..) |*v, i| v.* = @intCast(i * 3);
    const small = [_]u16{ 0, 600, 1497 };
    const miss = [_]u16{ 1, 2, 1498 };

    try testing.expectEqual(
        @as(usize, 3),
        intersection2by2Cardinality(&small, &large),
    );
    try testing.expectEqual(
        @as(usize, 3),
        intersection2by2Cardinality(&large, &small),
    );
    try testing.expectEqual(
        @as(usize, 0),
        intersection2by2Cardinality(&miss, &large),
    );

    // The galloping and the linear kernel must count the same thing.
    try testing.expectEqual(
        localintersect2by2Cardinality(&small, &large),
        onesidedgallopingintersect2by2Cardinality(&small, &large),
    );
}

/// The obvious intersection, for the block kernel to be checked against.
fn referenceIntersect(
    set1: []const u16,
    set2: []const u16,
    buffer: []u16,
) usize {
    var pos: usize = 0;
    for (set1) |v| {
        if (std.mem.indexOfScalar(u16, set2, v) != null) {
            buffer[pos] = v;
            pos += 1;
        }
    }
    return pos;
}

/// Both modes of the block kernel against `referenceIntersect`, both argument
/// orders (which swaps which side's blocks get re-compared).
fn expectLocalIntersect(set1: []const u16, set2: []const u16) !void {
    var want: [512]u16 = undefined;
    var got: [512]u16 = undefined;
    const n = referenceIntersect(set1, set2, &want);

    for ([_][2][]const u16{ .{ set1, set2 }, .{ set2, set1 } }) |pair| {
        const m = localintersect2by2(pair[0], pair[1], &got);
        try testing.expectEqualSlices(u16, want[0..n], got[0..m]);
        try testing.expectEqual(
            n,
            localintersect2by2Cardinality(pair[0], pair[1]),
        );
    }
}

test "localintersect2by2 finds a match in every pair of block lanes" {
    // One shared value at lane k of set1 and lane l of set2, for all 64
    // (k, l): every lane of set2 has to be rotated past every lane of set1.
    // Padding is even on the set1 side and odd on the set2 side, so 1000
    // is the only match.
    for (0..8) |k| {
        for (0..8) |l| {
            var a: [8]u16 = undefined;
            var b: [8]u16 = undefined;
            for (&a, 0..) |*v, i| {
                const di = 2 * @as(i32, @intCast(i));
                const dk = 2 * @as(i32, @intCast(k));
                const off = di - dk;
                v.* = @intCast(1000 + off);
            }
            for (&b, 0..) |*v, j| {
                const dj = 2 * @as(i32, @intCast(j));
                const dl = 2 * @as(i32, @intCast(l));
                const off = dj - dl;
                const adj = if (j == l)
                    @as(i32, 0)
                else if (j < l)
                    @as(i32, -1)
                else
                    1;
                v.* = @intCast(1000 + off + adj);
            }
            var buf: [8]u16 = undefined;
            try testing.expectEqual(
                @as(usize, 1),
                localintersect2by2(&a, &b, &buf),
            );
            try testing.expectEqual(@as(u16, 1000), buf[0]);
            try testing.expectEqual(
                @as(usize, 1),
                localintersect2by2Cardinality(&a, &b),
            );
        }
    }
}

test "localintersect2by2 blocks with equal maxes advance both sides" {
    // Both first blocks end at 100 and both second blocks end at 200: every
    // comparison is a tie, so both sides step on every iteration.
    const a = [_]u16{
        1,   2,   3,   4,   5,   6,   7,   100,
        101, 102, 103, 104, 105, 106, 107, 200,
    };
    const b = [_]u16{
        10,  20,  30,  40,  50,  60,  70,  100,
        110, 120, 130, 140, 150, 160, 170, 200,
    };
    try expectLocalIntersect(&a, &b);

    var buf: [16]u16 = undefined;
    try testing.expectEqual(@as(usize, 2), localintersect2by2(&a, &b, &buf));
    try testing.expectEqualSlices(u16, &.{ 100, 200 }, buf[0..2]);
}

test "localintersect2by2 all-match and no-match blocks" {
    var all: [64]u16 = undefined;
    for (&all, 0..) |*v, i| v.* = @intCast(i * 2); // even
    var odd: [64]u16 = undefined;
    for (&odd, 0..) |*v, i| v.* = @intCast(i * 2 + 1);

    var buf: [64]u16 = undefined;
    try testing.expectEqual(
        @as(usize, 64),
        localintersect2by2(&all, &all, &buf),
    );
    try testing.expectEqualSlices(u16, &all, buf[0..64]);
    try testing.expectEqual(
        @as(usize, 0),
        localintersect2by2(&all, &odd, &buf),
    );
    try testing.expectEqual(
        @as(usize, 0),
        localintersect2by2Cardinality(&all, &odd),
    );

    // A block that matches entirely, followed by one that matches not at all.
    const half = all[0..8] ++ odd[8..16];
    try expectLocalIntersect(&all, half);
}

test "localintersect2by2 around the block boundary: 8, 9, 15, 16, 17" {
    for ([_]usize{ 0, 1, 7, 8, 9, 15, 16, 17, 31, 33 }) |n| {
        var a: [33]u16 = undefined;
        var b: [33]u16 = undefined;
        for (0..n) |i| a[i] = @intCast(i);
        // Overlaps a in a different place for each length: shared values are
        // those >= n/2, so both a full-block and a tail match are exercised.
        for (0..n) |i| b[i] = @intCast(i + n / 2);
        try expectLocalIntersect(a[0..n], b[0..n]);

        // Same lengths, disjoint values.
        for (0..n) |i| b[i] = @intCast(i + 1000);
        try expectLocalIntersect(a[0..n], b[0..n]);
    }
}

test "localintersect2by2 matches the reference on random inputs" {
    var prng = std.Random.DefaultPrng.init(0x5E7071);
    const rnd = prng.random();

    var a: [200]u16 = undefined;
    var b: [200]u16 = undefined;
    for (0..200) |_| {
        const n1 = rnd.uintAtMost(usize, a.len - 1) + 1;
        const n2 = rnd.uintAtMost(usize, b.len - 1) + 1;
        // Ascending gaps keep both sides sorted and duplicate-free; the tighter
        // the gap, the denser the overlap.
        const gap = rnd.uintAtMost(u16, 3) + 1;
        var v: u16 = 0;
        for (a[0..n1]) |*e| {
            e.* = v;
            v += rnd.uintAtMost(u16, gap) + 1;
        }
        v = 0;
        for (b[0..n2]) |*e| {
            e.* = v;
            v += rnd.uintAtMost(u16, gap) + 1;
        }
        try expectLocalIntersect(a[0..n1], b[0..n2]);
    }
}

test "localintersect2by2 writes in place over its own left operand" {
    // What Container.andArray does: the output buffer is set1's own storage.
    var prng = std.Random.DefaultPrng.init(0xA11A5);
    const rnd = prng.random();

    var a: [100]u16 = undefined;
    var b: [100]u16 = undefined;
    var scratch: [100]u16 = undefined;
    var want: [100]u16 = undefined;
    for (0..200) |_| {
        const n1 = rnd.uintAtMost(usize, a.len - 1) + 1;
        const n2 = rnd.uintAtMost(usize, b.len - 1) + 1;
        var v: u16 = 0;
        for (a[0..n1]) |*e| {
            e.* = v;
            v += rnd.uintAtMost(u16, 2) + 1;
        }
        v = 0;
        for (b[0..n2]) |*e| {
            e.* = v;
            v += rnd.uintAtMost(u16, 2) + 1;
        }
        const n = referenceIntersect(a[0..n1], b[0..n2], &want);

        @memcpy(scratch[0..n1], a[0..n1]);
        const m = localintersect2by2(scratch[0..n1], b[0..n2], &scratch);
        try testing.expectEqualSlices(u16, want[0..n], scratch[0..m]);
    }
}

test "advanceUntil" {
    const a = [_]u16{ 0, 10, 20, 30, 40, 50 };

    try testing.expectEqual(@as(usize, 1), advanceUntil(&a, 0, 10));
    try testing.expectEqual(@as(usize, 2), advanceUntil(&a, 0, 11));
    try testing.expectEqual(@as(usize, 5), advanceUntil(&a, 0, 50));
    try testing.expectEqual(
        @as(usize, 6),
        advanceUntil(&a, 0, 51),
    ); // nothing >= min
    try testing.expectEqual(
        @as(usize, 6),
        advanceUntil(&a, 5, 0),
    ); // pos at the end

    // Long array so the exponential probe actually doubles a few times.
    var long: [300]u16 = undefined;
    for (&long, 0..) |*v, i| v.* = @intCast(i * 2);
    try testing.expectEqual(@as(usize, 150), advanceUntil(&long, 0, 300));
    try testing.expectEqual(@as(usize, 150), advanceUntil(&long, 0, 299));
    try testing.expectEqual(@as(usize, 299), advanceUntil(&long, 0, 598));
    try testing.expectEqual(@as(usize, 300), advanceUntil(&long, 0, 599));
}

test "difference empty, disjoint, identical, subset" {
    var buf: [16]u16 = undefined;
    const a = [_]u16{ 1, 3, 5, 7 };
    const b = [_]u16{ 2, 4, 6, 8 };

    try testing.expectEqual(@as(usize, 4), difference(&a, &.{}, &buf));
    try testing.expectEqualSlices(u16, &a, buf[0..4]);
    try testing.expectEqual(@as(usize, 0), difference(&.{}, &a, &buf));

    try testing.expectEqual(@as(usize, 4), difference(&a, &b, &buf));
    try testing.expectEqualSlices(u16, &a, buf[0..4]);

    try testing.expectEqual(@as(usize, 0), difference(&a, &a, &buf));

    const sub = [_]u16{ 3, 7 };
    try testing.expectEqual(@as(usize, 2), difference(&a, &sub, &buf));
    try testing.expectEqualSlices(u16, &.{ 1, 5 }, buf[0..2]);
    try testing.expectEqual(@as(usize, 0), difference(&sub, &a, &buf));
}

test "difference where set2 runs out first" {
    var buf: [16]u16 = undefined;
    const a = [_]u16{ 1, 2, 3, 4, 5 };
    const b = [_]u16{ 2, 9 };
    try testing.expectEqual(@as(usize, 4), difference(&a, &b, &buf));
    try testing.expectEqualSlices(u16, &.{ 1, 3, 4, 5 }, buf[0..4]);

    const c = [_]u16{ 1, 2 };
    try testing.expectEqual(@as(usize, 3), difference(&a, &c, &buf));
    try testing.expectEqualSlices(u16, &.{ 3, 4, 5 }, buf[0..3]);
}
