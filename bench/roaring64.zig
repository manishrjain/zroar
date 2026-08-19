//! The slice of CRoaring's `roaring64_bitmap_t` C API that the bench and the
//! difftest drive, wrapped just enough to read like Zig.
//!
//! CRoaring itself is compiled from a checkout of its repository (see
//! `Croaring` in build.zig and bench/fetch_croaring.sh); this file declares the
//! handful of its functions that are called, by hand rather than through
//! `@cImport`. The headers pull in CRoaring's internal container code, which
//! Zig's C translator does not take, and every type that crosses here is an
//! opaque pointer, an integer or a bool, so the declarations are short and the
//! C ABI carries them. Nothing here does work of its own — every method is one
//! C call — so `-r64` timings measure CRoaring, not the wrapper. Method names
//! follow roaring-zig's `Bitmap64`, which the bench was first written against;
//! `_and`/`_or` carry the underscore because `and`/`or` are keywords.

/// The C declarations, as roaring64.h spells them.
pub const c = struct {
    pub const roaring64_bitmap_t = opaque {};
    pub const roaring64_iterator_t = opaque {};

    pub extern fn roaring64_bitmap_create() ?*roaring64_bitmap_t;
    pub extern fn roaring64_bitmap_free(r: *roaring64_bitmap_t) void;
    pub extern fn roaring64_bitmap_copy(r: *const roaring64_bitmap_t) ?*roaring64_bitmap_t;
    pub extern fn roaring64_bitmap_of_ptr(n_args: usize, vals: [*]const u64) ?*roaring64_bitmap_t;
    pub extern fn roaring64_bitmap_add(r: *roaring64_bitmap_t, val: u64) void;
    pub extern fn roaring64_bitmap_add_checked(r: *roaring64_bitmap_t, val: u64) bool;
    pub extern fn roaring64_bitmap_add_many(r: *roaring64_bitmap_t, n_args: usize, vals: [*]const u64) void;
    pub extern fn roaring64_bitmap_remove(r: *roaring64_bitmap_t, val: u64) void;
    pub extern fn roaring64_bitmap_remove_checked(r: *roaring64_bitmap_t, val: u64) bool;
    pub extern fn roaring64_bitmap_contains(r: *const roaring64_bitmap_t, val: u64) bool;
    pub extern fn roaring64_bitmap_get_cardinality(r: *const roaring64_bitmap_t) u64;
    pub extern fn roaring64_bitmap_minimum(r: *const roaring64_bitmap_t) u64;
    pub extern fn roaring64_bitmap_maximum(r: *const roaring64_bitmap_t) u64;
    pub extern fn roaring64_bitmap_run_optimize(r: *roaring64_bitmap_t) bool;
    pub extern fn roaring64_bitmap_shrink_to_fit(r: *roaring64_bitmap_t) usize;
    pub extern fn roaring64_bitmap_portable_size_in_bytes(r: *const roaring64_bitmap_t) usize;
    pub extern fn roaring64_bitmap_portable_serialize(r: *const roaring64_bitmap_t, buf: [*]u8) usize;
    pub extern fn roaring64_bitmap_portable_deserialize_safe(buf: [*]const u8, maxbytes: usize) ?*roaring64_bitmap_t;
    pub extern fn roaring64_bitmap_frozen_size_in_bytes(r: *const roaring64_bitmap_t) usize;
    pub extern fn roaring64_bitmap_frozen_serialize(r: *const roaring64_bitmap_t, buf: [*]u8) usize;
    pub extern fn roaring64_bitmap_frozen_view(buf: [*]const u8, maxbytes: usize) ?*roaring64_bitmap_t;
    pub extern fn roaring64_bitmap_to_uint64_array(r: *const roaring64_bitmap_t, out: [*]u64) void;
    pub extern fn roaring64_bitmap_and(r1: *const roaring64_bitmap_t, r2: *const roaring64_bitmap_t) ?*roaring64_bitmap_t;
    pub extern fn roaring64_bitmap_and_cardinality(r1: *const roaring64_bitmap_t, r2: *const roaring64_bitmap_t) u64;
    pub extern fn roaring64_bitmap_or(r1: *const roaring64_bitmap_t, r2: *const roaring64_bitmap_t) ?*roaring64_bitmap_t;
    pub extern fn roaring64_bitmap_or_cardinality(r1: *const roaring64_bitmap_t, r2: *const roaring64_bitmap_t) u64;
    pub extern fn roaring64_bitmap_or_inplace(r1: *roaring64_bitmap_t, r2: *const roaring64_bitmap_t) void;
    pub extern fn roaring64_bitmap_andnot(r1: *const roaring64_bitmap_t, r2: *const roaring64_bitmap_t) ?*roaring64_bitmap_t;
    pub extern fn roaring64_bitmap_andnot_cardinality(r1: *const roaring64_bitmap_t, r2: *const roaring64_bitmap_t) u64;
    pub extern fn roaring64_iterator_create(r: *const roaring64_bitmap_t) ?*roaring64_iterator_t;
    pub extern fn roaring64_iterator_free(it: *roaring64_iterator_t) void;
    pub extern fn roaring64_iterator_has_value(it: *const roaring64_iterator_t) bool;
    pub extern fn roaring64_iterator_value(it: *const roaring64_iterator_t) u64;
    pub extern fn roaring64_iterator_advance(it: *roaring64_iterator_t) bool;
};

/// A `roaring64_bitmap_t`. Only ever handled by pointer; the C side owns the
/// memory, so every constructor pairs with `free`.
pub const Bitmap64 = opaque {
    fn raw(self: *const Bitmap64) *const c.roaring64_bitmap_t {
        return @ptrCast(self);
    }

    fn rawMut(self: *Bitmap64) *c.roaring64_bitmap_t {
        return @ptrCast(self);
    }

    fn wrap(ptr: ?*c.roaring64_bitmap_t) error{OutOfMemory}!*Bitmap64 {
        return @ptrCast(ptr orelse return error.OutOfMemory);
    }

    pub fn create() !*Bitmap64 {
        return wrap(c.roaring64_bitmap_create());
    }

    pub fn fromSlice(vals: []const u64) !*Bitmap64 {
        return wrap(c.roaring64_bitmap_of_ptr(vals.len, vals.ptr));
    }

    pub fn copy(self: *const Bitmap64) !*Bitmap64 {
        return wrap(c.roaring64_bitmap_copy(self.raw()));
    }

    /// `roaring64_bitmap_portable_deserialize_safe`: bounded by `buf.len`.
    pub fn portableDeserializeSafe(buf: []const u8) !*Bitmap64 {
        return wrap(c.roaring64_bitmap_portable_deserialize_safe(buf.ptr, buf.len));
    }

    pub fn free(self: *Bitmap64) void {
        c.roaring64_bitmap_free(self.rawMut());
    }

    pub fn add(self: *Bitmap64, val: u64) void {
        c.roaring64_bitmap_add(self.rawMut(), val);
    }

    /// True if `val` was not already present.
    pub fn addChecked(self: *Bitmap64, val: u64) bool {
        return c.roaring64_bitmap_add_checked(self.rawMut(), val);
    }

    pub fn addMany(self: *Bitmap64, vals: []const u64) void {
        c.roaring64_bitmap_add_many(self.rawMut(), vals.len, vals.ptr);
    }

    pub fn remove(self: *Bitmap64, val: u64) void {
        c.roaring64_bitmap_remove(self.rawMut(), val);
    }

    /// True if `val` was present.
    pub fn removeChecked(self: *Bitmap64, val: u64) bool {
        return c.roaring64_bitmap_remove_checked(self.rawMut(), val);
    }

    pub fn contains(self: *const Bitmap64, val: u64) bool {
        return c.roaring64_bitmap_contains(self.raw(), val);
    }

    pub fn cardinality(self: *const Bitmap64) u64 {
        return c.roaring64_bitmap_get_cardinality(self.raw());
    }

    /// Undefined on an empty bitmap, as in C.
    pub fn minimum(self: *const Bitmap64) u64 {
        return c.roaring64_bitmap_minimum(self.raw());
    }

    /// Undefined on an empty bitmap, as in C.
    pub fn maximum(self: *const Bitmap64) u64 {
        return c.roaring64_bitmap_maximum(self.raw());
    }

    /// Converts containers to run containers where that is smaller. True if
    /// anything changed.
    pub fn runOptimize(self: *Bitmap64) bool {
        return c.roaring64_bitmap_run_optimize(self.rawMut());
    }

    pub fn portableSizeInBytes(self: *const Bitmap64) usize {
        return c.roaring64_bitmap_portable_size_in_bytes(self.raw());
    }

    /// Writes the portable format into `buf`, which must hold
    /// `portableSizeInBytes()`; returns the bytes written.
    pub fn portableSerialize(self: *const Bitmap64, buf: []u8) usize {
        return c.roaring64_bitmap_portable_serialize(self.raw(), buf.ptr);
    }

    /// Trims every container to its contents; returns the bytes given back.
    /// Required before the frozen calls below.
    pub fn shrinkToFit(self: *Bitmap64) usize {
        return c.roaring64_bitmap_shrink_to_fit(self.rawMut());
    }

    /// The frozen format is CRoaring's memory layout written out as-is: a
    /// `frozenView` over it is a read-only bitmap backed by the buffer, which
    /// makes it the like-for-like counterpart of zroar's format. Not stable
    /// across CRoaring releases, and only readable by CRoaring. Buffers must be
    /// 64-byte aligned.
    pub fn frozenSizeInBytes(self: *const Bitmap64) usize {
        return c.roaring64_bitmap_frozen_size_in_bytes(self.raw());
    }

    /// Writes the frozen format into `buf`, which must hold
    /// `frozenSizeInBytes()`; returns the bytes written.
    pub fn frozenSerialize(self: *const Bitmap64, buf: []align(64) u8) usize {
        return c.roaring64_bitmap_frozen_serialize(self.raw(), buf.ptr);
    }

    /// A read-only bitmap over `buf`, which must outlive it. Freed with `free`
    /// like any other; only the view's own bookkeeping is released.
    pub fn frozenView(buf: []align(64) const u8) !*Bitmap64 {
        return wrap(c.roaring64_bitmap_frozen_view(buf.ptr, buf.len));
    }

    /// Unpacks every value, ascending, into `out`, which must hold
    /// `cardinality()` of them.
    pub fn toUint64Array(self: *const Bitmap64, out: []u64) void {
        c.roaring64_bitmap_to_uint64_array(self.raw(), out.ptr);
    }

    pub fn _and(self: *const Bitmap64, other: *const Bitmap64) !*Bitmap64 {
        return wrap(c.roaring64_bitmap_and(self.raw(), other.raw()));
    }

    pub fn _or(self: *const Bitmap64, other: *const Bitmap64) !*Bitmap64 {
        return wrap(c.roaring64_bitmap_or(self.raw(), other.raw()));
    }

    pub fn _orInPlace(self: *Bitmap64, other: *const Bitmap64) void {
        c.roaring64_bitmap_or_inplace(self.rawMut(), other.raw());
    }

    pub fn _andCardinality(self: *const Bitmap64, other: *const Bitmap64) u64 {
        return c.roaring64_bitmap_and_cardinality(self.raw(), other.raw());
    }

    pub fn _orCardinality(self: *const Bitmap64, other: *const Bitmap64) u64 {
        return c.roaring64_bitmap_or_cardinality(self.raw(), other.raw());
    }

    pub fn _andnot(self: *const Bitmap64, other: *const Bitmap64) !*Bitmap64 {
        return wrap(c.roaring64_bitmap_andnot(self.raw(), other.raw()));
    }

    pub fn _andnotCardinality(self: *const Bitmap64, other: *const Bitmap64) u64 {
        return c.roaring64_bitmap_andnot_cardinality(self.raw(), other.raw());
    }

    /// Positioned on the first value. The iterator allocates, hence the error.
    pub fn iterator(self: *const Bitmap64) !Iterator {
        const it = c.roaring64_iterator_create(self.raw()) orelse return error.OutOfMemory;
        return .{ .it = it };
    }
};

pub const Iterator = struct {
    it: *c.roaring64_iterator_t,

    pub fn free(self: *Iterator) void {
        c.roaring64_iterator_free(self.it);
    }

    pub fn hasValue(self: *const Iterator) bool {
        return c.roaring64_iterator_has_value(self.it);
    }

    /// The value under the cursor, or null once past the end; advances.
    pub fn next(self: *Iterator) ?u64 {
        if (!c.roaring64_iterator_has_value(self.it)) return null;
        const v = c.roaring64_iterator_value(self.it);
        _ = c.roaring64_iterator_advance(self.it);
        return v;
    }
};
