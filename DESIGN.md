# zroar — Design

A Zig port of [sroar](https://github.com/dgraph-io/sroar) (serialized roaring
bitmaps over u64 keys). The defining property: **the on-disk representation is
the in-memory representation**. Opening a serialized bitmap (`fromBuffer`) is
O(1) — no parsing, no per-container allocation. This exists to benchmark
against roaring-zig (CRoaring's `roaring64_bitmap_t`), where every open costs a
full portable deserialize (~1–2 µs per small bitmap, ≈75–280 `contains`
calls, measured 2026-08).

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
    return .{ .n = p[0 .. p[0] / 4] };   // p[0] = node size in u16 units
}
```

Layout in u64 units:

| u64 index | meaning |
|---|---|
| 0 | node size in **u16 units** (multiple of 4) |
| 1 | number of keys |
| 2 + 2i | key i — `value & 0xFFFF_FFFF_FFFF_0000` (top 48 bits) |
| 3 + 2i | offset of container i into `data`, in u16 units (multiple of 4) |

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

**Array container**: payload = sorted unique u16s. Allocated sizes double
from `container.min_size` up to 2048 u16s (header included). `min_size` is
the one adjustable knob for the waste-vs-growth-steps trade-off (see its doc
comment); the default of 8 u16s (16 bytes, 4 value slots) keeps single-value
containers nearly free — the case that dominates scattered u64 keys.
Membership: binary search (`std.sort.binarySearch`-style; linear scan is fine
below ~16 elements). Insert/remove: memmove within the container.
**Invariant: after any successful insert an array container has >= 1 free
slot** — `set` inserts first, then expands/converts if now full. When growth
would exceed 2048 u16s, convert to a bitmap container instead.

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
- array → bitmap: when the array would grow past 2048 u16s (~2044 values).
- union of two arrays / fastOr pre-sizing: a bitmap container whenever no
  array container fits the (estimated) cardinality, i.e. > ~2043 values.
  (Go's documented 4096 threshold is unreachable under this ladder — two
  maximal arrays sum to 4086 — so the effective rule is "fits or converts".)
- **No demotion of an existing bitmap container.** Result-type *selection at
  creation* by cardinality (e.g. And emitting a small array from a
  bitmap∩bitmap) is allowed and used.

### Growth machinery (port of sroar bitmap.go, same names where sensible)

- `scootRight(offset, bySize)`: the one growth primitive — open a zeroed hole of
  bySize u16s at `offset`, growing `data` to suit. Caller fixes offsets via
  `Keys.updateOffsets` (strictly-greater-than comparison, so the container at
  `offset` itself doesn't shift). `offset == data.len` scoots nothing and is
  therefore a plain append, which is how sroar's separate `fastExpand` is
  spelled here. The newly opened hole must be zeroed before use (Zig allocators
  do not zero; Go's bug here — Memclr counting elements as bytes — is not
  ported).

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
- `newContainer(sz)`: append zeroed container at end, write header size,
  return offset.
- `expandContainer(key, offset)`: double the container (or jump to 4100 +
  convert array→bitmap at the 2048 threshold). A container last in the
  buffer grows by plain append. Any other container is MOVED to the end
  of the buffer instead of grown in place: growing in place would memmove
  everything behind it at every rung of the size ladder — quadratic over
  a build — while the move costs one container copy plus a dead slot. The
  key is repointed at the new offset; the old slot is zeroed behind its
  size header, leaving a canonical empty array container (a "dead slot").
  `copyAt(key, offset, src)` — which installs a finished container,
  growing the existing one if `src` no longer fits — follows the same
  rule, since `src` replaces the old contents entirely anyway.
- Dead-slot policy: `markDead` tracks abandoned u16s in `Bitmap.dead`.
  Once dead slots exceed a quarter of the buffer (`dead * max_dead_divisor
  > data.len`, `max_dead_divisor = 4`), the mutating op runs `cleanup`
  itself, bounding the waste a build-heavy workload can accumulate at 25%
  of the buffer. Dead slots are canonical empty array containers, so the
  existing cleanup machinery reclaims them with no new code. A buffer
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
- `fromBuffer(allocator, buf: AlignedU8) Bitmap` — O(1) view: `buf.len % 2
  == 0` and `buf.len >= minimal` required (else return a fresh empty
  bitmap); `owned = false`; allocator retained for copy-on-grow. The
  bitmap MAY be mutated; first growth copies out. Non-growing mutations
  write through to the caller's buffer — documented.
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
- Format is unversioned and trusted. Buffers are validated only by debug
  assertions; production callers own integrity (checksums live a layer above,
  e.g. the storage engine).

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

Error policy: only operations that may allocate return `error{OutOfMemory}!T`.
All reads take `*const Bitmap` and cannot fail. Internal invariant violations
are `std.debug.assert` (verified in Debug/ReleaseSafe, free in ReleaseFast).

## Semantics source, and Go bugs that must NOT be ported

Port semantics from `~/source/sroar` (`bitmap.go`, `keys.go`, `container.go`,
`setutil.go`, `iterator.go`). Known Go bugs to avoid:

1. `And(a, b)` reads `a.keys.key(bi)` where it must be `b.keys` (bitmap.go:825).
2. `Memclr` passes an element count where bytes are expected (utils.go:100).
3. `array.andNotBitmap` leaves the result's size header at 4 (container.go:292).
4. Two-operand `Or` can emit an exactly-full array container, violating the
   free-slot invariant (container.go:264).
5. Iterator uses value 0 as an end sentinel — ours returns `?u64`.
6. `And`/`AndNot` append a fresh result container and orphan the old one
   (permanent dead space). Ours: intersection/difference results are subsets
   of the left operand, so compute **in place** in the left container —
   two-pointer writes never overtake reads. No allocation, no orphans.
7. The 32 MB package-level `empty` zeroing buffer — use `@memset`.

`setutil.go`'s `union2by2` / `intersection2by2` (with the 64×-skew galloping
variant `onesidedgallopingintersect2by2` + `advanceUntil`) are sound; port them
as the scalar array-merge kernels. Skip the dead code (`*Cardinality`
variants, `binarySearch`, `equal`, `exclusiveUnion2by2`).

Not ported at all (out of scope): `FastParOr`, `Split`, `Select`, `Rank`,
`RemoveRange`, `ManyItr`, run containers.

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
│   ├── iterator.zig     forward iterator (next() ?u64)
│   ├── tests.zig        the single test root: imports every test file below
│   ├── test_util.zig    shared helpers (checkInvariants, builders, ref sets)
│   ├── zroar_test.zig   \
│   ├── container_test.zig|  unit tests, moved out of the files they cover
│   ├── setutil_test.zig  |
│   ├── keys_test.zig    /
│   └── prop_test.zig    property tests vs std.AutoHashMapUnmanaged reference
└── bench/
    ├── bench.zig        harness (idioms cloned from roaring-zig/microbench/bench.zig)
    ├── datasets.zig     realdata loader, synthetic generators, pre-serialization
    └── difftest.zig     zroar vs roaring64 differential test
```

## Testing strategy

1. Unit tests in `src/<name>_test.zig`, reached through `src/tests.zig`
   (`zig build test`, run in Debug and ReleaseSafe): a file nothing imports
   has its tests silently skipped, so every test file must be listed there.
   Coverage: setutil merges incl. gallop threshold; container conversion
   at 2043/2044/2045 elements; keys-node growth under many keys; boundary
   values 0, 0xFFFF, 0x10000, 1<<48, maxInt(u64); round-trip
   `fromBuffer(toBufferCopy(bm))` bit-identical (`std.mem.eql` on u16s).
2. Property tests (prop_test.zig): seeded `std.Random.DefaultPrng`; random
   set/remove/contains streams (clustered and scattered distributions)
   mirrored into `std.AutoHashMapUnmanaged(u64, void)`; periodic checkpoints
   compare cardinality/min/max/sorted-toArray/iterator; mid-stream
   serialize→reopen→continue mutating (validates copy-on-grow); algebra
   checks for and/or/andNot/fastOr vs reference sets.
3. Differential test (bench/difftest.zig, links croaring via roaring-zig):
   identical op streams into zroar and `roaring64.Bitmap64`, compare
   cardinality every 1k ops and full arrays at checkpoints.

## Benchmarks (bench/bench.zig)

Copy the mechanics of `~/source/roaring-zig/microbench/bench.zig` (proven on
Zig 0.16): `pub fn main(init: std.process.Init)`, registry of
`{name, func: *const fn (*const DataSet) u64}`, marker u64 to defeat DCE,
1 warmup + loop until 1 s wall time via `std.Io.Clock.Timestamp.now(io,
.awake)`, print `{s:<36}{d:12} ns {d:12}`, `-b` substring filter.
`std.heap.c_allocator` in measured regions (CRoaring uses libc malloc).
Seeded `DefaultPrng`, re-initialized per iteration. Build ReleaseFast.

Comparison target: roaring64 **portable** serialize/deserialize only (frozen
formats are out of scope). Datasets: realdata dirs from
`/tmp/CRoaring/benchmarks/realdata/` (text files of comma-separated u32,
one bitmap per file; widen values by `| (file_index << 32)` for the union
bitmap so multi-level keys are exercised) plus seeded synthetic shapes
(dense∩sparse, 10k×1k sparse merge, sequential dense).

Bench list (U = union of all widened files; suffixes `-zroar` / `-r64`):
ColdOpen{0,1,16,256} (open pre-serialized U + k contains + close; r64's
free() inside the measured region), WarmContains (1024 mixed hit/miss
probes), WarmIterate, WarmCard, Mixed90R10W (open from buffer + 100k ops at
90% contains / 10% set + close; zroar via fromBufferCopy, r64 via portable
deserialize), UnionAllSer (open ×k files + union + serialize result),
Merge10K (fastOr vs folded `_orInPlace` over 10k prebuilt synthetic bitmaps),
BuildSer (100k random sets then serialize), MemcpyBaseline (memcpy of U's
buffer, for subtracting pure copy cost).

build.zig wiring for bench/difftest: module for roaring64 rooted at
`../roaring-zig/src/roaring64.zig`, `addIncludePath(../roaring-zig/croaring)`,
`addCSourceFile(../roaring-zig/croaring/roaring.c)`, `link_libc = true`, and
the AVX512 auto-detect block copied from `../roaring-zig/build.zig`. Provide
`-Droaring-zig=<path>` (default `../roaring-zig`).
