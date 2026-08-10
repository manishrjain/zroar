# zroar vs roaring-zig (CRoaring roaring64) — benchmark results

Date: 2026-08-07. Toolchain: Zig 0.16.0, ReleaseFast, x86-64 (no AVX-512, so
CRoaring ran its AVX2/scalar paths). CRoaring 4.3.9 via the roaring-zig
wrapper, with `runOptimize()` applied to every roaring64 bitmap (run
containers enabled — its best case). zroar has no run containers by design.

Method: `zig build -Doptimize=ReleaseFast bench -- <dataset-dir>` — 1 s
timing loop per bench, warmup iteration excluded, both libraries driven by
identical data with setup-time equivalence checks (element-identical union
content; every zroar/r64 bench pair must return identical markers or the
harness panics). Harness floor is ~19 ns/iteration; ColdOpen0-zroar measures
at the floor, i.e. the real open cost is ~1 ns.

Datasets: four CRoaring realdata sets (200 files each; union bitmap U built
from per-file values widened by `file_index << 32` to exercise multi-level
keys) plus seeded synthetic shapes. Merge10K/Build* are synthetic shapes and
identical across runs.

## Results (ratio = r64 time / zroar time; >1 means zroar faster)

| Benchmark | census1881 | census-income | wikileaks | weather_sept_85 | synthetic |
|---|---|---|---|---|---|
| ColdOpen0 (open+close) | ~10,900× | ~14,500× | ~10,800× | ~49,600× | ~6,700× |
| ColdOpen256 (open+256 reads) | 50× | 158× | 54× | 421× | 68× |
| WarmContains (1024 probes) | 1.6× | 1.6× | 1.2× | 1.9× | 1.6× |
| WarmIterate | 7.0× | 7.2× | 10.2× | 6.2× | 7.3× |
| WarmCardinality | 8.8× | 18.8× | 30.1× | 11.9× | 14.2× |
| UnionAllSer (200 opens+union+ser) | 4.3× | 2.7× | 20.9× | 2.8× | 2.2× |
| Merge10K (10k-way union) | 6.1× | 6.3× | 6.3× | 6.2× | 6.1× |
| BuildSortedSer (100k sorted) | 4.7× | 4.8× | 4.8× | 4.8× | 4.7× |
| **Mixed90R10W (90% read / 10% random write)** | **0.26×** | **0.28×** | **0.26×** | **0.24×** | **0.39×** |
| **BuildSer (100k random-order)** | **0.25×** | **0.25×** | **0.25×** | **0.25×** | **0.25×** |
| Serialized size (zroar/r64) | 1.51× | 1.23× | 4.37× | 1.20× | 1.57× |

Absolute anchors (census1881, U = 200 files, ~1.0 M values): zroar open ~1 ns
vs r64 218 µs; a warm `contains` ~19 ns vs ~30 ns; full iterate 740 µs vs
5.17 ms; U serialized 2.85 MB vs 1.89 MB.

## Reading the numbers

**Cold open is the thesis, confirmed.** `fromBuffer` is a pointer
reinterpretation; roaring64's portable deserialize is O(data) with a per-
container malloc + ART insert. On weather_sept_85 (12.9 M values) one r64
open costs ~1 ms — zroar's is free at any size. Even amortized over 256
point reads per open, zroar stays 50–420× ahead. Break-even is in the tens
of thousands of reads per open.

**Warm reads win too, despite CRoaring's SIMD.** Point lookups are memory-
latency-bound (keys binary search + container probe) — zroar's flat buffer
beats the ART walk by ~1.2–1.9×. Iteration and cardinality are wider wins:
no per-container pointer chasing, cardinality is a header sum.

**Bulk ordered writes win.** `fromSortedList` (pre-sized keys node, fill
left-to-right) builds 4.7× faster than r64's add-loop+runOptimize; `fastOr`
(all keys first, bitmap containers next, arrays last, lazy cardinality)
takes the 10k-way union 6× faster.

**Random scattered writes lose ~4×, uniformly.** Mixed90R10W and BuildSer
insert uniformly random values: each new key or container growth memmoves
everything to its right — O(buffer) per write. This is the structural price
of the flat layout, not a bug (BuildSortedSer proves it: identical values,
sorted order, 4.7× win). Workloads with write locality or batched/sorted
write application sit on the winning side of this line.

**Space costs 1.2–4.4×.** No run containers and no bitmap→array demotion.
wikileaks (long runs of consecutive ids) is the worst case at 4.4×; typical
data pays ~20–60%.

## Verdict for a 90% read / 10% write index workload

If bitmaps are opened per operation (posting-list pattern), zroar wins by
orders of magnitude — the open cost dominates everything and zroar's is
zero, while its warm reads are also faster across the board. The losses are
confined to (a) uniformly random single-value writes into large bitmaps,
addressable at the storage layer by batching/sorting writes before applying
them (which Egres's write path would naturally do), and (b) serialized
size on run-heavy data.

## CRoaring microbenchmark suite (`-b 64-`)

The same harness also replicates the 64-bit CRoaring microbenchmarks
(as mirrored by roaring-zig/microbench; r64 columns verified within 6% of
that harness on 9 of 10 benches). Per-file bitmaps are loaded unwidened,
exactly as the microbench does. Ratio > 1 = zroar faster.

| Benchmark | census1881 | wikileaks | Notes |
|---|---|---|---|
| SuccessiveIntersection64 | 0.73× | 0.87× | pairwise materialized ∩ (after output-proportional And; was 0.10×/0.37×) |
| SuccessiveIntersectionCardinality64 | 0.08× | 0.28× | ¹ API gap |
| SuccessiveUnionCardinality64 | 0.03× | 0.22× | ¹ API gap |
| SuccessiveDifferenceCardinality64 | 0.25× | 0.76× | ¹ API gap (clone) |
| SuccessiveUnion64 | 0.30× | 0.72× | pairwise materialized ∪ |
| TotalUnion64 | 4.5× | 20.9× | ² fastOr vs orInPlace fold |
| RandomAccess64 | 2.4× | 1.8× | |
| ToArray64 | 0.15× | 1.9× | ³ no bulk unpack |
| IterateAll64 | 6.1× | 8.4× | |
| ComputeCardinality64 | 7.2× | 21.1× | |

Skipped: RankManySlow (zroar has no rank), TotalUnionHeap (no 64-bit
or-many on either side).

¹ CRoaring's `*_cardinality` calls count the result without materializing
it; zroar has no fused variants, so it materializes + counts + frees (the
difference additionally clones the left operand). The zroar bodies of
`SuccessiveIntersection64` and `SuccessiveIntersectionCardinality64` are
identical — these rows measure a missing API, not the data structure.
Cardinality-only kernels (walk both key lists, count matches per container,
zero allocation) would be a small, readable addition and would close most
of this gap.
² Flatters zroar: the 64-bit C API has no or-many, so r64 folds 199
sequential `_orInPlace` calls where zroar uses pre-sized `fastOr`.
³ ~90% of ToArray64-zroar is iterator traversal; a bulk unpack-into-buffer
would close it. The two-operand `Or` could also adopt fastOr's pre-sizing
strategy instead of clone-then-merge.

**Takeaway:** on pairwise materialized set operations over small bitmaps —
CRoaring's strongest suit and its SIMD kernels' best case — zroar was
initially 1.4–10× slower. Rewriting two-operand `And` to be
output-proportional (count matching keys, pre-size the keys node,
intersect into scratch, emit only non-empty exactly-sized containers,
no cleanup pass) closed its gap to 1.15–1.38×, confirming the earlier
deficit was materialization overhead, not the flat layout. The remaining
red rows are the unimplemented fused-cardinality APIs (deliberately
skipped), `Or` (fastOr-strategy rewrite is the known fix), and bulk
toArray. Aggregate unions, point reads, iteration, and cardinality remain
zroar wins even on this suite.

Bug found by this work: `@popCount` on `@Vector(8, u64)` yields u7 lanes,
and an unwidened `@reduce(.Add, ...)` sums modulo 128 — three in-place
kernels wrote wrapped cardinalities on dense chunks (worst case: cleanup()
deleting live containers). Fixed with a widening cast + a dense-range
regression test; randomized tests never produced a 128-bit chunk, which is
why it survived until a dense benchmark diffed against CRoaring.

## OLTP index datasets (`--oltp`, `--oltp-random`) — the decision benchmark

Synthetic OLTP secondary index: 200 Zipf-sized posting lists (500k down to
~1.7k row-ids, 2.5M total) over a 10M-row table. `--oltp` = dense
auto-increment row-ids; `--oltp-random` = scattered random u64 (UUID-style).
Scattered bits mean run containers stop subsidizing CRoaring. `MixedOLTP`
models a transaction: open a size-weighted posting list from its serialized
buffer, 90% point reads, 10% appends of monotonically fresh row-ids, close.
Ratio > 1 = zroar faster.

| benchmark | oltp (dense ids) | oltp-random (u64 ids) |
|---|---|---|
| ColdOpen0 / ColdOpen256 | 8,342× / 98× | ~17,000,000× / 67,594× |
| WarmContains / Iterate / Card | 1.4× / 7.4× / 16.7× | 1.7× / 4.1× / 3.8× |
| Mixed90R10W (uniform-random writes) | 0.43× | 0.06× |
| **MixedOLTP (append writes)** | **2.13×** | 0.83× |
| SuccessiveIntersection64 | 0.35× | 2.34× |
| TotalUnion64 / UnionAllSer / Merge10K | 1.2× / 2.1× / 10.4× | 8.2× / 8.4× / 10.0× |
| RandomAccess64 | 2.7× | 0.99× |
| **Serialized size (zroar/r64)** | **1.002×** | **6.55×** |

Three findings that decide the Egres question:

1. **Write shape was the whole story.** Append-shaped writes (how OLTP
   allocates row-ids) flip the mixed workload from a 2.3× loss to a 2.1×
   win on the same data — and the flip reproduces on census1881
   (0.26× → 1.58×) and synthetic (0.39× → 10×). The uniform-random write
   loss in Mixed90R10W was a worst case that OLTP index maintenance never
   exhibits. Mechanically: an append lands at the end of the keys node and
   container region (no memmove); a random insert memmoves the tail.
2. **Dense row-ids erase the space penalty**: 1.002× vs CRoaring — run
   containers buy nothing on auto-increment posting lists.
3. **Scattered (UUID-style) row-ids are zroar's structural worst case**:
   ~2.5M near-unique 48-bit keys × 128-byte minimum container = 6.55×
   the space (360 MB vs 55 MB), which in turn erases the open advantage
   in MixedOLTP (0.83×) because every transaction memcpys a 6.5× larger
   buffer. If keys are UUID-derived, zroar needs a smaller minimum
   container (or key-prefix compression) before it makes sense.

Also surfaced: two-operand `Or` has an O(n·m) cliff on key-disjoint
operands (23.9 s vs r64's 127 ms at ~500k disjoint keys each — per-key
`moveRight` memmoves). `fastOr` is immune (8.2× win on the same data), so
the known "reimplement Or via fastOr's pre-sizing" fix is now the single
most actionable item on the list. RandomAccess also shows zroar's point-
lookup edge is a small-directory edge: dead even at 500k keys.

## Optimization round 2 (2026-08-08): Or via fastOr, min_size = 8, fused counts

Three changes, verified by the full suite + difftest + equivalence checks:

1. **Two-operand `Or` now delegates to `fastOr`** (pre-sized build instead of
   clone-then-merge). The key-disjoint cliff collapsed: --oltp-random
   `SuccessiveUnion64` 23.4 s → 649 ms (r64: 596 ms). `orInPlace` is
   unchanged and documents its many-new-keys cost.
2. **`container.min_size` is now the one adjustable sizing knob, default 8
   u16s** (was 64). Scattered-u64 serialized size fell 360 MB → 80 MB
   (6.55× → **1.45×** of r64), flipping --oltp-random `MixedOLTP` from 0.85×
   to **14.6× faster** than r64. Dense datasets unchanged (as predicted).
   Cost, measured and accepted: `BuildSer` (100k uniform-random sets, ~65
   values/container) regressed 2.14× from extra early growth steps —
   raise `min_size` to trade back if that pattern ever matters; sorted/bulk
   builds are unaffected (220 µs).
3. **Fused `andCardinality`/`orCardinality`/`andNotCardinality`** (count
   without materializing). All three `Successive*Cardinality64` benches now
   beat r64 on every dataset — census1881: 15.0/17.4/16.6 µs vs r64's
   15.9/47.4/33.4 µs; --oltp-random: 9.3× / 4.6× / 7.4× faster.

Behavioural note: `Or`/`fastOr` results may carry one dead 16-byte key-0
container (bounded, constant, reclaimed exactly by `cleanup()`).

Remaining known gaps after this round: `Mixed90R10W` on scattered data
(uniform-random `set` pays the same per-new-key memmove `Or` used to — not
an OLTP write shape, unscheduled), `ToArray64` on dense data (~3×, needs a
bulk unpack), dense-data `SuccessiveIntersection64` (~3×, CRoaring SIMD +
run-container kernels on mid-density containers).

## Optimization round 3 (2026-08-08): SIMD block-match intersection

The balanced array∩array core (`localIntersectCore`) gained a portable
SIMD block phase: all-pairs matching of 8-element blocks via comptime
rotations (`@Vector(8, u16)`, no asm, no runtime shuffles), `.count` mode
consuming matches as a popcount, `.materialize` as a ctz-gather; the scalar
two-pointer loop remains as the tail. Verified by interleaved A/B (5 pairs,
medians, r64 rows as machine-noise controls, ≤1.4% drift):

- dense `--oltp` SuccessiveIntersection64: 11.05 ms → **2.73 ms (−75%)**,
  now BEATS r64's 3.70 ms; the Cardinality row 9.98 ms → **2.42 ms**, beats
  r64's 2.84 ms. The last dense-data intersection gap is closed and inverted.
- census1881: −9.6% / −7.6%; --oltp-random: −2.1% / −4.7%; no regressions.

The in-place aliasing contract (`andArray` writes over its own left
operand) was re-proven for the block phase and is covered by a dedicated
seeded test.

Correctness evidence: 70 unit tests + property tests vs a hashmap reference
(Debug/ReleaseSafe/ReleaseFast), and a differential test running 810,000
identical ops through zroar and roaring64 with zero divergence
(`zig build difftest`); the test suite's sensitivity was itself verified by
mutation testing (5 injected bugs, 5 caught).

## Reproducible TPC-C-derived uint64 index workload

The older `--oltp` modes above are useful synthetic shapes, but they are not a
standard transaction model. A separate generator/replay benchmark now derives
indexed-table population and the 10/10/1/1/1 transaction deck from TPC-C 5.11,
then compares zroar and CRoaring over dense, locality-packed, and bijectively
scattered uint64 primary keys. It has resident and native-serialized lifecycle
profiles, deterministic portable artifacts, checksums, per-operation expected
answers, final-state digests, alternating library order, and an end-of-run
winner table that says which implementation is faster in each case. The
posting-list snapshot, immutable SELECT/read trace, and mutation-only write
trace are separate artifacts: read timing never creates or rewrites a posting
list, while write maintenance is reported separately.

Generate and replay the canonical ten-warehouse, 23,000-transaction dataset:

```sh
zig build tpcc-generate -- --out /tmp/zroar-tpcc
zig build -Doptimize=ReleaseFast tpcc-bench -- /tmp/zroar-tpcc
zig build -Doptimize=ReleaseFast tpcc-bench -- /tmp/zroar-tpcc --workload write
```

This is a **TPC-C-derived bitmap-index workload**, not a TPC benchmark; its
results are not comparable to TPC-C results and are never reported as tpmC.
The complete schema mapping, format, commands, timing rules, limitations, and
fair-use references are in [`bench/tpcc/README.md`](bench/tpcc/README.md).
