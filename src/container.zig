//! Array and bitmap container kernels. A container is a `[]u16` slice of
//! exactly its allocated size, laid out as a 4-u16 header followed by payload:
//!
//! | u16 index | meaning                                              |
//! |-----------|------------------------------------------------------|
//! | 0         | allocated size in u16 units, header included         |
//! | 1         | type: 0 = array, 1 = bitmap                          |
//! | 2..3      | cardinality, as one aligned u32                      |
//!
//! Every container starts at an 8-byte-aligned offset and every size is a
//! multiple of 4 u16s, so the payload of a bitmap container is 8-byte aligned
//! and can be viewed as `[]u64`.
//!
//! Ported from sroar's container.go, with two deliberate differences: the
//! cardinality is a single u32 rather than two u16s, and bitmap containers are
//! LSB-first over u64 words rather than MSB-first over u16 words.

const std = @import("std");
const assert = std.debug.assert;

const setutil = @import("setutil.zig");
const stats = @import("stats.zig");

pub const Type = enum(u16) { array = 0, bitmap = 1 };

pub const index_size: usize = 0;
pub const index_type: usize = 1;
pub const index_cardinality: usize = 2;
/// First payload element.
pub const start_idx: usize = 4;

/// Every size an array container may have, in u16 units, header included.
///
/// Listed rather than computed. These are the only legal array sizes, they are
/// the sizes a serialized buffer will contain, and every sizing decision in the
/// library goes through this table (`arraySizeFor`, `nextArraySize`, init's
/// key-0 container, `min_buffer_bytes`, `fromSortedList` and `fastOr`'s
/// pre-sizing). A doubling rule computed the same numbers but hid them, and
/// hid that the last step is the one that decides where bitmap containers
/// start.
///
/// The trade-off along the ladder is waste against growth events. A container
/// wastes the difference between its cardinality and its step; a container
/// that outgrows a step relocates to the end of the buffer and leaves a dead
/// slot behind (see `max_dead_divisor`), so finer steps waste less but churn
/// more. The first entry matters most: at 8 a container costs 16 bytes and
/// holds 4 values, so a key with a single value wastes almost nothing — the
/// case that dominates scattered u64 data, where a serialized bitmap is mostly
/// one-value containers.
///
/// So the ladder doubles while containers are small, where a step wastes only
/// a few hundred bytes and another growth event would cost more than it saves,
/// and takes half-steps from 1024 on, where doubling starts wasting kilobytes.
///
/// The last entry decides where arrays stop and bitmaps begin, which is a
/// bigger lever than it looks: a bitmap container is a fixed `max_size` and
/// extracts roughly 6x slower per value than an array, but answers membership
/// in one bit test and unions by vectorized word ops. 3072 u16 is 6144 bytes,
/// still under `max_size`, so every entry here is a size at which an array
/// genuinely beats a bitmap on space. The next half-step, 4096, would be 8192
/// bytes — a wash against a bitmap, so it would give up O(1) membership and
/// vectorized set ops for nothing. See DESIGN.md.
pub const array_sizes = [_]u16{
    8, 16, 32, 64, 128, 256, 512, 1024, 1536, 2048, 3072,
};

/// Smallest array container, in u16 units, header included.
pub const min_size: u16 = array_sizes[0];
/// An array container that would grow past this converts to a bitmap instead.
pub const max_array_size: u16 = array_sizes[array_sizes.len - 1];
/// Bitmap containers are always this size: 4 header + 4096 payload u16s.
pub const max_size: u16 = 4 + (1 << 16) / 16;
/// Payload words of a bitmap container.
pub const word_count: usize = (max_size - start_idx) / 4;
/// Largest number of values an array container can hold before converting.
pub const max_array_values: usize = max_array_size - start_idx;
/// A container holds at most every u16, i.e. 65536 values.
pub const max_cardinality: u32 = 1 << 16;
/// "Cardinality unknown, recompute me". Only ever set transiently by fastOr.
pub const invalid_cardinality: u32 = std.math.maxInt(u32);

comptime {
    assert(array_sizes.len > 0);
    assert(min_size > start_idx); // room for at least one value
    // A bitmap container must be the strictly larger option, or the last
    // growth step would not be a step.
    assert(max_array_size < max_size);
    for (array_sizes, 0..) |sz, i| {
        assert(sz % 4 == 0); // the 8-byte alignment invariant
        if (i > 0) assert(sz > array_sizes[i - 1]); // strictly ascending
    }
}

/// Allocated size of the container, in u16 units, header included.
pub fn size(c: []const u16) u16 {
    return c[index_size];
}

pub fn getType(c: []const u16) Type {
    assert(c[index_type] <= @intFromEnum(Type.bitmap));
    return @enumFromInt(c[index_type]);
}

pub fn setType(c: []u16, t: Type) void {
    c[index_type] = @intFromEnum(t);
}

pub fn getCardinality(c: []const u16) u32 {
    const p: *const u32 = @ptrCast(@alignCast(c[index_cardinality..].ptr));
    return p.*;
}

pub fn setCardinality(c: []u16, card: u32) void {
    assert(card <= max_cardinality or card == invalid_cardinality);
    const p: *u32 = @ptrCast(@alignCast(c[index_cardinality..].ptr));
    p.* = card;
}

/// Adds the low 16 bits `x` to the container. Returns true if newly added.
/// The caller must handle a now-full array container (expand or convert).
///
/// `sink` receives the count of what this had to move; it is zero-bit and
/// every write to it disappears unless the counters are enabled.
pub fn add(c: []u16, x: u16, sink: *stats.Sink) bool {
    return switch (getType(c)) {
        .array => array.add(c, x, sink),
        .bitmap => bitmap.add(c, x),
    };
}

/// Reports whether the low 16 bits `x` are present.
pub fn has(c: []const u16, x: u16) bool {
    return switch (getType(c)) {
        .array => array.has(c, x),
        .bitmap => bitmap.has(c, x),
    };
}

/// Removes the low 16 bits `x`. Returns true if it was present.
pub fn remove(c: []u16, x: u16) bool {
    return switch (getType(c)) {
        .array => array.remove(c, x),
        .bitmap => bitmap.remove(c, x),
    };
}

/// Smallest value present. The container must be non-empty.
pub fn minimum(c: []const u16) u16 {
    assert(getCardinality(c) > 0);
    return switch (getType(c)) {
        .array => array.minimum(c),
        .bitmap => bitmap.minimum(c),
    };
}

/// Largest value present. The container must be non-empty.
pub fn maximum(c: []const u16) u16 {
    assert(getCardinality(c) > 0);
    return switch (getType(c)) {
        .array => array.maximum(c),
        .bitmap => bitmap.maximum(c),
    };
}

/// Empties the container, keeping its type and its allocated size.
pub fn zeroOut(c: []u16) void {
    switch (getType(c)) {
        // Clear the payload too, so the serialized buffer stays canonical.
        .array => @memset(c[start_idx..][0..getCardinality(c)], 0),
        .bitmap => @memset(bitmap.words(c), 0),
    }
    setCardinality(c, 0);
}

/// Recomputes a bitmap container's cardinality from its payload bits. Only
/// bitmap containers can carry the `invalid_cardinality` sentinel, so only they
/// ever need repairing.
pub fn recomputeCardinality(c: []u16) void {
    assert(getType(c) == .bitmap);
    setCardinality(c, bitmap.cardinality(c));
}

/// Smallest legal array-container size (in u16s, header included) that holds
/// `count` values plus the free slot the invariant demands, or null when no
/// array container is big enough and a bitmap container must be used instead.
pub fn arraySizeFor(count: usize) ?u16 {
    for (array_sizes) |sz| {
        if (start_idx + count + 1 <= sz) return sz;
    }
    return null;
}

/// The smallest legal array-container size holding `count` values, ignoring
/// the ladder, or null when only a bitmap container will do.
///
/// `arraySizeFor` rounds up to a ladder step so a container has room to grow
/// into. This rounds up only as far as the invariants demand — the free slot
/// and the 8-byte alignment — which is what `Bitmap.compact` wants, since its
/// whole purpose is to hand that room back.
pub fn compactArraySizeFor(count: usize) ?u16 {
    const needed = start_idx + count + 1; // + the free slot
    const aligned = (needed + 3) / 4 * 4;
    if (aligned > max_array_size) return null;
    return @max(min_size, @as(u16, @intCast(aligned)));
}

/// The next size up from `sz` on the ladder, or `max_size` once the ladder is
/// exhausted and only a bitmap container is left. `sz` need not itself be a
/// ladder entry: `compact` produces sizes between steps, and callers grow a
/// container towards a size they already hold.
pub fn nextArraySize(sz: u16) u16 {
    for (array_sizes) |s| {
        if (s > sz) return s;
    }
    return max_size;
}

/// Array container: a sorted, duplicate-free run of u16s after the header.
pub const array = struct {
    /// The values, in ascending order.
    pub fn values(c: []const u16) []const u16 {
        const n: usize = getCardinality(c);
        assert(start_idx + n <= c.len);
        return c[start_idx..][0..n];
    }

    /// Window size at which `find` stops bisecting and scans instead.
    ///
    /// Values are contiguous u16, so a vector load is 16 of them and the scan
    /// is cheap per element — which argues for a wide window. What holds it
    /// down is that the scan's work cannot be speculated away, while the
    /// bisection steps it replaces cost nothing once lookups repeat and the
    /// branch predictor has learnt the path.
    ///
    /// Measured (`zig build searchbench`, medians of ten runs, mean ns/lookup
    /// against a plain bisect): widening 64 -> 128 buys 0.66 ns on
    /// non-repeating lookups and costs 1.07 ns on repeating ones, so it only
    /// pays if over ~62% of lookups never repeat. 256 is worse than 128 in
    /// every stream. Hence 64.
    pub const scan_max_values: usize = 64;

    const scan_lanes = 16;
    const Scan = @Vector(scan_lanes, u16);
    const ScanMask = std.meta.Int(.unsigned, scan_lanes);

    /// Index (payload-relative) of the first value >= x, or the cardinality if
    /// every value is smaller.
    ///
    /// Bisecting is a chain of dependent loads, so its cost is latency: each
    /// step waits for the previous one before it knows where to look next.
    /// Scanning has no chain, and one vector load is `scan_lanes` values, so
    /// past a point the scan is the cheaper way to finish. Bisect down to that
    /// point, then count.
    pub fn find(c: []const u16, x: u16) usize {
        return findWindow(scan_max_values, c, x);
    }

    /// `find` with the scan window given explicitly. `window` is comptime, so
    /// this is exactly the code `find` compiles to; the parameter exists so a
    /// benchmark can sweep the cutoff against the shipping function rather
    /// than against a copy of it that might drift.
    pub fn findWindow(
        comptime window: usize,
        c: []const u16,
        x: u16,
    ) usize {
        const vals = values(c);
        var lo: usize = 0;
        var hi: usize = vals.len;
        while (hi - lo > window) {
            const mid = lo + (hi - lo) / 2;
            if (vals[mid] < x) lo = mid + 1 else hi = mid;
        }
        return lo + scan(vals[lo..hi], x);
    }

    /// Counts values below x. Branch-free by construction: a lane comparison
    /// feeds a popcount, so there is nothing to mispredict. Stopping early at
    /// the first value >= x would do less work but costs an unpredictable
    /// branch, which measured worse.
    fn scan(vals: []const u16, x: u16) usize {
        const target: Scan = @splat(x);
        var count: usize = 0;
        var i: usize = 0;
        while (i + scan_lanes <= vals.len) : (i += scan_lanes) {
            const v: Scan = vals[i..][0..scan_lanes].*;
            const below: ScanMask = @bitCast(v < target);
            count += @popCount(below);
        }
        while (i < vals.len) : (i += 1) count += @intFromBool(vals[i] < x);
        return count;
    }

    pub fn has(c: []const u16, x: u16) bool {
        const vals = values(c);
        const idx = find(c, x);
        return idx < vals.len and vals[idx] == x;
    }

    /// Inserts x in sorted position. Returns true if newly added.
    /// Relies on the free-slot invariant: a live array container always has
    /// room for one more.
    ///
    /// Reports the tail it shifted to `sink`: an insert below the values
    /// already present moves all of them, which is the dominant cost of
    /// building a bitmap one value at a time.
    pub fn add(c: []u16, x: u16, sink: *stats.Sink) bool {
        const n: usize = getCardinality(c);
        const idx = find(c, x);
        const off = start_idx + idx;
        if (idx < n and c[off] == x) return false;

        assert(start_idx + n < c.len); // free-slot invariant
        const tail = n - idx;
        stats.bump(sink, .array_shifted_u16, tail);
        std.mem.copyBackwards(u16, c[off + 1 ..][0..tail], c[off..][0..tail]);
        c[off] = x;
        setCardinality(c, @intCast(n + 1));
        return true;
    }

    pub fn remove(c: []u16, x: u16) bool {
        const n: usize = getCardinality(c);
        const idx = find(c, x);
        const off = start_idx + idx;
        if (idx >= n or c[off] != x) return false;

        const tail = n - idx - 1;
        std.mem.copyForwards(u16, c[off..][0..tail], c[off + 1 ..][0..tail]);
        // Clear the vacated slot so the serialized buffer stays canonical.
        c[start_idx + n - 1] = 0;
        setCardinality(c, @intCast(n - 1));
        return true;
    }

    /// True when the container has no free slot left. `set` expands or converts
    /// as soon as this becomes true, so it is never observed by a reader.
    pub fn isFull(c: []const u16) bool {
        const n: usize = getCardinality(c);
        return start_idx + n >= c.len;
    }

    pub fn minimum(c: []const u16) u16 {
        return values(c)[0];
    }

    pub fn maximum(c: []const u16) u16 {
        const vals = values(c);
        return vals[vals.len - 1];
    }

    /// Keeps only the first `n` values, clearing the slots beyond them so the
    /// serialized buffer stays canonical.
    fn truncate(c: []u16, n: usize) void {
        const old: usize = getCardinality(c);
        assert(n <= old);
        @memset(c[start_idx + n ..][0 .. old - n], 0);
        setCardinality(c, @intCast(n));
    }

    /// c := c ∩ other, both array containers, computed in place.
    ///
    /// `intersection2by2` may write into the slice it reads as `set1` here:
    /// every element it emits was already consumed from set1, so the write
    /// cursor never overtakes the read cursor. (It contains no `@memcpy` of
    /// overlapping ranges either, unlike `union2by2` and `difference`.)
    pub fn andArray(c: []u16, other: []const u16) void {
        const n = setutil.intersection2by2(
            values(c),
            values(other),
            c[start_idx..],
        );
        truncate(c, n);
    }

    /// c := c ∩ other, where `other` is a bitmap container. A filter over c's
    /// own values, so the write cursor trails the read cursor and the filter
    /// can run over c's own payload.
    pub fn andBitmap(c: []u16, other: []const u16) void {
        truncate(c, andBitmapInto(c[start_idx..], c, other));
    }

    /// Writes those values of `c` that the bitmap container `other` also holds
    /// into `out`, ascending, and returns how many. `out` must hold c's
    /// cardinality. The out-of-place twin of andBitmap, for building a result
    /// without touching either operand.
    pub fn andBitmapInto(out: []u16, c: []const u16, other: []const u16) usize {
        var w: usize = 0;
        for (values(c)) |v| {
            out[w] = v;
            w += @intFromBool(bitmap.has(other, v));
        }
        return w;
    }

    /// How many of `c`'s values the bitmap container `other` also holds: one
    /// bit test per value of the array side, writing nothing. The counting twin
    /// of andBitmapInto.
    pub fn andBitmapCardinality(c: []const u16, other: []const u16) u32 {
        var n: u32 = 0;
        for (values(c)) |v| n += @intFromBool(bitmap.has(other, v));
        return n;
    }

    /// c := c \ other, both array containers, computed in place.
    pub fn andNotArray(c: []u16, other: []const u16) void {
        const src = values(other);
        var w: usize = 0;
        var j: usize = 0;
        for (values(c)) |v| {
            while (j < src.len and src[j] < v) j += 1;
            if (j < src.len and src[j] == v) continue;
            c[start_idx + w] = v;
            w += 1;
        }
        truncate(c, w);
    }

    /// c := c \ other, where `other` is a bitmap container.
    pub fn andNotBitmap(c: []u16, other: []const u16) void {
        var w: usize = 0;
        for (values(c)) |v| {
            c[start_idx + w] = v;
            w += @intFromBool(!bitmap.has(other, v));
        }
        truncate(c, w);
    }

    /// Writes the array container `c` into `buf` as a bitmap container. `buf`
    /// must be max_size long and 8-byte aligned; all of it is overwritten.
    pub fn toBitmapInto(buf: []u16, c: []const u16) void {
        assert(buf.len == max_size);
        @memset(buf, 0);
        buf[index_size] = max_size;
        setType(buf, .bitmap);

        const w = bitmap.words(buf);
        for (values(c)) |v| {
            w[v >> 6] |= @as(u64, 1) << @truncate(v);
        }
        setCardinality(buf, getCardinality(c));
    }

    /// Rewrites an array container in place as a bitmap container. `c` must
    /// already have been grown to max_size.
    pub fn toBitmap(c: []u16) void {
        assert(getType(c) == .array);
        assert(c.len == max_size);

        // Copy the values out first: the bit for a value can land anywhere in
        // the payload, including on top of values not yet read.
        var vals: [max_array_values]u16 = undefined;
        const n = getCardinality(c);
        @memcpy(vals[0..n], values(c));

        @memset(c[start_idx..], 0);
        c[index_size] = max_size;
        setType(c, .bitmap);

        const w = bitmap.words(c);
        for (vals[0..n]) |v| {
            w[v >> 6] |= @as(u64, 1) << @truncate(v);
        }
        setCardinality(c, n);
    }
};

/// Bitmap container: 1024 u64 words, LSB-first. Value x lives in word x >> 6,
/// bit x & 63.
pub const bitmap = struct {
    /// The payload viewed as u64 words. Valid only while the buffer is not
    /// grown.
    pub fn words(c: []u16) []u64 {
        assert(c.len == max_size);
        const p: [*]u64 = @ptrCast(@alignCast(c[start_idx..].ptr));
        return p[0..word_count];
    }

    pub fn constWords(c: []const u16) []const u64 {
        assert(c.len == max_size);
        const p: [*]const u64 = @ptrCast(@alignCast(c[start_idx..].ptr));
        return p[0..word_count];
    }

    pub fn add(c: []u16, x: u16) bool {
        const w = words(c);
        const mask = @as(u64, 1) << @truncate(x);
        if (w[x >> 6] & mask != 0) return false;
        w[x >> 6] |= mask;
        setCardinality(c, getCardinality(c) + 1);
        return true;
    }

    pub fn remove(c: []u16, x: u16) bool {
        const w = words(c);
        const mask = @as(u64, 1) << @truncate(x);
        if (w[x >> 6] & mask == 0) return false;
        w[x >> 6] &= ~mask;
        setCardinality(c, getCardinality(c) - 1);
        return true;
    }

    pub fn has(c: []const u16, x: u16) bool {
        const w = constWords(c);
        return w[x >> 6] & (@as(u64, 1) << @truncate(x)) != 0;
    }

    pub fn minimum(c: []const u16) u16 {
        for (constWords(c), 0..) |w, i| {
            if (w != 0) return @intCast(i * 64 + @ctz(w));
        }
        unreachable; // callers check the cardinality first
    }

    pub fn maximum(c: []const u16) u16 {
        const w = constWords(c);
        var i = w.len;
        while (i > 0) {
            i -= 1;
            if (w[i] != 0) return @intCast(i * 64 + 63 - @clz(w[i]));
        }
        unreachable; // callers check the cardinality first
    }

    /// Recomputes the cardinality from the payload bits.
    pub fn cardinality(c: []const u16) u32 {
        var n: u32 = 0;
        for (constWords(c)) |w| n += @popCount(w);
        return n;
    }

    /// Words per @Vector chunk. word_count is a multiple of this, so the loops
    /// below need no scalar tail.
    const lanes = 8;
    const Chunk = @Vector(lanes, u64);

    /// The word operation `wordKernel` applies.
    const WordOp = enum { and_, andnot, or_ };

    /// One instantiation of `wordKernel`. The defaults describe the common
    /// kernel: rewrite the destination and count what it ends up holding.
    const Kernel = struct {
        op: WordOp,
        /// Write the result words to `dst`. False for the fused counters,
        /// which only ever read their operands.
        store: bool = true,
        /// Accumulate the result's cardinality. False only for the lazy union,
        /// where fastOr recounts once at the end instead.
        count: bool = true,
    };

    /// The one word loop behind every bitmap-container × bitmap-container
    /// kernel: `x` op `y` over the whole payload, a Chunk at a time, into
    /// `dst`. Returns the result's cardinality, or 0 when not counting.
    ///
    /// An in-place kernel passes the left operand's own words as both `dst` and
    /// `x`; nothing here reads a word after writing it, so the aliasing is
    /// safe. Every knob is comptime, so an instantiation is the plain loop it
    /// was hand-written as, with the store or the popcount folded away.
    fn wordKernel(
        comptime k: Kernel,
        dst: if (k.store) []u64 else void,
        x: []const u64,
        y: []const u64,
    ) u64 {
        var card: u64 = 0;
        var i: usize = 0;
        while (i < word_count) : (i += lanes) {
            const l: Chunk = x[i..][0..lanes].*;
            const r: Chunk = y[i..][0..lanes].*;
            const v = switch (k.op) {
                .and_ => l & r,
                .andnot => l & ~r,
                .or_ => l | r,
            };
            if (k.store) dst[i..][0..lanes].* = v;
            // @popCount of a Chunk is a @Vector(lanes, u7) — 7 bits is all
            // one lane's count needs — so reducing it as it comes would add
            // the lanes up in u7 and wrap at 128. Widen to u64 before reducing.
            if (k.count) card += @reduce(.Add, @as(Chunk, @popCount(v)));
        }
        return card;
    }

    /// b := b ∩ other, both bitmap containers.
    pub fn andBitmap(b: []u16, other: []const u16) void {
        const dst = words(b);
        const card = wordKernel(.{ .op = .and_ }, dst, dst, constWords(other));
        setCardinality(b, @intCast(card));
    }

    /// out := a ∩ b, all three bitmap containers. `out` is overwritten whole,
    /// header included. The out-of-place twin of andBitmap.
    pub fn andBitmapInto(out: []u16, a: []const u16, b: []const u16) void {
        const card = wordKernel(
            .{ .op = .and_ },
            words(out),
            constWords(a),
            constWords(b),
        );
        out[index_size] = max_size;
        setType(out, .bitmap);
        setCardinality(out, @intCast(card));
    }

    /// |a ∩ b| for two bitmap containers, counted without storing the result
    /// anywhere. The counting twin of andBitmapInto.
    pub fn andBitmapCardinality(a: []const u16, b: []const u16) u32 {
        const x = constWords(a);
        const y = constWords(b);
        return @intCast(wordKernel(.{ .op = .and_, .store = false }, {}, x, y));
    }

    /// b := b \ other, both bitmap containers.
    pub fn andNotBitmap(b: []u16, other: []const u16) void {
        const dst = words(b);
        const src = constWords(other);
        const card = wordKernel(.{ .op = .andnot }, dst, dst, src);
        setCardinality(b, @intCast(card));
    }

    /// b := b ∪ other, both bitmap containers. In `lazy` mode the cardinality
    /// is left as the invalid sentinel for fastOr to repair in one final pass,
    /// and the popcount is skipped along with it.
    pub fn orBitmap(b: []u16, other: []const u16, lazy: bool) void {
        const dst = words(b);
        const src = constWords(other);
        if (lazy or getCardinality(b) == invalid_cardinality) {
            _ = wordKernel(.{ .op = .or_, .count = false }, dst, dst, src);
            setCardinality(b, invalid_cardinality);
            return;
        }
        const card = wordKernel(.{ .op = .or_ }, dst, dst, src);
        setCardinality(b, @intCast(card));
    }

    /// b := b ∩ other, where `other` is an array container. The result stays
    /// a bitmap container: DESIGN.md rules out demoting a bitmap to an array.
    pub fn andArray(b: []u16, other: []const u16) void {
        const vals = array.values(other);
        const w = words(b);
        var k: usize = 0;
        var card: u64 = 0;
        for (w, 0..) |*word, i| {
            // The values of `other` that fall inside this word. `vals` is
            // ascending, so the cursor only ever moves forward.
            const hi = (i + 1) * 64;
            var mask: u64 = 0;
            while (k < vals.len and vals[k] < hi) : (k += 1) {
                mask |= @as(u64, 1) << @truncate(vals[k]);
            }
            word.* &= mask;
            card += @popCount(word.*);
        }
        setCardinality(b, @intCast(card));
    }

    /// b := b \ other, where `other` is an array container.
    pub fn andNotArray(b: []u16, other: []const u16) void {
        const w = words(b);
        var card = getCardinality(b);
        for (array.values(other)) |v| {
            const mask = @as(u64, 1) << @truncate(v);
            if (w[v >> 6] & mask == 0) continue;
            w[v >> 6] &= ~mask;
            card -= 1;
        }
        setCardinality(b, card);
    }

    /// Writes the bitmap container `c` into the array container `dst`, which
    /// must have room for c's values plus the free slot the invariant demands.
    /// The mirror of array.toBitmapInto.
    pub fn toArrayInto(dst: []u16, c: []const u16) void {
        const card = getCardinality(c);
        assert(start_idx + card < dst.len); // free-slot invariant
        var n: usize = 0;
        for (constWords(c), 0..) |word, i| {
            var w = word;
            while (w != 0) : (w &= w - 1) {
                dst[start_idx + n] = @intCast(i * 64 + @ctz(w));
                n += 1;
            }
        }
        assert(n == card);
        setType(dst, .array);
        setCardinality(dst, card);
    }

    /// b := b ∪ other, where `other` is an array container.
    pub fn orArray(b: []u16, other: []const u16, lazy: bool) void {
        const w = words(b);
        const vals = array.values(other);
        if (lazy or getCardinality(b) == invalid_cardinality) {
            for (vals) |v| w[v >> 6] |= @as(u64, 1) << @truncate(v);
            setCardinality(b, invalid_cardinality);
            return;
        }
        var card = getCardinality(b);
        for (vals) |v| {
            const mask = @as(u64, 1) << @truncate(v);
            if (w[v >> 6] & mask != 0) continue;
            w[v >> 6] |= mask;
            card += 1;
        }
        setCardinality(b, card);
    }
};

// ---------------------------------------------------------------------------
// Set operations between two containers
// ---------------------------------------------------------------------------

/// dst := dst ∩ src, computed in place with no allocation and no scratch
/// space.
///
/// An intersection is a subset of dst, so a two-pointer rewrite of dst never
/// overtakes itself. (sroar instead appends a fresh container and orphans the
/// old one — DESIGN.md, Go bug 6.) A bitmap dst stays a bitmap even when the
/// result is tiny: DESIGN.md rules out demoting a bitmap to an array.
pub fn containerAnd(dst: []u16, src: []const u16) void {
    switch (getType(dst)) {
        .array => switch (getType(src)) {
            .array => array.andArray(dst, src),
            .bitmap => array.andBitmap(dst, src),
        },
        .bitmap => switch (getType(src)) {
            .array => bitmap.andArray(dst, src),
            .bitmap => bitmap.andBitmap(dst, src),
        },
    }
}

/// buf := a ∩ b, built out of place: a two-operand And may touch neither
/// operand, and the size the result needs is only known once it exists. `buf`
/// must be max_size u16s long and 8-byte aligned; it is overwritten.
///
/// Returns the finished container, a slice of `buf`. It is bitmap-shaped only
/// when both operands are bitmap containers — the one case whose result can
/// outgrow an array container. A cardinality of 0 means an empty intersection.
pub fn containerAndInto(buf: []u16, a: []const u16, b: []const u16) []u16 {
    assert(buf.len == max_size);
    return switch (getType(a)) {
        .array => switch (getType(b)) {
            .array => finishArray(buf, setutil.intersection2by2(
                array.values(a),
                array.values(b),
                buf[start_idx..],
            )),
            .bitmap => finishArray(
                buf,
                array.andBitmapInto(buf[start_idx..], a, b),
            ),
        },
        .bitmap => switch (getType(b)) {
            .array => finishArray(
                buf,
                array.andBitmapInto(buf[start_idx..], b, a),
            ),
            .bitmap => blk: {
                bitmap.andBitmapInto(buf, a, b);
                break :blk buf;
            },
        },
    };
}

/// Wraps the `n` values a kernel has just written into buf's payload as a
/// finished array container. Every caller above bounds `n` by the cardinality
/// of an array operand, which the free-slot invariant keeps below the array
/// ceiling, so an array container always fits.
fn finishArray(buf: []u16, n: usize) []u16 {
    const sz = arraySizeFor(n).?;
    const out = buf[0..sz];
    @memset(out[start_idx + n ..], 0);
    out[index_size] = sz;
    setType(out, .array);
    setCardinality(out, @intCast(n));
    return out;
}

/// |a ∩ b|, counted without building the intersection: nothing is written and
/// neither container is read as anything but a `[]const u16`.
///
/// The one per-container-pair kernel behind all three of
/// `Bitmap.andCardinality`, `Bitmap.orCardinality` and
/// `Bitmap.andNotCardinality`: a union's size is |a| + |b| - |a ∩ b| and a
/// difference's is |a| - |a ∩ b|, both of which the containers' own headers
/// finish off, so counting the overlap is all any of them actually has to do.
pub fn containerAndCardinality(a: []const u16, b: []const u16) u32 {
    return switch (getType(a)) {
        .array => switch (getType(b)) {
            .array => @intCast(setutil.intersection2by2Cardinality(
                array.values(a),
                array.values(b),
            )),
            .bitmap => array.andBitmapCardinality(a, b),
        },
        .bitmap => switch (getType(b)) {
            // The array side drives the loop whichever operand it is.
            .array => array.andBitmapCardinality(b, a),
            .bitmap => bitmap.andBitmapCardinality(a, b),
        },
    };
}

/// dst := dst \ src, computed in place. Like containerAnd, the result is a
/// subset of dst, so no allocation or scratch space is needed.
pub fn containerAndNot(dst: []u16, src: []const u16) void {
    switch (getType(dst)) {
        .array => switch (getType(src)) {
            .array => array.andNotArray(dst, src),
            .bitmap => array.andNotBitmap(dst, src),
        },
        .bitmap => switch (getType(src)) {
            .array => bitmap.andNotArray(dst, src),
            .bitmap => bitmap.andNotBitmap(dst, src),
        },
    }
}

/// dst := dst ∪ src.
///
/// Returns null when the union was completed inside `dst`. Otherwise the result
/// did not fit and was built in `buf` instead; the caller must install it (see
/// Bitmap.copyAt), which may grow or retype the container at dst's offset.
/// `buf` must be max_size u16s long and 8-byte aligned.
///
/// In `lazy` mode a bitmap result keeps the invalid-cardinality sentinel rather
/// than being recounted on every step; fastOr repairs it once at the end.
pub fn containerOr(
    dst: []u16,
    src: []const u16,
    buf: []u16,
    lazy: bool,
) ?[]u16 {
    assert(buf.len == max_size);
    switch (getType(dst)) {
        .array => switch (getType(src)) {
            .array => {
                const combined: usize =
                    getCardinality(dst) + getCardinality(src);
                // DESIGN.md phrases this threshold as "combined > 4096", which
                // comes from sroar's variable-sized array containers. Ours stop
                // at max_array_size, so the union becomes a bitmap as soon as
                // no array container can hold it — a stricter, reachable
                // bound.
                if (arraySizeFor(combined) == null) {
                    array.toBitmapInto(buf, dst);
                    bitmap.orArray(buf, src, lazy);
                    return buf;
                }
                // The merge reads both containers, so it cannot run in place:
                // dst's own values would be overwritten before being read.
                const n = setutil.union2by2(
                    array.values(dst),
                    array.values(src),
                    buf[start_idx..],
                );
                const sz = arraySizeFor(n).?;
                const out = buf[0..sz];
                @memset(out[start_idx + n ..], 0);
                out[index_size] = @intCast(sz);
                setType(out, .array);
                setCardinality(out, @intCast(n));
                return out;
            },
            .bitmap => {
                // A bitmap operand forces a bitmap result, which never fits in
                // an array container's slot.
                @memcpy(buf, src);
                bitmap.orArray(buf, dst, lazy);
                return buf;
            },
        },
        .bitmap => {
            switch (getType(src)) {
                .array => bitmap.orArray(dst, src, lazy),
                .bitmap => bitmap.orBitmap(dst, src, lazy),
            }
            return null;
        },
    }
}
