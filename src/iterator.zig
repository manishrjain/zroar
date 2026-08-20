// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! Forward iterator over the values of a Bitmap, in ascending order.
//!
//! Unlike sroar's Go iterator, which uses the value 0 as its end sentinel and
//! therefore cannot distinguish "done" from "the bitmap contains 0", `next`
//! returns `?u64`.
//!
//! The iterator caches the current container — its key and a slice of its
//! payload — so the per-value path never re-derives the keys node or the
//! container from the bitmap. That keeps `next` down to two compares and a
//! handful of ops on the hot paths, and it is also what makes the iteration
//! benchmarks stable: a fatter per-value path was observed swinging ~30% from
//! code placement alone (a 3-cycle loop straddling a fetch boundary pays a
//! cycle; see zero.zig for the same story), while the slim one has less to
//! lose and container advancement is out of line in `nextSlow`.

const std = @import("std");
const assert = std.debug.assert;
const container = @import("container.zig");
const zroar = @import("zroar.zig");

pub const Iterator = struct {
    bm: *const zroar.Bitmap,

    /// Index of the container being walked; == numKeys() once exhausted.
    key_idx: usize,
    /// The current container's key (already masked to its top 48 bits).
    key: u64,
    /// Array containers: the values not yet emitted.
    vals: []const u16,
    /// Bitmap containers: the walk through the payload words.
    bits: Bits,

    /// Where a walk through a bitmap container's payload stands. Held by
    /// value inside the iterator: `it.bits.word` is a load at an offset from
    /// `it` exactly as a flat field would be — the struct groups names, not
    /// memory — and the methods inline into `next` like everything else.
    const Bits = struct {
        /// The container's payload words; empty while in an array container.
        words: []const u64,
        /// Index of the word held in `word`.
        word_idx: usize,
        /// The bits of words[word_idx] not yet emitted.
        word: u64,

        const empty: Bits = .{ .words = &.{}, .word_idx = 0, .word = 0 };

        /// Emits the lowest pending bit as a container-local value.
        /// The caller guarantees `word != 0`.
        fn pop(b: *Bits) u64 {
            const bit: u64 = @ctz(b.word);
            b.word &= b.word - 1; // clear the lowest set bit
            return b.word_idx * 64 + bit;
        }

        /// Moves to the next nonzero word, or returns false when the
        /// container has none left.
        fn advance(b: *Bits) bool {
            while (b.word_idx + 1 < b.words.len) {
                b.word_idx += 1;
                b.word = b.words[b.word_idx];
                if (b.word != 0) return true;
            }
            return false;
        }
    };

    /// Positions a fresh iterator at the first value of the bitmap.
    /// Valid only until the bitmap is mutated.
    pub fn init(bm: *const zroar.Bitmap) Iterator {
        var it = Iterator{
            .bm = bm,
            .key_idx = 0,
            .key = 0,
            .vals = &.{},
            .bits = .empty,
        };
        _ = it.loadContainer();
        return it;
    }

    /// Returns the next value in ascending order, or null when exhausted.
    ///
    /// The bitmap check comes first: whichever check loses this race costs
    /// its containers one predicted branch per value, and bitmap containers
    /// hold the most values by construction, so they get the front spot
    /// (measured: -15% on a dense set for +3% on an array-heavy one).
    ///
    /// The container-has-a-value checks appear again in `nextSlow`, and that
    /// duplication is deliberate: every deduplication tried (a shared helper
    /// behind an optional, a single merged Bits.next, delegation back into
    /// this function) measured 1.6x-3.4x slower, because each one tipped
    /// LLVM out of keeping the iterator in registers — the state spilled to
    /// the stack, a store per value. Exactly this shape stays promoted.
    pub fn next(it: *Iterator) ?u64 {
        if (it.bits.word != 0) return it.key | it.bits.pop();
        if (it.vals.len != 0) {
            const v = it.vals[0];
            it.vals = it.vals[1..];
            return it.key | v;
        }
        if (it.bits.advance()) return it.key | it.bits.pop();
        return it.nextSlow();
    }

    /// The current container is exhausted: walk containers until one yields
    /// a value, or the keys run out. Everything within a container is
    /// `next`'s business; this is only the transition between them.
    fn nextSlow(it: *Iterator) ?u64 {
        while (true) {
            it.key_idx += 1;
            if (!it.loadContainer()) return null;
            if (it.vals.len != 0) {
                const v = it.vals[0];
                it.vals = it.vals[1..];
                return it.key | v;
            }
            if (it.bits.word != 0) return it.key | it.bits.pop();
            if (it.bits.advance()) return it.key | it.bits.pop();
            // A container that is present but empty (e.g. emptied in place by
            // an intersection): fall through to the next one.
        }
    }

    /// Caches the container at key_idx, or returns false when exhausted.
    fn loadContainer(it: *Iterator) bool {
        it.vals = &.{};
        it.bits = .empty;

        const ks = it.bm.keys();
        if (it.key_idx >= ks.numKeys()) return false;
        it.key = ks.key(it.key_idx);
        const c = it.bm.getContainer(ks.val(it.key_idx));
        switch (container.getType(c)) {
            .array => it.vals = container.array.values(c),
            .bitmap => {
                it.bits.words = container.bitmap.constWords(c);
                it.bits.word = it.bits.words[0];
            },
        }
        return true;
    }
};
