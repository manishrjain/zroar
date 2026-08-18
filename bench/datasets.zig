//! Fixtures for the zroar vs roaring64 benchmarks.
//!
//! Everything the benchmarks touch is built here, untimed: the input bitmaps,
//! their serialized forms for both libraries, the buffers cold rows open into.
//! A benchmark function then does nothing but the work it is named after.
//!
//! Two kinds of fixture. The per-file set (`files_*`) is what CRoaring's own
//! microbenchmark loads: one bitmap per input file, values exactly as the file
//! holds them, `runOptimize` applied on the CRoaring side, as `bench.h` does.
//! Three input shapes feed it: `realdata`, a directory of CRoaring's benchmark
//! files (comma-separated u32, one bitmap per file); `--oltp` and
//! `--oltp-random`, a generated database secondary index, one posting list per
//! indexed value over one table's row-ids — dense auto-increment ids in the
//! first, ids scattered over the whole u64 range in the second. That is the
//! shape the realdata sets do not cover: scattered bits with little for a run
//! container to find, and writes that append.
//!
//! The other fixture, `Synth`, is one bitmap (per side) of a shape a
//! synthetic-grid row asks for — `count` values `i * step`, or 2^20 random
//! values under a bitmask — rebuilt for each row and torn down after it, as
//! CRoaring's `synthetic_bench.cpp` does inside each benchmark function.

const std = @import("std");
const zroar = @import("zroar");
const roaring64 = @import("roaring64");

/// Which per-file input shape to build.
pub const Mode = enum {
    /// A directory of CRoaring benchmark files.
    realdata,
    /// Posting lists over auto-increment row-ids.
    oltp,
    /// Posting lists over row-ids scattered across the whole u64 range.
    oltp_random,
};

/// The OLTP modes' index: `oltp_lists` posting lists over a table of
/// `oltp_rows` rows. Sizes are Zipf shaped — a few values match most of the
/// table, most match almost none of it — which is how a real secondary index
/// looks and which is what makes the size-weighted pick in MixedOLTP mean
/// something. The sizes sum to roughly 3M row-ids.
pub const oltp_rows = 10_000_000;
pub const oltp_lists = 200;
pub const oltp_head_size = 500_000;
pub const oltp_zipf_exponent = 1.07;
pub const oltp_min_size = 8;

/// The Random rows' fixture holds this many draws under the bitmask, as
/// CRoaring's does. Duplicates are kept, so the bitmap holds fewer distinct
/// values and probes under a narrow mask mostly hit.
pub const random_fill = 1 << 20;

/// Every random choice in here comes from this one seed, so a rerun sees the
/// same data down to the last probe. CRoaring's synthetic bench seeds from
/// `std::random_device`; a fixed seed is the one deliberate departure, and the
/// price of insisting both sides see identical values.
const seed = 0x5EED_B0A7;

pub const DataSet = struct {
    /// Used for every allocation a benchmark makes; CRoaring mallocs, so zroar
    /// must too for the comparison to be about the data structures.
    allocator: std.mem.Allocator,
    /// For a row that has to keep part of itself out of the timing.
    io: std.Io,

    /// The per-file bitmaps, open and never mutated by any row.
    files_zroar: []zroar.Bitmap,
    files_r64: []*roaring64.Bitmap64,

    /// The same bitmaps serialized: zroar's one format, and CRoaring's two.
    /// The frozen buffers are 64-byte aligned because `frozenView` insists.
    zr_bufs: [][]align(8) u8,
    r64_portable_bufs: [][]u8,
    r64_frozen_bufs: [][]align(64) u8,

    /// Where the cold rows open the per-file bitmaps. Preallocated because
    /// those rows measure opening, not sizing an array.
    zr_open: []zroar.Bitmap,
    r64_open: []*roaring64.Bitmap64,

    /// Where ToArray64-r64 unpacks a bitmap. Sized for the largest file.
    array_buf: []u64,

    /// Largest value in any file; RandomAccess64 probes fractions of it.
    max_value: u64,

    /// Running total of the file cardinalities: `file_cum[i]` counts files
    /// 0..=i. MixedOLTP picks a posting list with probability proportional to
    /// its size by dropping a random point below the last entry and finding the
    /// file it lands in.
    file_cum: []u64,

    /// The row-id space MixedOLTP reads from, inclusive of both ends.
    row_id_max: u64,

    /// The first row-id MixedOLTP appends. Row-ids are handed out in increasing
    /// order, so everything from here up is fresh.
    row_id_next: u64,

    /// Values across the per-file set.
    values: u64,

    /// Bytes of the per-file set serialized, summed, per format.
    zr_bytes: usize,
    r64_portable_bytes: usize,
    r64_frozen_bytes: usize,
    /// The portable bytes before `runOptimize`: how much run containers buy
    /// CRoaring on this data. zroar has none, so a set where this is large is
    /// one where the comparison is partly about run containers.
    r64_portable_bytes_norun: usize,

    /// The synthetic-grid fixture, empty between rows.
    synth: Synth,

    pub fn deinit(self: *DataSet) void {
        const a = self.allocator;
        self.synth.reset();
        for (self.files_zroar) |*bm| bm.deinit();
        for (self.files_r64) |bm| bm.free();
        for (self.zr_bufs) |b| a.free(b);
        for (self.r64_portable_bufs) |b| a.free(b);
        for (self.r64_frozen_bufs) |b| a.free(b);
        a.free(self.files_zroar);
        a.free(self.files_r64);
        a.free(self.zr_bufs);
        a.free(self.r64_portable_bufs);
        a.free(self.r64_frozen_bufs);
        a.free(self.zr_open);
        a.free(self.r64_open);
        a.free(self.array_buf);
        a.free(self.file_cum);
    }
};

/// One shape for one synthetic-grid row, on both sides. Built by a row's setup
/// hook, freed by its teardown, so peak memory is one shape, not the grid.
pub const Synth = struct {
    allocator: std.mem.Allocator,

    /// The row's parameters, for bodies that rebuild the shape themselves.
    count: usize = 0,
    step: u64 = 0,
    mask: u64 = 0,

    /// The shape, when the row wants it prebuilt. The Random rows mutate
    /// theirs, which is why these are not const.
    zr: ?zroar.Bitmap = null,
    r64: ?*roaring64.Bitmap64 = null,

    /// The shape serialized, for the Deserialize rows to open.
    zr_buf: ?[]align(8) u8 = null,
    r64_portable_buf: ?[]u8 = null,
    r64_frozen_buf: ?[]align(64) u8 = null,

    /// Where the Serialize rows write. Sized for the shape.
    zr_dest: ?[]align(8) u8 = null,
    r64_portable_dest: ?[]u8 = null,
    r64_frozen_dest: ?[]align(64) u8 = null,

    /// One generator per side for the Random rows, seeded alike, so the k-th
    /// call on either side draws the same values. Reseeded by `buildRandom`.
    prng_zr: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),
    prng_r64: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0),

    /// `count` values `i * step`, added one at a time — the loop
    /// `synthetic_bench.cpp` uses to build every stepped fixture.
    pub fn buildStepped(self: *Synth, count: usize, step: u64) !void {
        self.reset();
        self.count = count;
        self.step = step;

        var zr = try zroar.Bitmap.init(self.allocator);
        errdefer zr.deinit();
        const r64 = try roaring64.Bitmap64.create();
        errdefer r64.free();
        for (0..count) |i| {
            // Wraps at the widest step, as their `i * step` does in C.
            const v = @as(u64, i) *% step;
            _ = try zr.set(v);
            r64.add(v);
        }
        self.zr = zr;
        self.r64 = r64;
    }

    /// `random_fill` draws under `mask`, duplicates and all, into both sides;
    /// then both probe generators are seeded alike.
    pub fn buildRandom(self: *Synth, mask: u64) !void {
        self.reset();
        self.mask = mask;

        var prng = std.Random.DefaultPrng.init(seed ^ mask);
        const rnd = prng.random();
        var zr = try zroar.Bitmap.init(self.allocator);
        errdefer zr.deinit();
        const r64 = try roaring64.Bitmap64.create();
        errdefer r64.free();
        for (0..random_fill) |_| {
            const v = rnd.int(u64) & mask;
            _ = try zr.set(v);
            r64.add(v);
        }
        self.zr = zr;
        self.r64 = r64;

        const probe_seed = seed +% mask;
        self.prng_zr = std.Random.DefaultPrng.init(probe_seed);
        self.prng_r64 = std.Random.DefaultPrng.init(probe_seed);
    }

    /// Serializes the prebuilt shape in every format and allocates a
    /// destination of each size, for the Serialize and Deserialize rows.
    pub fn serialize(self: *Synth) !void {
        const a = self.allocator;
        const zr = &(self.zr orelse unreachable);
        const r64 = self.r64 orelse unreachable;

        self.zr_buf = try zr.toBufferCopy(a);
        self.zr_dest = try a.alignedAlloc(u8, .@"8", self.zr_buf.?.len);

        const pbuf = try a.alloc(u8, r64.portableSizeInBytes());
        _ = r64.portableSerialize(pbuf);
        self.r64_portable_buf = pbuf;
        self.r64_portable_dest = try a.alloc(u8, pbuf.len);

        // Frozen serialization wants shrink_to_fit first. The prebuilt bitmap
        // is only read from here on, so trimming it changes nothing measured.
        _ = r64.shrinkToFit();
        const fbuf = try a.alignedAlloc(u8, .@"64", r64.frozenSizeInBytes());
        _ = r64.frozenSerialize(fbuf);
        self.r64_frozen_buf = fbuf;
        self.r64_frozen_dest = try a.alignedAlloc(u8, .@"64", fbuf.len);
    }

    /// Every serialized form must open to the shape's cardinality.
    pub fn checkSerialized(self: *const Synth) !void {
        const want = self.zr.?.getCardinality();
        if (self.r64.?.cardinality() != want) return error.R64Differs;

        var zr = try zroar.Bitmap.fromBuffer(self.allocator, self.zr_buf.?);
        defer zr.deinit();
        if (zr.getCardinality() != want) return error.ZroarBufferDiffers;

        const portable = try roaring64.Bitmap64.portableDeserializeSafe(self.r64_portable_buf.?);
        defer portable.free();
        if (portable.cardinality() != want) return error.PortableDiffers;

        const frozen = try roaring64.Bitmap64.frozenView(self.r64_frozen_buf.?);
        defer frozen.free();
        if (frozen.cardinality() != want) return error.FrozenDiffers;
    }

    /// Frees whatever is built and returns to the empty state.
    pub fn reset(self: *Synth) void {
        const a = self.allocator;
        if (self.zr) |*bm| bm.deinit();
        if (self.r64) |bm| bm.free();
        if (self.zr_buf) |b| a.free(b);
        if (self.r64_portable_buf) |b| a.free(b);
        if (self.r64_frozen_buf) |b| a.free(b);
        if (self.zr_dest) |b| a.free(b);
        if (self.r64_portable_dest) |b| a.free(b);
        if (self.r64_frozen_dest) |b| a.free(b);
        self.* = .{ .allocator = a };
    }
};

/// Builds every fixture for `mode`. Errors are fatal to the caller: there is
/// nothing useful a benchmark run can do without its data.
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    mode: Mode,
) !DataSet {
    var prng = std.Random.DefaultPrng.init(seed);
    const rnd = prng.random();

    const files = switch (mode) {
        .realdata => try readDataDir(io, allocator, dir_path),
        .oltp, .oltp_random => try oltpFiles(allocator, rnd, mode),
    };
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }
    if (files.len == 0) return error.NoInputFiles;

    const files_zroar = try allocator.alloc(zroar.Bitmap, files.len);
    const files_r64 = try allocator.alloc(*roaring64.Bitmap64, files.len);
    const zr_bufs = try allocator.alloc([]align(8) u8, files.len);
    const r64_portable_bufs = try allocator.alloc([]u8, files.len);
    const r64_frozen_bufs = try allocator.alloc([]align(64) u8, files.len);
    const file_cum = try allocator.alloc(u64, files.len);
    var max_card: usize = 0;
    var max_value: u64 = 0;
    var running_card: u64 = 0;
    var zr_bytes: usize = 0;
    var r64_portable_bytes: usize = 0;
    var r64_frozen_bytes: usize = 0;
    var r64_portable_bytes_norun: usize = 0;
    for (files, 0..) |f, i| {
        files_zroar[i] = try zroar.Bitmap.fromSortedList(allocator, f);
        zr_bufs[i] = try files_zroar[i].toBufferCopy(allocator);

        // One `add` per value and then `runOptimize`, which is how CRoaring's
        // microbenchmark builds its 64-bit bitmaps.
        files_r64[i] = try roaring64.Bitmap64.create();
        for (f) |v| files_r64[i].add(v);
        r64_portable_bytes_norun += files_r64[i].portableSizeInBytes();
        _ = files_r64[i].runOptimize();
        r64_portable_bufs[i] = try allocator.alloc(u8, files_r64[i].portableSizeInBytes());
        _ = files_r64[i].portableSerialize(r64_portable_bufs[i]);

        // The frozen format wants shrink_to_fit first. Done to a copy, so the
        // warm bitmap stays exactly what CRoaring's benchmark would hold.
        const trimmed = try files_r64[i].copy();
        defer trimmed.free();
        _ = trimmed.shrinkToFit();
        r64_frozen_bufs[i] = try allocator.alignedAlloc(u8, .@"64", trimmed.frozenSizeInBytes());
        _ = trimmed.frozenSerialize(r64_frozen_bufs[i]);

        zr_bytes += zr_bufs[i].len;
        r64_portable_bytes += r64_portable_bufs[i].len;
        r64_frozen_bytes += r64_frozen_bufs[i].len;

        // The values are sorted and deduplicated, so the file's length is its
        // cardinality and its last value is its maximum.
        max_card = @max(max_card, f.len);
        if (f.len > 0) max_value = @max(max_value, f[f.len - 1]);
        running_card += f.len;
        file_cum[i] = running_card;
    }

    // MixedOLTP reads over the whole row-id space and appends above it. The
    // OLTP modes name that space outright; in realdata the file values are all
    // there is, so their largest stands in for it.
    const row_id_max: u64 = switch (mode) {
        .oltp => oltp_rows - 1,
        .oltp_random => std.math.maxInt(u64),
        .realdata => max_value,
    };
    const row_id_next: u64 = switch (mode) {
        .oltp, .oltp_random => oltp_rows,
        .realdata => max_value + 1,
    };

    std.debug.print(
        "mode: {s}  files: {d}  values: {d}  serialized bytes: zroar {d}  r64 portable {d} (without run containers {d})  r64 frozen {d}\n",
        .{ @tagName(mode), files.len, running_card, zr_bytes, r64_portable_bytes, r64_portable_bytes_norun, r64_frozen_bytes },
    );

    return .{
        .allocator = allocator,
        .io = io,
        .files_zroar = files_zroar,
        .files_r64 = files_r64,
        .zr_bufs = zr_bufs,
        .r64_portable_bufs = r64_portable_bufs,
        .r64_frozen_bufs = r64_frozen_bufs,
        .zr_open = try allocator.alloc(zroar.Bitmap, files.len),
        .r64_open = try allocator.alloc(*roaring64.Bitmap64, files.len),
        .array_buf = try allocator.alloc(u64, max_card),
        .max_value = max_value,
        .file_cum = file_cum,
        .row_id_max = row_id_max,
        .row_id_next = row_id_next,
        .values = running_card,
        .zr_bytes = zr_bytes,
        .r64_portable_bytes = r64_portable_bytes,
        .r64_frozen_bytes = r64_frozen_bytes,
        .r64_portable_bytes_norun = r64_portable_bytes_norun,
        .synth = .{ .allocator = allocator },
    };
}

/// The two libraries must hold the same bitmaps before any benchmark compares
/// them, and the serialized forms must open to the same thing. Equal
/// cardinalities would not catch a wrong value, so compare the contents,
/// file by file, warm bitmaps and all three formats.
pub fn checkFiles(ds: *const DataSet) void {
    for (ds.files_zroar, 0..) |*zr, i| {
        const want = zr.toArray(ds.allocator) catch @panic("out of memory");
        defer ds.allocator.free(want);

        expectR64(ds, ds.files_r64[i], want, i, "warm");

        const portable = roaring64.Bitmap64.portableDeserializeSafe(ds.r64_portable_bufs[i]) catch
            std.debug.panic("file {d}: r64 portable buffer does not deserialize", .{i});
        defer portable.free();
        expectR64(ds, portable, want, i, "portable");

        const frozen = roaring64.Bitmap64.frozenView(ds.r64_frozen_bufs[i]) catch
            std.debug.panic("file {d}: r64 frozen buffer does not open", .{i});
        defer frozen.free();
        expectR64(ds, frozen, want, i, "frozen");

        var reopened = zroar.Bitmap.fromBuffer(ds.allocator, ds.zr_bufs[i]) catch unreachable;
        defer reopened.deinit();
        const got = reopened.toArray(ds.allocator) catch @panic("out of memory");
        defer ds.allocator.free(got);
        if (!std.mem.eql(u64, want, got)) std.debug.panic(
            "file {d}: zroar buffer reopens to different contents",
            .{i},
        );
    }
}

fn expectR64(
    ds: *const DataSet,
    bm: *const roaring64.Bitmap64,
    want: []const u64,
    file: usize,
    what: []const u8,
) void {
    const card = bm.cardinality();
    if (card != want.len) std.debug.panic(
        "file {d} ({s}): zroar cardinality {d}, r64 cardinality {d}",
        .{ file, what, want.len, card },
    );
    const got = ds.allocator.alloc(u64, @intCast(card)) catch @panic("out of memory");
    defer ds.allocator.free(got);
    bm.toUint64Array(got);
    for (want, got, 0..) |a, b, j| {
        if (a != b) std.debug.panic(
            "file {d} ({s}) differs at index {d}: zroar has {d}, r64 has {d}",
            .{ file, what, j, a, b },
        );
    }
}

// ---------------------------------------------------------------------------
// Input shapes
// ---------------------------------------------------------------------------

/// One secondary index: a posting list per indexed value, each holding row-ids
/// of the same table. `.oltp` gives the table auto-increment row-ids, so the
/// lists are scattered samples of a 10M-wide range; `.oltp_random` gives it
/// row-ids derived from something like a UUID, so they span the whole u64 range
/// and every value tends to land on a 48-bit key of its own.
fn oltpFiles(allocator: std.mem.Allocator, rnd: std.Random, mode: Mode) ![][]u64 {
    const max_row_id: u64 = switch (mode) {
        .oltp => oltp_rows - 1,
        .oltp_random => std.math.maxInt(u64),
        .realdata => unreachable, // only the OLTP modes get here
    };

    const files = try allocator.alloc([]u64, oltp_lists);
    for (files, 0..) |*f, i| {
        const rank: f64 = @floatFromInt(i + 1);
        const size = @max(
            oltp_min_size,
            @as(usize, @intFromFloat(oltp_head_size / std.math.pow(f64, rank, oltp_zipf_exponent))),
        );
        // Sampled with replacement and then deduplicated, so a list comes out a
        // little shorter than `size`. Only the shape of the size distribution
        // matters here, and a few percent does not change it.
        const buf = try allocator.alloc(u64, size);
        const vals = randomSortedAtMost(buf, rnd, max_row_id);
        f.* = try allocator.realloc(buf, vals.len);
    }
    return files;
}

/// Reads every `*.txt` in `dir_path` as one bitmap's worth of values.
fn readDataDir(io: std.Io, allocator: std.mem.Allocator, dir_path: []const u8) ![][]u64 {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".txt")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    // Directory order is arbitrary and the successive rows pair neighbouring
    // files, so fix an order the next run will reproduce.
    std.mem.sort([]u8, names.items, {}, lessThanName);

    const files = try allocator.alloc([]u64, names.items.len);
    for (names.items, 0..) |name, i| {
        const bytes = try dir.readFileAlloc(io, name, allocator, .limited(1 << 28));
        defer allocator.free(bytes);
        files[i] = try parseValues(allocator, bytes);
    }
    return files;
}

fn lessThanName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn parseValues(allocator: std.mem.Allocator, bytes: []const u8) ![]u64 {
    var vals: std.ArrayListUnmanaged(u64) = .empty;
    defer vals.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] < '0' or bytes[i] > '9') {
            i += 1;
            continue;
        }
        var v: u64 = 0;
        while (i < bytes.len and bytes[i] >= '0' and bytes[i] <= '9') : (i += 1) {
            v = v * 10 + (bytes[i] - '0');
        }
        // CRoaring's loader reads these files as u32; anything wider is not
        // one of its data sets.
        if (v > std.math.maxInt(u32)) return error.ValueTooLarge;
        try vals.append(allocator, v);
    }

    std.mem.sort(u64, vals.items, {}, std.sort.asc(u64));
    vals.shrinkRetainingCapacity(dedup(vals.items));
    return vals.toOwnedSlice(allocator);
}

/// Fills `out` with random values up to and including `max`, then sorts and
/// deduplicates it in place. Returns the part of `out` that holds the distinct
/// values. Inclusive because "the whole u64 range" has no exclusive bound.
fn randomSortedAtMost(out: []u64, rnd: std.Random, max: u64) []u64 {
    for (out) |*v| v.* = rnd.uintAtMost(u64, max);
    std.mem.sort(u64, out, {}, std.sort.asc(u64));
    return out[0..dedup(out)];
}

/// Compacts a sorted slice in place; returns the number of distinct values.
fn dedup(vals: []u64) usize {
    var w: usize = 0;
    for (vals) |v| {
        if (w > 0 and vals[w - 1] == v) continue;
        vals[w] = v;
        w += 1;
    }
    return w;
}
