// Copyright 2026 Manish R Jain
// SPDX-License-Identifier: Apache-2.0

//! Zero-filling without going through `memset`.
//!
//! `@memset` lowers to a call to `memset`, and in a Zig 0.16 program that
//! links libc the symbol resolves to compiler_rt's copy rather than libc's —
//! a byte-at-a-time loop, unlike its `memcpy` neighbour, which got a proper
//! implementation. (Upstream has a fix in the works for 0.17.) zroar zeroes
//! only where zeros are data — a bitmap container's payload, `compact`'s
//! output buffer, a fresh bitmap's first bytes — but a bitmap container is
//! 8 KB and `compact` rewrites everything, so the slow loop still cost real
//! time wherever it was kept.
//!
//! `zero` stores 64 bytes per step instead, then finishes with single stores
//! of 32, 16, 8, 4, 2 and 1 bytes — straight-line code, no loop. Measured
//! against glibc's memset it is even from 1 KB up and ahead below (no call).
//!
//! Two details are load-bearing. The empty `asm volatile` in the loop: without
//! it LLVM recognises the loop as a memset idiom and turns it right back into
//! the call this file exists to avoid (the tail needs none — it has no loop to
//! recognise; it used to be a byte loop, and that one did get turned into a
//! `memset` call). And the two stores per iteration: a one-store loop is
//! short enough that where it lands decides its speed — straddling a 64-byte
//! boundary halved it (Zen 3, measured 2×) — and as `zero` is inlined at a
//! dozen sites it lands everywhere. Two stores per trip keep a store a cycle
//! either way.

const std = @import("std");

const Chunk = @Vector(32, u8);

/// Sets every element of `s` to zero. `s` is a slice of any type that is
/// zero when all its bytes are.
pub fn zero(s: anytype) void {
    const bytes = std.mem.sliceAsBytes(s);
    var p: [*]u8 = bytes.ptr; // drop the source alignment: p walks in bytes
    var n = bytes.len;
    const z: Chunk = @splat(0);
    while (n >= 64) : (n -= 64) {
        p[0..32].* = z;
        p[32..64].* = z;
        p += 64;
        asm volatile ("" ::: .{ .memory = true });
    }
    if (n >= 32) {
        p[0..32].* = z;
        p += 32;
        n -= 32;
    }
    if (n >= 16) {
        p[0..16].* = @as(@Vector(16, u8), @splat(0));
        p += 16;
        n -= 16;
    }
    if (n >= 8) {
        p[0..8].* = @as(@Vector(8, u8), @splat(0));
        p += 8;
        n -= 8;
    }
    if (n >= 4) {
        p[0..4].* = @as(@Vector(4, u8), @splat(0));
        p += 4;
        n -= 4;
    }
    if (n >= 2) {
        p[0..2].* = @as(@Vector(2, u8), @splat(0));
        p += 2;
        n -= 2;
    }
    if (n >= 1) p[0] = 0;
}
