// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

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
/// A vector equality only ever lines lane k up with lane k, so one compare
/// sees 8 of the 64 pairs. Rotating `vb` one lane to the left re-pairs
/// every lane of `va` with `vb`'s next neighbour, so eight rotations — the
/// identity plus seven — walk every lane of `vb` past every lane of `va`:
/// all 64 pairs, none twice. Every rotation amount is comptime, so each is
/// one fixed shuffle.
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

/// Intersection for heavily skewed inputs: each element of `smallset` is
/// located in `largeset` by an exponential (galloping) probe instead of a
/// linear walk.
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
pub fn intersection2by2(
    set1: []const u16,
    set2: []const u16,
    buffer: []u16,
) usize {
    return intersectCore(.materialize, set1, set2, buffer);
}

/// Intersection for sets of similar size: the balanced-input kernel behind
/// `intersection2by2`. Public so the test suite can exercise it directly
/// rather than through the skew dispatcher.
pub fn localintersect2by2(
    set1: []const u16,
    set2: []const u16,
    buffer: []u16,
) usize {
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

/// Counts set1 ∩ set2 without writing it anywhere. (sroar carries this pair
/// as dead code in setutil.go; here they are what the fused
/// `Bitmap.andCardinality` and friends run on two array containers.)
pub fn intersection2by2Cardinality(
    set1: []const u16,
    set2: []const u16,
) usize {
    return intersectCore(.count, set1, set2, {});
}

/// Counting twin of `localintersect2by2`, the balanced-input kernel. Public for
/// the same reason: so the test suite can reach it without the dispatcher.
pub fn localintersect2by2Cardinality(
    set1: []const u16,
    set2: []const u16,
) usize {
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
    var upper = if (lower + spansize < array.len)
        lower + spansize
    else
        array.len - 1;

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
