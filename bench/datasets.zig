//! Fixtures for the zroar vs roaring64 benchmarks.
//!
//! Everything the benchmarks touch is built here, untimed: the input bitmaps,
//! their serialized forms for both libraries, the probe array and the scratch
//! buffer every serialization writes into. A benchmark function then does
//! nothing but the work it is named after.
//!
//! Four input shapes are supported. `realdata` reads a directory of CRoaring's
//! benchmark files (comma-separated u32, one bitmap per file). `--synthetic`
//! generates the shapes DESIGN.md asks for instead. In both of those the union
//! bitmap U tags each input's values with its index in the high 32 bits, so U
//! spans many 48-bit keys rather than the u32 range the inputs live in.
//!
//! `--oltp` and `--oltp-random` generate a database secondary index instead:
//! one posting list per indexed value, each holding the row-ids of a primary
//! table. Those lists share one row-id space, so there is nothing to tag and U
//! is their plain union. This is the shape the realdata sets do not cover:
//! scattered bits with little for a run container to find, and writes that
//! append rather than land anywhere in the domain.

const std = @import("std");
const zroar = @import("zroar");
const roaring64 = @import("roaring64");

/// Which of the four input shapes to build.
pub const Mode = enum {
    /// A directory of CRoaring benchmark files.
    realdata,
    /// The shapes DESIGN.md names.
    synthetic,
    /// Posting lists over auto-increment row-ids.
    oltp,
    /// Posting lists over row-ids scattered across the whole u64 range.
    oltp_random,

    /// True for the two posting-list modes, which share one row-id space and so
    /// take neither the file-index tag nor a data directory.
    fn isOltp(self: Mode) bool {
        return self == .oltp or self == .oltp_random;
    }
};

/// Probes the WarmContains and ColdOpen benchmarks issue. Half are present in
/// U, half are not.
pub const num_probes = 1024;

/// Merge10K's inputs: many small, scattered bitmaps.
pub const merge_bitmaps = 10_000;
pub const merge_values = 1_000;
pub const merge_domain = 100_000_000;

/// BuildSer's input.
pub const build_count = 100_000;
pub const build_domain = 100_000_000;

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

/// Every random choice in here comes from this one seed, so a rerun sees the
/// same data down to the last probe.
const seed = 0x5EED_B0A7;

pub const DataSet = struct {
    /// Used for every allocation a benchmark makes; CRoaring mallocs, so zroar
    /// must too for the comparison to be about the data structures.
    allocator: std.mem.Allocator,

    /// U, serialized by each library.
    zr_u_buf: []align(8) u8,
    r64_u_buf: []u8,

    /// U, already open. The warm benchmarks read these and never mutate them.
    zr_u: zroar.Bitmap,
    r64_u: *roaring64.Bitmap64,

    /// One serialized buffer per input file, holding that file's raw values.
    zr_file_bufs: [][]align(8) u8,
    r64_file_bufs: [][]u8,

    /// The same per-file values, kept open. These are what the CRoaring
    /// microbenchmark suite works on: untagged, exactly the values the file
    /// holds, so a `-r64` timing can be read next to CRoaring's own tables.
    files_zroar: []zroar.Bitmap,
    files_zroar_ptrs: []*const zroar.Bitmap,
    files_r64: []*roaring64.Bitmap64,

    /// Where ToArray64-r64 unpacks a bitmap. Sized for the largest file.
    files_array_buf: []u64,

    /// Largest value in any file bitmap; RandomAccess64 probes fractions of it.
    files_max_value: u64,

    /// Where UnionAllSer puts the bitmaps it opens. Preallocated because the
    /// benchmark measures opening and unioning, not sizing an array.
    zr_open: []zroar.Bitmap,
    zr_open_ptrs: []*const zroar.Bitmap,
    r64_open: []*roaring64.Bitmap64,

    /// Merge10K's prebuilt inputs.
    zr_merge: []zroar.Bitmap,
    zr_merge_ptrs: []*const zroar.Bitmap,
    r64_merge: []*roaring64.Bitmap64,

    /// BuildSer's values, and the same values sorted for BuildSortedSer.
    build_vals: []u64,
    build_vals_sorted: []u64,

    /// 1024 probes: half present in U, half absent, shuffled together.
    probes: []u64,

    /// Output for every r64 serialization and for MemcpyBaseline. Sized in
    /// setup to the largest thing any benchmark writes into it.
    scratch: []u8,

    /// Largest value in U. Mixed90R10W draws its random values from [0, u_max].
    u_max: u64,

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

    pub fn deinit(self: *DataSet) void {
        const a = self.allocator;
        self.zr_u.deinit();
        self.r64_u.free();
        a.free(self.zr_u_buf);
        a.free(self.r64_u_buf);

        for (self.zr_file_bufs) |b| a.free(b);
        for (self.r64_file_bufs) |b| a.free(b);
        a.free(self.zr_file_bufs);
        a.free(self.r64_file_bufs);

        for (self.files_zroar) |*b| b.deinit();
        for (self.files_r64) |b| b.free();
        a.free(self.files_zroar);
        a.free(self.files_zroar_ptrs);
        a.free(self.files_r64);
        a.free(self.files_array_buf);

        a.free(self.zr_open);
        a.free(self.zr_open_ptrs);
        a.free(self.r64_open);

        for (self.zr_merge) |*b| b.deinit();
        for (self.r64_merge) |b| b.free();
        a.free(self.zr_merge);
        a.free(self.zr_merge_ptrs);
        a.free(self.r64_merge);

        a.free(self.build_vals);
        a.free(self.build_vals_sorted);
        a.free(self.probes);
        a.free(self.scratch);
        a.free(self.file_cum);
    }
};

/// Builds every fixture and prints one line describing the result.
///
/// Setup failures abort the process rather than unwind: there is nothing
/// useful a benchmark run can do without its data.
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
        .synthetic => try syntheticFiles(allocator, rnd),
        .oltp, .oltp_random => try oltpFiles(allocator, rnd, mode),
    };
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }
    if (files.len == 0) return error.NoInputFiles;

    // U tags each file's values with the file index. Each file's values are
    // sorted and the tag rises with the index, so the concatenation is sorted
    // as a whole and the bulk loaders can take it as it is.
    //
    // The OLTP modes are the exception: their posting lists index one table, so
    // a row-id means the same thing in all of them and U is the honest union.
    // That concatenation overlaps and needs sorting.
    var total: usize = 0;
    for (files) |f| total += f.len;
    const u_all = try allocator.alloc(u64, total);
    defer allocator.free(u_all);
    {
        var n: usize = 0;
        for (files, 0..) |f, i| {
            const tag: u64 = if (mode.isOltp()) 0 else @as(u64, i) << 32;
            for (f) |v| {
                u_all[n] = tag | v;
                n += 1;
            }
        }
    }
    const u_values = if (mode.isOltp()) blk: {
        std.mem.sort(u64, u_all, {}, std.sort.asc(u64));
        break :blk u_all[0..dedup(u_all)];
    } else u_all;
    if (u_values.len == 0) return error.NoInputValues;

    var zr_u = try zroar.Bitmap.fromSortedList(allocator, u_values);
    const zr_u_buf = try zr_u.toBufferCopy(allocator);

    const r64_u = try roaring64.Bitmap64.create();
    r64_u.addMany(u_values);
    // Run containers are CRoaring's advantage and zroar has none, so leave them
    // on: r64 is measured at its best.
    _ = r64_u.runOptimize();
    const r64_u_buf = try allocator.alloc(u8, r64_u.portableSizeInBytes());
    _ = r64_u.portableSerialize(r64_u_buf);

    // Per-file bitmaps keep their raw values; only U is tagged. `max_ser` grows
    // to cover everything a benchmark will serialize into `scratch`.
    var max_ser: usize = @max(zr_u_buf.len, r64_u_buf.len);
    const zr_file_bufs = try allocator.alloc([]align(8) u8, files.len);
    const r64_file_bufs = try allocator.alloc([]u8, files.len);
    const files_zroar = try allocator.alloc(zroar.Bitmap, files.len);
    const files_zroar_ptrs = try allocator.alloc(*const zroar.Bitmap, files.len);
    const files_r64 = try allocator.alloc(*roaring64.Bitmap64, files.len);
    const file_cum = try allocator.alloc(u64, files.len);
    var files_max_card: usize = 0;
    var files_max_value: u64 = 0;
    var files_running_card: u64 = 0;
    const files_union = try roaring64.Bitmap64.create();
    defer files_union.free();
    for (files, 0..) |f, i| {
        files_zroar[i] = try zroar.Bitmap.fromSortedList(allocator, f);
        files_zroar_ptrs[i] = &files_zroar[i];
        zr_file_bufs[i] = try files_zroar[i].toBufferCopy(allocator);

        // One `add` per value and then `runOptimize`, which is how the CRoaring
        // microbenchmark builds its 64-bit bitmaps.
        files_r64[i] = try roaring64.Bitmap64.create();
        for (f) |v| files_r64[i].add(v);
        _ = files_r64[i].runOptimize();
        r64_file_bufs[i] = try allocator.alloc(u8, files_r64[i].portableSizeInBytes());
        _ = files_r64[i].portableSerialize(r64_file_bufs[i]);
        max_ser = @max(max_ser, r64_file_bufs[i].len);

        // The values are sorted and deduplicated, so the file's length is its
        // cardinality and its last value is its maximum.
        files_max_card = @max(files_max_card, f.len);
        if (f.len > 0) files_max_value = @max(files_max_value, f[f.len - 1]);
        files_running_card += f.len;
        file_cum[i] = files_running_card;

        files_union._orInPlace(files_r64[i]);
    }
    // UnionAllSer serializes the union of the files, which is not U: the files
    // are untagged, so their values overlap.
    max_ser = @max(max_ser, files_union.portableSizeInBytes());

    const probes = try allocator.alloc(u64, num_probes);
    for (probes, 0..) |*p, i| {
        const present = u_values[rnd.uintLessThan(usize, u_values.len)];
        if (i < num_probes / 2) {
            p.* = present;
            continue;
        }
        // A miss near a hit: the same region of the value space, so the lookup
        // walks the same keys and containers a hit would.
        var v = present +% 1 +% rnd.uintLessThan(u64, 1024);
        while (zr_u.contains(v)) v +%= 1;
        p.* = v;
    }
    rnd.shuffle(u64, probes);

    const zr_merge = try allocator.alloc(zroar.Bitmap, merge_bitmaps);
    const zr_merge_ptrs = try allocator.alloc(*const zroar.Bitmap, merge_bitmaps);
    const r64_merge = try allocator.alloc(*roaring64.Bitmap64, merge_bitmaps);
    {
        const buf = try allocator.alloc(u64, merge_values);
        defer allocator.free(buf);
        for (0..merge_bitmaps) |i| {
            const vals = randomSorted(buf, rnd, merge_domain);
            zr_merge[i] = try zroar.Bitmap.fromSortedList(allocator, vals);
            zr_merge_ptrs[i] = &zr_merge[i];
            r64_merge[i] = try roaring64.Bitmap64.create();
            r64_merge[i].addMany(vals);
            _ = r64_merge[i].runOptimize();
        }
    }

    const build_vals = try allocator.alloc(u64, build_count);
    for (build_vals) |*v| v.* = rnd.uintLessThan(u64, build_domain);
    const build_vals_sorted = try allocator.dupe(u64, build_vals);
    std.mem.sort(u64, build_vals_sorted, {}, std.sort.asc(u64));
    {
        const rb = try roaring64.Bitmap64.create();
        defer rb.free();
        rb.addMany(build_vals);
        _ = rb.runOptimize();
        max_ser = @max(max_ser, rb.portableSizeInBytes());
    }

    // UnionAllSer opens the per-file bitmaps into these slots every iteration;
    // the pointers it hands to `fastOr` are set once, here.
    const zr_open = try allocator.alloc(zroar.Bitmap, files.len);
    const zr_open_ptrs = try allocator.alloc(*const zroar.Bitmap, files.len);
    for (zr_open_ptrs, 0..) |*p, i| p.* = &zr_open[i];

    std.debug.print(
        "mode: {s}  files: {d}  U cardinality: {d}  U serialized bytes: zroar {d}  r64 {d}\n",
        .{ @tagName(mode), files.len, zr_u.getCardinality(), zr_u_buf.len, r64_u_buf.len },
    );

    // MixedOLTP reads over the whole row-id space and appends above it. The
    // OLTP modes name that space outright; in the other modes the file values
    // are all there is, so their largest stands in for it.
    const row_id_max: u64 = switch (mode) {
        .oltp => oltp_rows - 1,
        .oltp_random => std.math.maxInt(u64),
        .realdata, .synthetic => files_max_value,
    };
    const row_id_next: u64 = switch (mode) {
        .oltp, .oltp_random => oltp_rows,
        .realdata, .synthetic => files_max_value + 1,
    };

    return .{
        .allocator = allocator,
        .zr_u_buf = zr_u_buf,
        .r64_u_buf = r64_u_buf,
        .zr_u = zr_u,
        .r64_u = r64_u,
        .zr_file_bufs = zr_file_bufs,
        .r64_file_bufs = r64_file_bufs,
        .files_zroar = files_zroar,
        .files_zroar_ptrs = files_zroar_ptrs,
        .files_r64 = files_r64,
        .files_array_buf = try allocator.alloc(u64, @max(files_max_card, 1)),
        .files_max_value = files_max_value,
        .zr_open = zr_open,
        .zr_open_ptrs = zr_open_ptrs,
        .r64_open = try allocator.alloc(*roaring64.Bitmap64, files.len),
        .zr_merge = zr_merge,
        .zr_merge_ptrs = zr_merge_ptrs,
        .r64_merge = r64_merge,
        .build_vals = build_vals,
        .build_vals_sorted = build_vals_sorted,
        .probes = probes,
        .scratch = try allocator.alloc(u8, max_ser),
        .u_max = u_values[u_values.len - 1],
        .file_cum = file_cum,
        .row_id_max = row_id_max,
        .row_id_next = row_id_next,
    };
}

/// The two libraries must hold the same U before any benchmark compares them.
/// Equal cardinalities would not catch a wrong value, so compare the contents.
pub fn checkUnions(ds: *const DataSet) void {
    const zr = ds.zr_u.toArray(ds.allocator) catch @panic("out of memory");
    defer ds.allocator.free(zr);

    const card = ds.r64_u.cardinality();
    if (card != zr.len) std.debug.panic(
        "U differs: zroar cardinality {d}, r64 cardinality {d}",
        .{ zr.len, card },
    );

    const r64_vals = ds.allocator.alloc(u64, @intCast(card)) catch @panic("out of memory");
    defer ds.allocator.free(r64_vals);
    ds.r64_u.toUint64Array(r64_vals);

    for (zr, r64_vals, 0..) |a, b, i| {
        if (a != b) std.debug.panic(
            "U differs at index {d}: zroar has {d}, r64 has {d}",
            .{ i, a, b },
        );
    }
}

// ---------------------------------------------------------------------------
// Input shapes
// ---------------------------------------------------------------------------

/// The shapes DESIGN.md names: a dense and a sparse bitmap of equal
/// cardinality, and one fully sequential run.
fn syntheticFiles(allocator: std.mem.Allocator, rnd: std.Random) ![][]u64 {
    const files = try allocator.alloc([]u64, 3);
    files[0] = try randomValues(allocator, rnd, 65_536, 150_000);
    files[1] = try randomValues(allocator, rnd, 65_536, 100_000_000);
    files[2] = try allocator.alloc(u64, 100_000);
    for (files[2], 0..) |*v, i| v.* = i;
    return files;
}

/// One secondary index: a posting list per indexed value, each holding row-ids
/// of the same table. `.oltp` gives the table auto-increment row-ids, so the
/// lists are scattered samples of a 10M-wide range; `.oltp_random` gives it
/// row-ids derived from something like a UUID, so they span the whole u64 range
/// and every value tends to land on a 48-bit key of its own.
fn oltpFiles(allocator: std.mem.Allocator, rnd: std.Random, mode: Mode) ![][]u64 {
    const max_row_id: u64 = switch (mode) {
        .oltp => oltp_rows - 1,
        .oltp_random => std.math.maxInt(u64),
        .realdata, .synthetic => unreachable, // only the OLTP modes get here
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
    // Directory order is arbitrary and the file index ends up inside U's
    // values, so fix an order the next run will reproduce.
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

/// Every run of digits in `bytes` is one value; anything else is a separator.
/// The result is sorted and deduplicated, ready for the bulk loaders.
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
        // The file index goes into the high 32 bits of U's values, so the file
        // values themselves have to stay inside the u32 range.
        if (v > std.math.maxInt(u32)) return error.ValueTooLarge;
        try vals.append(allocator, v);
    }

    std.mem.sort(u64, vals.items, {}, std.sort.asc(u64));
    vals.shrinkRetainingCapacity(dedup(vals.items));
    return vals.toOwnedSlice(allocator);
}

fn randomValues(
    allocator: std.mem.Allocator,
    rnd: std.Random,
    count: usize,
    domain: u64,
) ![]u64 {
    const buf = try allocator.alloc(u64, count);
    const vals = randomSorted(buf, rnd, domain);
    return allocator.realloc(buf, vals.len);
}

/// Fills `out` with random values below `domain`, then sorts and deduplicates
/// it in place. Returns the part of `out` that holds the distinct values.
fn randomSorted(out: []u64, rnd: std.Random, domain: u64) []u64 {
    return randomSortedAtMost(out, rnd, domain - 1);
}

/// `randomSorted` with an inclusive bound, which is the only way to say "the
/// whole u64 range": the scattered OLTP flavor's row-ids cover it.
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
