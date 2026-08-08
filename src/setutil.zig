//! Merge kernels over the sorted, duplicate-free u16 payloads of array
//! containers. Ported from sroar's setutil.go, which in turn comes from
//! RoaringBitmap/roaring (Apache-2.0). Scalar throughout, except for the
//! eight-at-a-time block phase of `localIntersectCore`.
//!
//! Every kernel writes into a caller-supplied `buffer` and returns how many
//! elements it wrote; the caller sizes the buffer from the worst case.

const std = @import("std");
const assert = std.debug.assert;

/// Galloping intersection pays off once one side is this many times larger.
const gallop_skew = 64;

/// Writes set1 ∪ set2 into `buffer`, returns the count written.
/// `buffer` must hold at least set1.len + set2.len elements.
pub fn union2by2(set1: []const u16, set2: []const u16, buffer: []u16) usize {
    if (set2.len == 0) {
        @memcpy(buffer[0..set1.len], set1);
        return set1.len;
    }
    if (set1.len == 0) {
        @memcpy(buffer[0..set2.len], set2);
        return set2.len;
    }
    assert(buffer.len >= set1.len + set2.len);

    var pos: usize = 0;
    var k1: usize = 0;
    var k2: usize = 0;
    var s1 = set1[k1];
    var s2 = set2[k2];
    while (true) {
        if (s1 < s2) {
            buffer[pos] = s1;
            pos += 1;
            k1 += 1;
            if (k1 >= set1.len) {
                pos += copyTail(buffer[pos..], set2[k2..]);
                break;
            }
            s1 = set1[k1];
        } else if (s1 == s2) {
            buffer[pos] = s1;
            pos += 1;
            k1 += 1;
            k2 += 1;
            if (k1 >= set1.len) {
                pos += copyTail(buffer[pos..], set2[k2..]);
                break;
            }
            if (k2 >= set2.len) {
                pos += copyTail(buffer[pos..], set1[k1..]);
                break;
            }
            s1 = set1[k1];
            s2 = set2[k2];
        } else {
            buffer[pos] = s2;
            pos += 1;
            k2 += 1;
            if (k2 >= set2.len) {
                pos += copyTail(buffer[pos..], set1[k1..]);
                break;
            }
            s2 = set2[k2];
        }
    }
    return pos;
}

fn copyTail(dst: []u16, src: []const u16) usize {
    @memcpy(dst[0..src.len], src);
    return src.len;
}

/// Whether an intersection kernel writes the elements it matches or only counts
/// them. `.count` is the same loop with the one store dropped, so the mode is a
/// comptime parameter rather than a second copy of the loop.
const Mode = enum { materialize, count };

/// Where a kernel of that mode puts its output: a buffer, or nowhere.
fn Out(comptime mode: Mode) type {
    return if (mode == .materialize) []u16 else void;
}

/// set1 ∩ set2, returning how many elements matched. Both modes take the same
/// galloping-versus-linear decision on the same inputs, so a count always
/// agrees with the intersection it stands in for.
fn intersectCore(
    comptime mode: Mode,
    set1: []const u16,
    set2: []const u16,
    out: Out(mode),
) usize {
    if (set1.len * gallop_skew < set2.len) {
        return gallopingIntersectCore(mode, set1, set2, out);
    }
    if (set2.len * gallop_skew < set1.len) {
        return gallopingIntersectCore(mode, set2, set1, out);
    }
    return localIntersectCore(mode, set1, set2, out);
}

/// How many elements of each side `localIntersectCore` compares at a time.
const block_len = 8;
const Block = @Vector(block_len, u16);

/// Bit k of the result is set iff `va[k]` equals some lane of `vb`.
///
/// A vector equality only ever lines lane k up with lane k, so one compare sees
/// 8 of the 64 pairs. Rotating `vb` one lane to the left re-pairs every lane of
/// `va` with `vb`'s next neighbour, so eight rotations — the identity plus
/// seven — walk every lane of `vb` past every lane of `va`: all 64 pairs, none
/// twice. Every rotation amount is comptime, so each is one fixed shuffle.
fn matchAny(va: Block, vb: Block) u8 {
    var mask: u8 = @bitCast(va == vb);
    inline for (1..block_len) |r| {
        mask |= @as(u8, @bitCast(va == std.simd.rotateElementsLeft(vb, r)));
    }
    return mask;
}

/// Intersection for sets of similar size: a block phase that compares eight
/// elements against eight at a time, then the scalar two-pointer walk over
/// whatever tail is left over.
fn localIntersectCore(
    comptime mode: Mode,
    set1: []const u16,
    set2: []const u16,
    out: Out(mode),
) usize {
    if (set1.len == 0 or set2.len == 0) return 0;

    var k1: usize = 0;
    var k2: usize = 0;
    var pos: usize = 0;

    // Block phase. Both sides are sorted, so the block maxes say which block is
    // finished: if a_max <= b_max, everything in set2 past this block is larger
    // than every element of set1's block, so that block can never match again
    // and set1 advances; symmetrically for set2; on a tie both are finished.
    // The block that does not advance is compared again against set2's next
    // block, but no match can be reported twice: each side is duplicate-free,
    // so a matching pair meets in exactly one block-against-block compare.
    while (k1 + block_len <= set1.len and k2 + block_len <= set2.len) {
        const va: Block = set1[k1..][0..block_len].*;
        const vb: Block = set2[k2..][0..block_len].*;
        var m = matchAny(va, vb);
        if (mode == .materialize) {
            // The set bits of `m`, lowest first, are the matching lanes of the
            // set1 block in ascending order; `m &= m - 1` clears the lowest.
            // Lane t is written at `pos <= k1 + t`, i.e. never past the element
            // it came from, which is what lets Container.andArray point `out`
            // at set1's own storage.
            while (m != 0) : (m &= m - 1) {
                out[pos] = set1[k1 + @ctz(m)];
                pos += 1;
            }
        } else {
            pos += @popCount(m);
        }
        const a_max = set1[k1 + block_len - 1];
        const b_max = set2[k2 + block_len - 1];
        if (a_max <= b_max) k1 += block_len;
        if (b_max <= a_max) k2 += block_len;
    }
    if (k1 == set1.len or k2 == set2.len) return pos;

    // Tail: fewer than eight elements left on one side, so finish by walking.
    var s1 = set1[k1];
    var s2 = set2[k2];
    mainwhile: while (true) {
        while (s2 < s1) {
            k2 += 1;
            if (k2 == set2.len) break :mainwhile;
            s2 = set2[k2];
        }
        while (s1 < s2) {
            k1 += 1;
            if (k1 == set1.len) break :mainwhile;
            s1 = set1[k1];
        }
        if (s1 == s2) {
            if (mode == .materialize) out[pos] = s1;
            pos += 1;
            k1 += 1;
            if (k1 == set1.len) break;
            s1 = set1[k1];
            k2 += 1;
            if (k2 == set2.len) break;
            s2 = set2[k2];
        }
    }
    return pos;
}

/// Intersection for heavily skewed inputs: each element of `smallset` is located
/// in `largeset` by an exponential (galloping) probe instead of a linear walk.
fn gallopingIntersectCore(
    comptime mode: Mode,
    smallset: []const u16,
    largeset: []const u16,
    out: Out(mode),
) usize {
    if (smallset.len == 0 or largeset.len == 0) return 0;

    var k1: usize = 0;
    var k2: usize = 0;
    var pos: usize = 0;
    var s1 = largeset[k1];
    var s2 = smallset[k2];
    mainwhile: while (true) {
        if (s1 < s2) {
            k1 = advanceUntil(largeset, k1, s2);
            if (k1 == largeset.len) break :mainwhile;
            s1 = largeset[k1];
        }
        if (s2 < s1) {
            k2 += 1;
            if (k2 == smallset.len) break :mainwhile;
            s2 = smallset[k2];
        } else {
            if (mode == .materialize) out[pos] = s2;
            pos += 1;
            k2 += 1;
            if (k2 == smallset.len) break;
            s2 = smallset[k2];
            k1 = advanceUntil(largeset, k1, s2);
            if (k1 == largeset.len) break :mainwhile;
            s1 = largeset[k1];
        }
    }
    return pos;
}

/// Writes set1 ∩ set2 into `buffer`, returns the count written.
/// `buffer` must hold at least @min(set1.len, set2.len) elements.
pub fn intersection2by2(set1: []const u16, set2: []const u16, buffer: []u16) usize {
    return intersectCore(.materialize, set1, set2, buffer);
}

/// Intersection for sets of similar size.
fn localintersect2by2(set1: []const u16, set2: []const u16, buffer: []u16) usize {
    return localIntersectCore(.materialize, set1, set2, buffer);
}

/// Galloping intersection, for heavily skewed inputs.
pub fn onesidedgallopingintersect2by2(
    smallset: []const u16,
    largeset: []const u16,
    buffer: []u16,
) usize {
    return gallopingIntersectCore(.materialize, smallset, largeset, buffer);
}

/// Counts set1 ∩ set2 without writing it anywhere. (sroar carries this pair as
/// dead code in setutil.go; here they are what the fused `Bitmap.andCardinality`
/// and friends run on two array containers.)
pub fn intersection2by2Cardinality(set1: []const u16, set2: []const u16) usize {
    return intersectCore(.count, set1, set2, {});
}

/// Counting twin of `localintersect2by2`.
fn localintersect2by2Cardinality(set1: []const u16, set2: []const u16) usize {
    return localIntersectCore(.count, set1, set2, {});
}

/// Counting twin of `onesidedgallopingintersect2by2`.
pub fn onesidedgallopingintersect2by2Cardinality(
    smallset: []const u16,
    largeset: []const u16,
) usize {
    return gallopingIntersectCore(.count, smallset, largeset, {});
}

/// Returns the index of the first element of `array` at index > `pos` that is
/// >= `min`, or array.len if there is none. Exponential probe, then bisection.
pub fn advanceUntil(array: []const u16, pos: usize, min: u16) usize {
    var lower = pos + 1;
    if (lower >= array.len or array[lower] >= min) return lower;

    var spansize: usize = 1;
    while (lower + spansize < array.len and array[lower + spansize] < min) {
        spansize *= 2;
    }
    var upper = if (lower + spansize < array.len) lower + spansize else array.len - 1;

    if (array[upper] == min) return upper;
    if (array[upper] < min) return array.len; // no element >= min

    // The previous, half-as-wide span was too small, so the answer lies in
    // (lower + spansize/2, upper].
    lower += spansize >> 1;
    while (lower + 1 != upper) {
        const mid = (lower + upper) >> 1;
        if (array[mid] == min) return mid;
        if (array[mid] < min) lower = mid else upper = mid;
    }
    return upper;
}

/// Writes set1 \ set2 into `buffer`, returns the count written.
/// `buffer` must hold at least set1.len elements.
pub fn difference(set1: []const u16, set2: []const u16, buffer: []u16) usize {
    if (set2.len == 0) {
        @memcpy(buffer[0..set1.len], set1);
        return set1.len;
    }
    if (set1.len == 0) return 0;
    assert(buffer.len >= set1.len);

    var pos: usize = 0;
    var k1: usize = 0;
    var k2: usize = 0;
    var s1 = set1[k1];
    var s2 = set2[k2];
    while (true) {
        if (s1 < s2) {
            buffer[pos] = s1;
            pos += 1;
            k1 += 1;
            if (k1 >= set1.len) break;
            s1 = set1[k1];
        } else if (s1 == s2) {
            k1 += 1;
            k2 += 1;
            if (k1 >= set1.len) break;
            s1 = set1[k1];
            if (k2 >= set2.len) {
                pos += copyTail(buffer[pos..], set1[k1..]);
                break;
            }
            s2 = set2[k2];
        } else {
            k2 += 1;
            if (k2 >= set2.len) {
                pos += copyTail(buffer[pos..], set1[k1..]);
                break;
            }
            s2 = set2[k2];
        }
    }
    return pos;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

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

    try testing.expectEqual(@as(usize, 3), intersection2by2(&small, &large, &buf));
    try testing.expectEqualSlices(u16, &small, buf[0..3]);
    try testing.expectEqual(@as(usize, 3), intersection2by2(&large, &small, &buf));
    try testing.expectEqualSlices(u16, &small, buf[0..3]);

    // A small set with no matches at all, and one that runs past the large set.
    const miss = [_]u16{ 1, 2, 1498 };
    try testing.expectEqual(@as(usize, 0), intersection2by2(&miss, &large, &buf));
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
        try testing.expectEqual(want, intersection2by2Cardinality(pair[0], pair[1]));
    }

    // Past the 64x skew threshold, where both dispatchers pick galloping.
    var large: [500]u16 = undefined;
    for (&large, 0..) |*v, i| v.* = @intCast(i * 3);
    const small = [_]u16{ 0, 600, 1497 };
    const miss = [_]u16{ 1, 2, 1498 };

    try testing.expectEqual(@as(usize, 3), intersection2by2Cardinality(&small, &large));
    try testing.expectEqual(@as(usize, 3), intersection2by2Cardinality(&large, &small));
    try testing.expectEqual(@as(usize, 0), intersection2by2Cardinality(&miss, &large));

    // The galloping and the linear kernel must count the same thing.
    try testing.expectEqual(
        localintersect2by2Cardinality(&small, &large),
        onesidedgallopingintersect2by2Cardinality(&small, &large),
    );
}

/// The obvious intersection, for the block kernel to be checked against.
fn referenceIntersect(set1: []const u16, set2: []const u16, buffer: []u16) usize {
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
        try testing.expectEqual(n, localintersect2by2Cardinality(pair[0], pair[1]));
    }
}

test "localintersect2by2 finds a match in every pair of block lanes" {
    // One shared value at lane k of set1 and lane l of set2, for all 64 (k, l):
    // every lane of set2 has to be rotated past every lane of set1. Padding is
    // even on the set1 side and odd on the set2 side, so 1000 is the only match.
    for (0..8) |k| {
        for (0..8) |l| {
            var a: [8]u16 = undefined;
            var b: [8]u16 = undefined;
            for (&a, 0..) |*v, i| {
                v.* = @intCast(1000 + 2 * @as(i32, @intCast(i)) - 2 * @as(i32, @intCast(k)));
            }
            for (&b, 0..) |*v, j| {
                const off = 2 * @as(i32, @intCast(j)) - 2 * @as(i32, @intCast(l));
                v.* = @intCast(1000 + off + if (j == l) @as(i32, 0) else if (j < l) @as(i32, -1) else 1);
            }
            var buf: [8]u16 = undefined;
            try testing.expectEqual(@as(usize, 1), localintersect2by2(&a, &b, &buf));
            try testing.expectEqual(@as(u16, 1000), buf[0]);
            try testing.expectEqual(@as(usize, 1), localintersect2by2Cardinality(&a, &b));
        }
    }
}

test "localintersect2by2 blocks with equal maxes advance both sides" {
    // Both first blocks end at 100 and both second blocks end at 200: every
    // comparison is a tie, so both sides step on every iteration.
    const a = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 100, 101, 102, 103, 104, 105, 106, 107, 200 };
    const b = [_]u16{ 10, 20, 30, 40, 50, 60, 70, 100, 110, 120, 130, 140, 150, 160, 170, 200 };
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
    try testing.expectEqual(@as(usize, 64), localintersect2by2(&all, &all, &buf));
    try testing.expectEqualSlices(u16, &all, buf[0..64]);
    try testing.expectEqual(@as(usize, 0), localintersect2by2(&all, &odd, &buf));
    try testing.expectEqual(@as(usize, 0), localintersect2by2Cardinality(&all, &odd));

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
    try testing.expectEqual(@as(usize, 6), advanceUntil(&a, 0, 51)); // nothing >= min
    try testing.expectEqual(@as(usize, 6), advanceUntil(&a, 5, 0)); // pos at the end

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
