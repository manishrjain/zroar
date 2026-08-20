# zroar — Design

A Zig port of [sroar](https://github.com/dgraph-io/sroar) (serialized roaring
bitmaps over u64 keys). The defining property: **the on-disk representation is
the in-memory representation**. Opening a serialized bitmap (`fromBuffer`) is
O(1) — no parsing, no per-container allocation. This exists to benchmark
against CRoaring's `roaring64_bitmap_t`, where opening from the portable
format costs a full deserialize (~1–2 µs per small bitmap, ≈75–280 `contains`
calls) and even a frozen view is an O(#containers) fix-up pass (measured
2026-08).

## Non-negotiable constraints

1. **Understandable over fast.** Prefer the obvious implementation; accept
   "slightly slower." A reader familiar with roaring bitmaps should follow any
   function on first read.
2. **No inline assembly. No intrinsics. No runtime CPU dispatch.** Portable Zig
   only. SIMD exclusively via `@Vector` with comptime-known shuffle patterns,
   in loops that stay obvious: the bitset word operations, and the
   block-match phase of the balanced array intersection
   (`setutil.localIntersectCore` — all-pairs compare via comptime rotations).
   Scalar code everywhere else; no runtime shuffles or lookup-table permutes.
3. **No run containers.** Array and bitmap containers only.
4. Only 64-bit values (`u64`). No 32-bit variant.
5. Target toolchain: Zig 0.16.0. Library code uses no I/O.

## Memory layout

One flat buffer per bitmap. Unit of measure throughout: **u16 elements** (not
bytes). The buffer pointer is always 8-byte aligned. `AlignedU8`,
`AlignedConstU8` and `AlignedU16` are the buffer/container slice aliases
(`[]align(8) u8`, `[]align(8) const u8`, `[]align(8) u16`); the 8-byte
alignment they carry is a correctness requirement, not a hint, since the
keys node and bitmap-container payloads are both viewed as `[]u64` — the
trailing number in the name is the element width, not the alignment.

```
data: []align(8) u16
      ┌───────────────────┬─────────────┬─────────────┬─────┐
      │ keys node         │ container   │ container   │ ... │
      │ (viewed as []u64) │             │             │     │
      └───────────────────┴─────────────┴─────────────┴─────┘
       ^ index 0           ^ offsets stored in keys node
```

```zig
pub const Bitmap = struct {
    data: AlignedU16,  // in-use region
    cap: usize,        // capacity in u16s (== data.len when borrowed)
    owned: bool,        // false after fromBuffer; true after first grow
    dead: usize = 0,    // dead u16s from relocation; see max_dead_divisor
    allocator: std.mem.Allocator,
};
```

**Alignment invariant (load-bearing):** every container offset and every
container size is a multiple of 4 u16s (= 8 bytes). Combined with the 4-u16
header, every bitmap-container payload starts on an 8-byte boundary, so it can
be viewed as `[]u64` with a checked `@alignCast`. The keys-node size is also
a multiple of 4 u16s. Anything that allocates or grows (newContainer,
expandContainer, keys-node growth, fastOr pre-sizing, fromSortedList) must
round sizes up to a multiple of 4.

### Keys node

A `[]u64` view over the front of `data`, derived on demand (never stored — a
stored alias dangles after realloc):

```zig
fn keys(self: *const Bitmap) Keys {
    const p: [*]u64 = @ptrCast(self.data.ptr);
    return .{ .n = p[0 .. nodeSizeOf(p[0]) / 4] }; // p[0] >> 16 = node size in u16 units
}
```

Layout in u64 units:

| u64 index | meaning |
|---|---|
| 0 | low 16 bits: **format version** (currently 1); high 48 bits: node size in **u16 units** (multiple of 4) |
| 1 | number of keys |
| 2 + 2i | key i — `value & 0xFFFF_FFFF_FFFF_0000` (top 48 bits) |
| 3 + 2i | offset of container i into `data`, in u16 units (multiple of 4) |

The version occupies the buffer's first two bytes (the format is little-endian
by definition), so any layout change can bump `keys.format_version` and old
readers refuse new buffers — and new readers refuse pre-versioning ones — rather
than misreading them (`fromBuffer` → `error.UnsupportedFormatVersion`).

- Keys sorted ascending. Binary search (`Keys.search`) returns the index of
  the smallest key >= target, or numKeys.
- **Key 0 always exists** (created at init with an empty min-size array
  container). Rationale: a zeroed slot and a legitimate zero key are otherwise
  indistinguishable. Cleanup must never remove key 0.
- Node growth: when full, double the pair capacity (growth increment capped at
  65532 u16s), `scootRight` the entire container region, then add the shift to
  **every** offset. O(buffer) — this is why bulk builders create all keys
  before any containers.

### Containers

4-u16 header, then payload. Header fields (byte offsets from an 8-byte-aligned
base):

| u16 index | meaning |
|---|---|
| 0 | allocated size in u16 units, **including header** (multiple of 4) |
| 1 | type: 0 = array, 1 = bitmap |
| 2..3 | cardinality as one aligned u32 (bytes 4..8) |

Cardinality sentinel: `0xFFFF_FFFF` = "invalid, recompute" — used only during
`fastOr`'s lazy union, repaired before it returns. Valid range 0…65536.

**Array container**: payload = sorted unique u16s. Allocated sizes follow the
ladder in `container.array_sizes`: doubling from `container.min_size` to
1024 u16s, then half-steps 1536, 2048, 3072 (header included). `min_size` is
the one adjustable knob for the waste-vs-growth-steps trade-off (see its doc
comment); the default of 8 u16s (16 bytes, 4 value slots) keeps single-value
containers nearly free — the case that dominates scattered u64 keys.
Membership: binary search (`std.sort.binarySearch`-style; linear scan is fine
below ~16 elements). Insert/remove: memmove within the container.
**Invariant: after any successful insert an array container has >= 1 free
slot** — `set` inserts first, then expands/converts if now full. When growth
would exceed 3072 u16s, convert to a bitmap container instead.

**Bitmap container**: fixed 4100 u16s (4 header + 4096 payload = 1024 u64
words). **LSB-first**: value `x` (low 16 bits) lives in word `x >> 6`, bit
`x & 63`. (Deliberately differs from Go sroar's MSB-first u16 words.)
All kernels operate on the `[]u64` view:

- add/remove/contains: single word index + bit mask.
- and/or/andNot/xor between two bitmap payloads: one obvious loop over
  `@Vector(8, u64)` chunks (1024 words = 128 iterations), or plain u64 loops
  where clearer. Popcount: `@reduce(.Add, @popCount(vec))` accumulated in the
  same loop when cardinality is needed.
- iterate: per word, `@ctz` + `w &= w - 1`.
- minimum: `@ctz` of first nonzero word; maximum: `63 - @clz` of last nonzero.

Conversion thresholds:
- array → bitmap: when the array would grow past 3072 u16s (~3068 values).
- union of two arrays / fastOr pre-sizing: a bitmap container whenever no
  array container fits the (estimated) cardinality, i.e. > 3067 values —
  "fits an array size or converts".
- **No demotion of an existing bitmap container.** Result-type *selection at
  creation* by cardinality (e.g. And emitting a small array from a
  bitmap∩bitmap) is allowed and used.

### Growth machinery (port of sroar bitmap.go, same names where sensible)

- `scootRight(offset, bySize)`: the one growth primitive — open a hole of
  bySize u16s at `offset`, growing `data` to suit. Caller fixes offsets via
  `Keys.updateOffsets` (strictly-greater-than comparison, so the container at
  `offset` itself doesn't shift). `offset == data.len` scoots nothing and is
  therefore a plain append, which is how sroar's separate `fastExpand` is
  spelled here. The hole is not zeroed (see "Zeroing and canonical form"): callers initialize
  the headers they create, and bitmap payloads are cleared by whoever builds
  one.

  Shaped after `std.array_list.addManyAt`, which solves the same problem:
  - Capacity comes from `growCapacity(needed) = needed + needed/2 + 32`, lifted
    from `std.array_list`. Growing off the length *required* rather than the
    capacity *held* guarantees slack; sroar's `cap + max(cap, bySize)` lands on
    exactly the new length whenever one step asks for more than the buffer
    holds (a bitmap container arriving in a small buffer), so the next write
    reallocates again.
  - Growth tries `allocator.remap` first. For the C allocator that reaches
    `realloc`, letting a large buffer grow by extending its mapping rather than
    copying it. This works only because our alignment is 8: `remap` falls back
    to `null` unconditionally once the requested alignment exceeds
    `max_align_t`.
  - When remap fails, the head `[0, offset)` and the tail `[offset, len)` are
    copied straight to their final positions in the new allocation, so the tail
    is copied once instead of being copied whole and then scooted.
  - A borrowed buffer is never remapped or freed, only copied out of.
- `newContainer(sz)`: append empty array container at end (header initialized,
  payload dead bytes), write header size,
  return offset.
- `expandContainer(key, offset)`: double the container (or jump to 4100 +
  convert array→bitmap at the 3072 threshold). A container last in the
  buffer grows by plain append. Any other container is MOVED to the end
  of the buffer instead of grown in place: growing in place would memmove
  everything behind it at every rung of the size ladder — quadratic over
  a build — while the move costs one container copy plus a dead slot. The
  key is repointed at the new offset; the old slot is marked an empty array
  container behind its size header (a "dead slot" — cardinality zero is what
  cleanup reclaims by; its payload is dead bytes).
  `copyAt(key, offset, src)` — which installs a finished container,
  growing the existing one if `src` no longer fits — follows the same
  rule, since `src` replaces the old contents entirely anyway.
- Dead-slot policy: `markDead` tracks abandoned u16s in `Bitmap.dead`.
  Once dead slots exceed a quarter of the buffer (`dead * max_dead_divisor
  > data.len`, `max_dead_divisor = 4`), the mutating op runs `cleanup`
  itself, bounding the waste a build-heavy workload can accumulate at 25%
  of the buffer. Dead slots are empty array containers (cardinality zero,
  payload dead bytes), so the existing cleanup machinery reclaims them with
  no new code. A buffer
  serialized with dead slots still in it is valid — readers go through
  the keys node and never see them — it is just larger than it needs
  to be.
- `setKey(key, offset) -> new offset`: insert key; if the node grew, every
  offset (including the one being set) shifts — callers must use the returned
  offset. Mirrors Go `bitmap.go:144-175`.

## Serialization

- `toBuffer(self) AlignedConstU8` — `std.mem.sliceAsBytes(self.data)`. O(1).
  Valid until the bitmap grows or is deinited. Empty bitmap returns its
  (minimal, valid) buffer — no null special case.
- `toBufferCopy(self, allocator) !AlignedU8` — owning copy.
- `fromBuffer(allocator, buf: AlignedU8, .borrow | .own) !Bitmap` — O(1),
  no copy: `buf.len % 2 == 0` and `buf.len >= minimal` required (else a
  fresh empty bitmap); an unknown version is refused
  (`error.UnsupportedFormatVersion`). With `.borrow`, `buf` is never
  written to or freed and must outlive the bitmap: every mutation begins
  with `ensureOwned`, which copies the buffer out first. With `.own`, the
  bitmap mutates, remaps and (in `deinit`) frees `buf` itself; the
  transfer is unconditional — the empty-bitmap and error returns free an
  owned `buf` too.
- `fromBufferCopy(allocator, buf: []const u8) !Bitmap` — copy up front
  (also the path for unaligned input).
- **Format is little-endian by definition** — not "native-endian". On
  little-endian hosts (x86-64, ARM64, RISC-V, WASM — every supported target)
  this is free: reinterpretation IS the little-endian encoding. Big-endian
  targets are rejected with a comptime guard in zroar.zig:
  `if (builtin.target.cpu.arch.endian() != .little) @compileError(...)` —
  fail loudly at compile time rather than corrupt data silently. (BE support,
  if ever wanted, becomes an explicit swap-on-open in `fromBufferCopy`
  without changing the format.) A file written on any supported machine reads
  on every supported machine.
- Format is versioned (the first two bytes; see the keys-node section) and
  otherwise trusted: beyond the version and size checks, buffers are
  validated only by debug assertions; production callers own integrity
  (checksums live a layer above, e.g. the storage engine).

## Public API (src/zroar.zig)

Construction/lifetime: `init(allocator) !Bitmap`, `deinit`,
`fromSortedList(allocator, []const u64) !Bitmap`, `clone`.
Serialization: `fromBuffer`, `fromBufferCopy`, `toBuffer`, `toBufferCopy`.
Point ops: `set(x) !bool` (true if newly added), `contains(x) bool`,
`remove(x) bool`.
Queries: `getCardinality() u64`, `isEmpty() bool`, `minimum() ?u64`,
`maximum() ?u64`, `toArray(allocator) ![]u64`, `iterator() Iterator` with
`next() ?u64`.
Fused counts (no materialization, no allocation, take `*const`):
`andCardinality(a, b) u64`, `orCardinality(a, b) u64`,
`andNotCardinality(a, b) u64`.
Set ops: `andInPlace(*const Bitmap) void` (in-place, allocation-free),
`orInPlace(*const Bitmap) !void`, `andNotInPlace(*const Bitmap) void`,
`And(allocator, a, b) !Bitmap`, `Or(allocator, a, b) !Bitmap`,
`fastOr(allocator, []const *const Bitmap) !Bitmap`, `cleanup() void`
(compact zero-cardinality containers and relocation dead slots, resetting
`dead`; preserves key 0).

Intersection and difference results are subsets of the left operand, so the
in-place forms compute the result inside the left container itself — a
two-pointer rewrite whose writes never overtake its reads. No allocation, no
orphaned containers.

Out of scope (deliberately not offered): rank/select, range removal, bitmap
splitting, parallel n-ary union; run containers are excluded by constraint 3.

Error policy: only operations that may allocate return `error{OutOfMemory}!T`.
All reads take `*const Bitmap` and cannot fail. Internal invariant violations
are `std.debug.assert` (verified in Debug/ReleaseSafe, free in ReleaseFast).

## Zeroing and canonical form

Zeroing is done in place by `zero.zig`, and only where zeros are data. A
bitmap container's payload is its bits, so whoever creates one clears it
(`toBitmap`/`toBitmapInto`, and the two sites that build one bit by bit);
everything else the headers bound — array slack, dead slots, spare key
pairs, scoot holes — is dead bytes and is not zeroed. The working buffer is
therefore NOT canonical: two equal sets need not match byte for byte, and
bytes of removed values may linger in the slack. `compact()` is the
canonicalizer — it rebuilds into a zeroed buffer, so equal sets compact to
identical bytes, and it is the step before storing; serialize a
non-compacted buffer only if its dead bytes are acceptable in the output.

## fastOr (the flagship bulk union — port with one simplification)

Go's FastOr (bitmap.go:1134): estimate per-key cardinality across all inputs,
create ALL keys first, then bitmap containers (est >= 4096), then array
containers, then lazy-OR each input in (cardinality sentinel invalid), then
repair cardinalities. Ours does the same but replaces the
`map[uint64]int` + per-insert `setKey` with: collect (key, card) pairs from
all inputs into a list, sort by key, merge-sum duplicates, then build the
keys node in one pre-sized pass. Clamp summed estimates at 65536.

## File layout

```
zroar/
├── DESIGN.md            (this file)
├── build.zig            lib module + `zig build test` + bench exe + difftest exe
├── src/                 production code carries no test blocks; tests live in
│   │                    the *_test.zig files beside it
│   ├── zroar.zig        pub Bitmap, buffer machinery, public API
│   ├── keys.zig         Keys node view + search/set/updateOffsets
│   ├── container.zig    array + bitmap container kernels, conversions
│   ├── setutil.zig      union2by2 / intersection2by2 / gallop / difference on []u16
│   ├── zero.zig         vector zero fill, in place of the slow compiler_rt memset
│   ├── iterator.zig     forward iterator (next() ?u64)
│   ├── tests.zig        the single test root: imports every test file below
│   ├── test_util.zig    shared helpers (checkInvariants, builders, ref sets)
│   ├── zroar_test.zig   \
│   ├── container_test.zig|  unit tests, moved out of the files they cover
│   ├── setutil_test.zig  |
│   ├── keys_test.zig    /
│   └── prop_test.zig    property tests vs std.AutoHashMapUnmanaged reference
└── bench/
    ├── bench.zig        harness + CRoaring's 64-bit benchmarks ported row for row, plus the open axis
    ├── datasets.zig     per-file fixtures (realdata / OLTP), synthetic-grid shapes, pre-serialization
    ├── difftest.zig     zroar vs roaring64 differential test
    ├── roaring64.zig    hand-declared externs for the slice of CRoaring's roaring64 API used
    ├── fetch_croaring.sh  clones CRoaring (source + realdata) into /tmp/CRoaring
    ├── run_all.sh       runs data sets pinned to a CPU → <prefix>-<set>.tsv → <prefix>-report.md
    └── report.py        renders --out .tsv files as the Markdown report
```

## Testing strategy

1. Unit tests in `src/<name>_test.zig`, reached through `src/tests.zig`
   (`zig build test`, run in Debug and ReleaseSafe): a file nothing imports
   has its tests silently skipped, so every test file must be listed there.
   Coverage: setutil merges incl. gallop threshold; container conversion
   at the array→bitmap boundary (`max_array_values` ± 1); keys-node growth under many keys; boundary
   values 0, 0xFFFF, 0x10000, 1<<48, maxInt(u64); round-trip
   `fromBuffer(toBufferCopy(bm))` bit-identical (`std.mem.eql` on u16s).
2. Property tests (prop_test.zig): seeded `std.Random.DefaultPrng`; random
   set/remove/contains streams (clustered and scattered distributions)
   mirrored into `std.AutoHashMapUnmanaged(u64, void)`; periodic checkpoints
   compare cardinality/min/max/sorted-toArray/iterator; mid-stream
   serialize→reopen→continue mutating (validates copy-on-grow); algebra
   checks for and/or/andNot/fastOr vs reference sets.
3. Differential test (bench/difftest.zig, links CRoaring from its checkout):
   identical op streams into zroar and `roaring64.Bitmap64`, compare
   cardinality every 1k ops and full arrays at checkpoints; plus a bulk-build
   pass (sorted build, both serialized round trips, removes) and a set-algebra
   pass (And/Or/AndNot materialized, in place and fused, fastOr, compact)
   against CRoaring's equivalents. `zig build difftest` is one fixed-seed
   pass (~2s); `zig build difftest -- --soak <sec>` repeats it with fresh
   derived seeds until the time is up, printing progress and, on a failure,
   the seed that replays it.

## Benchmarks (bench/bench.zig)

Principle: a statement about how zroar compares to CRoaring rests on
CRoaring's own benchmarks, ported row for row, so a reader can hold our
numbers next to theirs; anything we add is an axis on top of those rows, not
a bench of our own design. 64-bit only (`roaring64_bitmap_t`), which is what
zroar is.

Three suites, selected with `--suite`, all through one harness (one warm-up
call, then calls until a per-row budget — 500 ms, Google Benchmark's default
minimum — is spent, per implementation; markers of every implementation must
agree before any timing; `std.heap.c_allocator` in measured regions since
CRoaring mallocs; seeded PRNGs; ReleaseFast forced):

1. `realdata` — `microbenchmarks/bench.cpp`, its 64-bit rows over the
   per-file bitmaps of a CRoaring data set (`run_optimize`d, values as the
   files hold them): Successive{Intersection,Union}64,
   Successive{Intersection,Union,Difference}Cardinality64, RandomAccess64,
   ToArray64, IterateAll64, ComputeCardinality64. Bodies copied line for
   line. Omitted: RandomAccess64Cpp (their C++ `Roaring64Map`, unreachable
   from Zig) and every 32-bit row.
2. `synthetic` — `microbenchmarks/synthetic_bench.cpp`, its `r64*` rows over
   their grid: ContainsHit/Miss, Insert, Remove, Serialize, Deserialize for
   count ∈ {1e3,1e4,1e5,1e6} × step ∈ {1, 2^8, …, 2^48} (values `i * step`,
   wrapping as C does), and ContainsRandom / InsertRemoveRandom under their
   ten bitmasks. Row `X/c/s` is their `r64X/c/s`. Per-op rows do one pass
   over the sequence per call and divide by its length. One deliberate
   departure: a fixed seed instead of `std::random_device`, so both sides
   see identical values and the marker check can hold.
3. `cold` — ours: every realdata row again with the bitmaps opened from
   their serialized form inside the call (`Cold*`), and MixedOLTP (a
   transaction against a posting-list index: size-weighted open, 90% contains
   / 10% append, close). This is the axis zroar is designed for.

Formats: wherever a buffer is opened or written, r64 gets two columns —
**portable** (the interchange format; what a store would keep) and
**frozen** (CRoaring's memory layout written out and viewed in place with
`frozen_view`, read-only, 64-byte aligned, disclaimed as unstable across
releases). zroar's format is of the frozen kind — little-endian by
definition, unversioned, only zroar reads it — so frozen is the like-for-like
column and portable the deployment-realistic one; both are reported. Frozen
views are read-only, so MixedOLTP (which appends after opening) opens its
frozen column as `frozen_view` plus `roaring64_bitmap_copy` — the writable
bitmap a frozen-format user has to make first. (Measured, that is slower than
the portable parse: the tree is built twice and every container cloned.)
Serialized sizes are reported for all three. zroar's per-input
bitmaps and synthetic shapes are `compact()`ed before their buffers are taken
(at setup, untimed) — the counterpart of CRoaring's exact portable encoding
and the `shrink_to_fit` its frozen format demands — so sizes and the
Serialize row measure what a store would write, not growth slack.

Data: `realdata` dirs from `/tmp/CRoaring/benchmarks/realdata/` (text files
of comma-separated u32, one bitmap per file; `bench/fetch_croaring.sh` fetches
them with the CRoaring source), or the generated OLTP index (`--oltp`: 200
Zipf-sized posting lists over 10M auto-increment row-ids). The synthetic
suite builds its own shapes per row. Standard set: census1881, census-income, weather_sept_85
(run containers save CRoaring 1–6% there; on the `_srt` variants and
wikileaks 64–90%, which would measure run containers, not the layouts) plus
both OLTP modes.

build.zig wiring for bench/difftest: CRoaring is compiled straight from a
checkout of its repository (`-Dcroaring=<path>`, default `/tmp/CRoaring`,
which `bench/fetch_croaring.sh` populates at a pinned tag): every `.c` under
`<croaring>/src`, found by walking the tree at configure time, with
`<croaring>/include` on the include path, `link_libc = true`, and CRoaring's
own AVX512 auto-detect. `bench/roaring64.zig` declares the ~30 functions the
bench and difftest call as `extern fn` by hand (the headers pull in CRoaring's
internal container code, which Zig's C translator does not accept, and every
type crossing is an opaque pointer, integer or bool) and wraps them. The
CRoaring version is read from the checkout at configure time and handed to the
bench as the `croaring` options module. With no checkout the `bench`/`difftest`
steps fail with a pointer to the script; `test` and `searchbench` never look
for it.

Reporting: `--out <tsv>` writes `meta`/`row` lines; `bench/report.py` renders
any number of them as one Markdown report (ratios only, synthetic grid
condensed unless `--full`); `bench/run_all.sh` runs the standard set (the
realdata sets on which run containers buy CRoaring little — zroar has none —
plus the OLTP indexes and the synthetic grid), pinned to one CPU, and writes
the report next to the results (`-o <prefix>`); BENCHMARKS.md is written by
hand.
