# zroar vs CRoaring roaring64

Generated 2026-08-17 by `bench/report.py` from `zig build bench --out` files (Zig 0.16.0, CRoaring 5.0.0, ReleaseFast). Ratios; absolute times (µs) are in the .tsv files.

Measured on AMD Ryzen 9 5950X 16-Core Processor; governor performance, boost on, SMT on, pinned to CPU(s) 3.

How to read this:

- Every cell is a speed ratio: **CRoaring's time ÷ zroar's time** on the same
  benchmark. `2.93×` means zroar took a third of the time (zroar 2.93× faster);
  `0.49×` means zroar took twice as long (zroar 2× slower). **>1 = zroar faster.**
- The benchmarks are CRoaring's own, ported line for line: `bench.cpp`'s 64-bit
  rows over the per-file bitmaps of each data set (section *realdata*), and
  `synthetic_bench.cpp`'s r64 rows over its shape grid (section *synthetic*).
- Section *cold* is ours: the realdata rows again, but every bitmap is opened
  from its serialized bytes inside the timed call — what a store does per
  query. Plus `MixedOLTP`: open one posting list, 90 point reads, 10 appends,
  close.
- Where bitmaps are opened or written, CRoaring has two formats and both get
  a column, written `portable / frozen`. *Portable* is its interchange format
  (a full parse to open). *Frozen* is its in-memory layout written out and
  viewed in place, read-only — the same kind of format as zroar's. `MixedOLTP`
  writes after opening, so it has no frozen column.
- Sizes and serialization are measured on what a store would write: zroar's
  buffers are compacted first (`compact()`, no growth slack), matching
  CRoaring's exact portable encoding and the `shrink_to_fit` its frozen
  format requires. This happens at setup, outside every timing.
- zroar has no run containers. Data sets where run containers shrink
  CRoaring's bitmaps a lot are left out of the standard set; the saving is
  shown per set below.

## Summary

Two views of each table below. *Typical row*: the geometric mean of the ratios, min–max in brackets — every benchmark counts the same. *Total time*: each library's time summed over the rows, and the ratio of the sums — the expensive rows dominate, as they would in a workload. Above 1 = zroar faster. An overview only: the tables show where the wins and losses actually are.

| set | table | typical row | total time |
|---|---|---|---|
| census1881 | realdata (in memory) | 1.95× (0.48×–9.97×) | zroar 2.64 ms · r64 6.93 ms (2.62×) |
| census1881 | cold, opened portable | 10.91× (0.68×–137×) | zroar 4.29 ms · portable 12.99 ms (3.03×) |
| census1881 | cold, opened frozen | 4.52× (0.51×–31.17×) | zroar 2.49 ms · frozen 7.50 ms (3.01×) |
| census-income | realdata (in memory) | 1.96× (0.35×–11.38×) | zroar 16.55 ms · r64 57.86 ms (3.50×) |
| census-income | cold, opened portable | 5.53× (0.92×–294×) | zroar 14.42 ms · portable 59.74 ms (4.14×) |
| census-income | cold, opened frozen | 2.75× (0.71×–33.64×) | zroar 14.27 ms · frozen 55.79 ms (3.91×) |
| oltp | realdata (in memory) | 1.70× (0.66×–10.48×) | zroar 39.45 ms · r64 47.43 ms (1.20×) |
| oltp | cold, opened portable | 5.42× (0.79×–246×) | zroar 40.54 ms · portable 79.08 ms (1.95×) |
| oltp | cold, opened frozen | 3.92× (0.71×–97.87×) | zroar 39.23 ms · frozen 58.48 ms (1.49×) |

## Data sets

| set | bitmaps | values | zroar | r64 portable | run-container saving | r64 frozen |
|---|---|---|---|---|---|---|
| census1881 | 200 | 1,003,861 | 2.4 MB | 1.8 MB (0.76× of zroar) | 6% | 1.9 MB (0.80×) |
| census-income | 200 | 6,922,021 | 2.5 MB | 2.1 MB (0.87× of zroar) | 5% | 2.2 MB (0.89×) |
| oltp | 200 | 2,486,531 | 7.4 MB | 5.0 MB (0.68× of zroar) | 0% | 5.7 MB (0.77×) |

## realdata — CRoaring's bench.cpp rows, bitmaps already in memory

Both libraries hold the data set's 200 bitmaps in memory (built once, before timing); each cell is CRoaring's time ÷ zroar's for that benchmark. One column per data set.

| benchmark | census1881 | census-income | oltp |
|---|---|---|---|
| SuccessiveIntersection64 | 0.78× | 1.31× | 1.40× |
| SuccessiveIntersectionCardinality64 | 1.20× | 1.45× | 1.15× |
| SuccessiveUnionCardinality64 | 3.05× | 1.51× | 1.34× |
| SuccessiveDifferenceCardinality64 | 2.29× | 1.47× | 1.24× |
| SuccessiveUnion64 | 0.48× | 0.35× | 0.66× |
| RandomAccess64 | 1.78× | 2.36× | 1.68× |
| ToArray64 | 1.25× | 1.21× | 0.86× |
| IterateAll64 | 5.78× | 9.02× | 4.43× |
| ComputeCardinality64 | 9.97× | 11.38× | 10.48× |

zroar faster than CRoaring on 22 of 27 cells.

## cold — the same rows, but every bitmap is opened inside the timed call

Cells read `portable / frozen`: CRoaring's time opening its bitmaps from that format and doing the work, ÷ zroar's time doing the same from its buffer.

| benchmark | census1881 | census-income | oltp |
|---|---|---|---|
| ColdSuccessiveIntersection64 | 8.71× / 1.78× | 1.86× / 1.38× | 2.37× / 1.77× |
| ColdSuccessiveIntersectionCardinality64 | 19.24× / 4.41× | 2.82× / 1.58× | 2.17× / 1.54× |
| ColdSuccessiveUnionCardinality64 | 19.42× / 5.87× | 2.90× / 1.66× | 2.36× / 1.71× |
| ColdSuccessiveDifferenceCardinality64 | 19.25× / 5.13× | 2.87× / 1.63× | 2.26× / 1.63× |
| ColdSuccessiveUnion64 | 0.68× / 0.51× | 0.92× / 0.71× | 0.79× / 0.71× |
| ColdRandomAccess64 | 86.10× / 16.65× | 55.60× / 7.06× | 246× / 97.87× |
| ColdToArray64 | 3.38× / 1.64× | 1.31× / 1.23× | 2.70× / 1.57× |
| ColdIterateAll64 | 8.02× / 7.72× | 7.49× / 7.42× | 6.16× / 5.50× |
| ColdComputeCardinality64 | 137× / 31.17× | 294× / 33.64× | 106× / 47.63× |
| MixedOLTP | 1.73× | 4.17× | 2.33× |

zroar faster than CRoaring portable on 27 of 30 cells.
zroar faster than CRoaring frozen on 24 of 27 cells.
