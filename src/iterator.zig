//! Forward iterator over the values of a Bitmap, in ascending order.
//!
//! Unlike sroar's Go iterator, which uses the value 0 as its end sentinel and
//! therefore cannot distinguish "done" from "the bitmap contains 0", `next`
//! returns `?u64`.

const std = @import("std");
const assert = std.debug.assert;
const container = @import("container.zig");
const zroar = @import("zroar.zig");

pub const Iterator = struct {
    bm: *const zroar.Bitmap,

    /// Index of the container being walked; == numKeys() once exhausted.
    key_idx: usize,
    /// Array containers: payload index of the next value to emit.
    arr_idx: usize,
    /// Bitmap containers: index of the word held in `word`.
    word_idx: usize,
    /// Bitmap containers: the bits of words[word_idx] not yet emitted.
    word: u64,

    /// Positions a fresh iterator at the first value of the bitmap.
    /// Valid only until the bitmap is mutated.
    pub fn init(bm: *const zroar.Bitmap) Iterator {
        var it = Iterator{
            .bm = bm,
            .key_idx = 0,
            .arr_idx = 0,
            .word_idx = 0,
            .word = 0,
        };
        it.loadContainer();
        return it;
    }

    /// Returns the next value in ascending order, or null when exhausted.
    pub fn next(it: *Iterator) ?u64 {
        const ks = it.bm.keys();
        while (it.key_idx < ks.numKeys()) {
            const key = ks.key(it.key_idx);
            const c = it.bm.getContainer(ks.offset(it.key_idx));
            switch (container.getType(c)) {
                .array => {
                    const vals = container.array.values(c);
                    if (it.arr_idx < vals.len) {
                        const v = vals[it.arr_idx];
                        it.arr_idx += 1;
                        return key | v;
                    }
                },
                .bitmap => {
                    const w = container.bitmap.constWords(c);
                    while (it.word == 0 and it.word_idx + 1 < w.len) {
                        it.word_idx += 1;
                        it.word = w[it.word_idx];
                    }
                    if (it.word != 0) {
                        const bit = @ctz(it.word);
                        it.word &= it.word - 1; // clear the lowest set bit
                        return key | (it.word_idx * 64 + bit);
                    }
                },
            }
            it.key_idx += 1;
            it.loadContainer();
        }
        return null;
    }

    /// Resets the per-container cursor for the container at key_idx.
    fn loadContainer(it: *Iterator) void {
        it.arr_idx = 0;
        it.word_idx = 0;
        it.word = 0;

        const ks = it.bm.keys();
        if (it.key_idx >= ks.numKeys()) return;
        const c = it.bm.getContainer(ks.offset(it.key_idx));
        if (container.getType(c) == .bitmap) {
            it.word = container.bitmap.constWords(c)[0];
        }
    }
};
