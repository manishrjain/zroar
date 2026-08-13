//! Optional counters for the work zroar does moving memory around.
//!
//! A roaring bitmap in one flat buffer trades pointer chasing for memmoves, and
//! which memmoves dominate is rarely the one you would guess. Measuring a
//! workload's wall clock says something is slow; these say *what* moved and how
//! much, which is what tells you whether an idea can pay before you build it.
//!
//! The counters live on the `Bitmap`, not in its buffer: the serialized layout
//! is untouched and two bitmaps never share a count. Nothing here is global, so
//! nothing here races.
//!
//! Disabled by default, and then genuinely free: `Sink` is an empty struct, so
//! the field on `Bitmap` is zero-bit, every pointer to it is zero-bit, and each
//! `bump` is behind a comptime `enabled` that leaves nothing behind. To turn
//! the counters on, declare this in the root source file of your program:
//!
//! ```zig
//! pub const zroar_track_stats = true;
//! ```
//!
//! They are also on in test builds, so the accounting can be tested.
//!
//! Typical use, and the shape of the question they answer:
//!
//! ```zig
//! for (values) |v| _ = try bm.set(v);
//! // bm.counters.array_shifted_u16 dwarfing bm.counters.cleanup_moved_u16
//! // means the time is in array.add opening slots, not in compaction, so
//! // deferring compaction cannot help much.
//! ```

const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");

/// Whether the counters are live. Comptime, so `bump` disappears when false.
pub const enabled: bool = builtin.is_test or
    (@hasDecl(root, "zroar_track_stats") and root.zroar_track_stats);

/// Every counter is a u16 count or a u16 volume, never bytes: the buffer is a
/// `[]u16` and reporting in its own units avoids a factor-of-two mistake.
pub const Counters = struct {
    /// Calls to `Bitmap.set`, as the denominator for everything else.
    sets: u64 = 0,
    /// Mutations whose container came from the bitmap's one-entry cursor
    /// rather than a keys-node search. Sequential row-ids approach one hit
    /// per set; scattered keys push this toward zero.
    cursor_hits: u64 = 0,

    /// Array containers that outgrew their size and stepped up the ladder.
    container_grows: u64 = 0,
    /// Of those, the ones not last in the buffer, which are copied to the end
    /// and leave a dead slot behind.
    container_relocs: u64 = 0,
    /// u16s zeroed when a relocated container's old slot is abandoned.
    abandoned_u16: u64 = 0,

    /// Times the whole buffer had to grow.
    buffer_grows: u64 = 0,
    /// u16s copied by those growths. Stays 0 when the allocator can extend the
    /// mapping in place instead of moving it.
    buffer_copied_u16: u64 = 0,

    /// Compaction passes over the buffer.
    cleanups: u64 = 0,
    /// u16s memmoved by them.
    cleanup_moved_u16: u64 = 0,
    /// Keys visited fixing up offsets, which happens once per hole closed, so
    /// this grows as holes x keys.
    cleanup_key_visits: u64 = 0,

    /// u16s memmoved by `array.add` opening a slot inside a container. Usually
    /// the largest number here for a build-by-set workload: an insert into the
    /// middle of a container shifts its whole tail.
    array_shifted_u16: u64 = 0,

    /// Times the keys node was enlarged.
    node_grows: u64 = 0,
    /// u64s memmoved opening a slot in the keys node. A key inserted out of
    /// order shifts every key above it, so a stream of unordered keys makes
    /// this quadratic.
    node_shifted_u64: u64 = 0,
};

/// Which counter to add to. An enum rather than a field name so a typo is a
/// compile error.
pub const Counter = std.meta.FieldEnum(Counters);

/// What a `Bitmap` carries. `Counters` when enabled, and an empty struct when
/// not, so a disabled build pays nothing per bitmap rather than ~100 bytes.
/// A consumer reading `bm.counters` therefore guards on `enabled` first.
pub const Sink = if (enabled) Counters else struct {};

/// Adds `n` to one of `sink`'s counters. The condition is comptime, so when
/// disabled the body is never analysed and nothing is emitted.
pub inline fn bump(sink: *Sink, comptime which: Counter, n: u64) void {
    if (comptime enabled) {
        @field(sink.*, @tagName(which)) += n;
    }
}
