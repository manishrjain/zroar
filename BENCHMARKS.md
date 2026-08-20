# zroar vs CRoaring roaring64

Generated 2026-08-19 by `bench/report.py` from `zig build bench --out` files (Zig 0.16.0, CRoaring 5.0.0, ReleaseFast). Ratios; absolute times (µs) are in the .tsv files.

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
  writes after opening, which a frozen view does not allow, so its frozen
  column is `frozen_view` plus `roaring64_bitmap_copy`: the writable bitmap a
  frozen-format user has to make first.
- Sizes and serialization are measured on what a store would write: zroar's
  buffers are compacted first (`compact()`, no growth slack), matching
  CRoaring's exact portable encoding and the `shrink_to_fit` its frozen
  format requires. This happens at setup, outside every timing.
- zroar has no run containers. Data sets where run containers shrink
  CRoaring's bitmaps a lot are left out of the standard set; the saving is
  shown per set below.

## Summary

Geometric means of the ratios (CRoaring's time ÷ zroar's; above 1 = zroar faster), every cell counting the same. *Headline*: one number per table, over every data set. Then the same per data set and per synthetic family, each with its min–max and with *total time*: each library's time summed over the rows and the ratio of the sums, where the expensive rows dominate as they would in a workload. An overview only: the tables further down show where the wins and losses are.

| headline | cells | vs CRoaring | vs frozen |
|---|---|---|---|
| realdata, bitmaps in memory (all data sets) | 36 | 2.15× | – |
| cold, every bitmap opened inside the call (all data sets) | 40 | 6.71× (portable) | 3.35× |
| synthetic, operations (Contains/Insert/Remove/Random; families weighted equally) | 132 | 2.16× | – |
| synthetic, Serialize + Deserialize | 56 | 622× (portable) | 267× |
| synthetic, all families | 188 | 8.91× (portable where a format is involved) | – |

| set | table | typical row | total time |
|---|---|---|---|
| census1881 | realdata (in memory) | 2.46× (0.88×–14.12×) | zroar 1.48 ms · r64 6.95 ms (4.71×) |
| census1881 | cold, opened portable | 11.82× (1.81×–108×) | zroar 2.46 ms · portable 11.47 ms (4.66×) |
| census1881 | cold, opened frozen | 4.72× (1.35×–25.14×) | zroar 2.46 ms · frozen 9.51 ms (3.87×) |
| census-income | realdata (in memory) | 2.25× (0.91×–13.98×) | zroar 12.43 ms · r64 52.94 ms (4.26×) |
| census-income | cold, opened portable | 5.12× (1.11×–156×) | zroar 12.69 ms · portable 57.45 ms (4.53×) |
| census-income | cold, opened frozen | 2.44× (0.95×–16.31×) | zroar 12.69 ms · frozen 53.62 ms (4.23×) |
| weather_sept_85 | realdata (in memory) | 2.14× (0.90×–13.35×) | zroar 32.40 ms · r64 108.05 ms (3.34×) |
| weather_sept_85 | cold, opened portable | 5.96× (1.03×–289×) | zroar 33.14 ms · portable 122.68 ms (3.70×) |
| weather_sept_85 | cold, opened frozen | 2.77× (0.90×–31.05×) | zroar 33.14 ms · frozen 109.91 ms (3.32×) |
| oltp | realdata (in memory) | 1.81× (0.87×–12.07×) | zroar 33.38 ms · r64 47.07 ms (1.41×) |
| oltp | cold, opened portable | 5.61× (1.06×–217×) | zroar 35.00 ms · portable 79.12 ms (2.26×) |
| oltp | cold, opened frozen | 3.96× (0.94×–86.69×) | zroar 35.00 ms · frozen 62.28 ms (1.78×) |

| synthetic family | typical row (vs CRoaring; portable where a format is involved) | vs frozen | total time |
|---|---|---|---|
| ContainsHit | 2.85× (1.28×–4.24×) | – | zroar 159 ns · r64 426 ns (2.68×) |
| ContainsMiss | 3.07× (1.31×–5.20×) | – | zroar 134 ns · r64 367 ns (2.74×) |
| Insert | 2.20× (0.80×–4.22×) | – | zroar 825.29 ms · r64 736.74 ms (0.89×) |
| Remove | 6.79× (1.72×–11.53×) | – | zroar 52.41 ms · r64 340.93 ms (6.50×) |
| Serialize | 23.66× (1.29×–103×) | 13.67× (1.23×–38.30×) | zroar 9.37 ms · portable 206.85 ms (22.07×) · frozen 108.03 ms (11.53×) |
| Deserialize | 16,358× (6.45×–4,412,064×) | 5,215× (2.51×–1,538,984×) | zroar 723 ns · portable 467.69 ms (646,753×) · frozen 180.21 ms (249,205×) |
| ContainsRandom | 1.33× (0.93×–1.89×) | – | zroar 1.5 µs · r64 2.0 µs (1.39×) |
| InsertRemoveRandom | 0.59× (0.33×–1.42×) | – | zroar 101.3 µs · r64 39.4 µs (0.39×) |
| **across the operation families** (Ser/Deserialize excluded) | **2.16×** | | |
| **across all families** (each weighted equally) | **8.91×** | | |

## Data sets

| set | bitmaps | values | zroar | r64 portable | run-container saving | r64 frozen |
|---|---|---|---|---|---|---|
| census1881 | 200 | 1,003,861 | 2.0 MB | 1.8 MB (0.93× of zroar) | 6% | 1.9 MB (0.97×) |
| census-income | 200 | 6,922,021 | 2.3 MB | 2.1 MB (0.93× of zroar) | 5% | 2.2 MB (0.95×) |
| weather_sept_85 | 200 | 12,870,627 | 8.6 MB | 8.3 MB (0.96× of zroar) | 1% | 8.3 MB (0.97×) |
| oltp | 200 | 2,486,531 | 5.9 MB | 5.0 MB (0.85× of zroar) | 0% | 5.7 MB (0.97×) |

## realdata — CRoaring's bench.cpp rows, bitmaps already in memory

Both libraries hold the data set's 200 bitmaps in memory (built once, before timing); each cell is CRoaring's time ÷ zroar's for that benchmark. One column per data set.

| benchmark | census1881 | census-income | weather_sept_85 | oltp |
|---|---|---|---|---|
| SuccessiveIntersection64 | 0.88× | 1.52× | 1.64× | 1.44× |
| SuccessiveIntersectionCardinality64 | 1.32× | 1.42× | 1.36× | 1.20× |
| SuccessiveUnionCardinality64 | 3.63× | 1.49× | 1.41× | 1.39× |
| SuccessiveDifferenceCardinality64 | 2.65× | 1.46× | 1.38× | 1.28× |
| SuccessiveUnion64 | 1.45× | 0.91× | 1.06× | 0.88× |
| RandomAccess64 | 1.50× | 2.66× | 2.34× | 1.49× |
| ToArray64 | 1.27× | 1.02× | 0.90× | 0.87× |
| IterateAll64 | 7.59× | 9.05× | 7.47× | 4.89× |
| ComputeCardinality64 | 14.12× | 13.98× | 13.35× | 12.07× |

zroar faster than CRoaring on 31 of 36 cells.

## cold — the same rows, but every bitmap is opened inside the timed call

Cells read `portable / frozen`: CRoaring's time opening its bitmaps from that format and doing the work, ÷ zroar's time doing the same from its buffer.

| benchmark | census1881 | census-income | weather_sept_85 | oltp |
|---|---|---|---|---|
| ColdSuccessiveIntersection64 | 10.69× / 2.74× | 2.20× / 1.61× | 2.29× / 1.68× | 2.47× / 1.84× |
| ColdSuccessiveIntersectionCardinality64 | 19.92× / 4.67× | 2.79× / 1.56× | 2.48× / 1.45× | 2.25× / 1.61× |
| ColdSuccessiveUnionCardinality64 | 20.52× / 6.29× | 2.86× / 1.63× | 2.46× / 1.49× | 2.43× / 1.78× |
| ColdSuccessiveDifferenceCardinality64 | 20.07× / 5.47× | 2.82× / 1.59× | 2.44× / 1.48× | 2.32× / 1.68× |
| ColdSuccessiveUnion64 | 1.82× / 1.35× | 1.23× / 0.95× | 1.32× / 1.05× | 1.06× / 0.94× |
| ColdRandomAccess64 | 61.40× / 12.25× | 51.28× / 6.01× | 118× / 11.70× | 217× / 86.69× |
| ColdToArray64 | 3.50× / 1.73× | 1.11× / 1.02× | 1.03× / 0.90× | 2.74× / 1.58× |
| ColdIterateAll64 | 8.01× / 7.66× | 9.18× / 9.06× | 7.59× / 7.45× | 5.99× / 5.31× |
| ColdComputeCardinality64 | 108× / 25.14× | 156× / 16.31× | 289× / 31.05× | 120× / 54.30× |
| MixedOLTP | 1.81× / 2.27× | 2.49× / 1.36× | 4.73× / 1.91× | 2.20× / 2.85× |

zroar faster than CRoaring portable on 40 of 40 cells.
zroar faster than CRoaring frozen on 37 of 40 cells.

## synthetic — CRoaring's synthetic_bench.cpp rows, generated shapes

- Each shape is `count` values spaced `step` apart (their `r64X/count/step`, with the step written as a power of two here).
- Step 1 packs everything into one dense container; from step 2^16 up every value sits in its own container under its own key.
- Cells are again CRoaring's time ÷ zroar's, per operation for the Contains rows and per whole build/serialize otherwise.
- At step 2^48 `count × step` overflows past 65,536 values (in C too), so those cells re-insert the same 65,536 values.

Steps 2^16 and up behave alike, so they share one column showing the range across them (`--full` prints every step). Serialize and Deserialize cells read `portable / frozen`.

| benchmark | count | step 1 | step 2^8 | steps 2^16–2^48 |
|---|---|---|---|---|
| ContainsHit | 1,000 | 1.28× | 1.52× | 2.70× |
| ContainsHit | 10,000 | 1.91× | 1.60× | 2.81×–3.30× |
| ContainsHit | 100,000 | 2.88× | 1.91× | 2.83×–3.78× |
| ContainsHit | 1,000,000 | 4.04× | 2.06× | 2.83×–4.24× |
| ContainsMiss | 1,000 | 1.31× | 1.52× | 2.91×–3.58× |
| ContainsMiss | 10,000 | 1.91× | 1.61× | 2.99×–3.80× |
| ContainsMiss | 100,000 | 2.87× | 1.90× | 2.89×–4.47× |
| ContainsMiss | 1,000,000 | 4.07× | 2.08× | 2.88×–5.20× |
| Insert | 1,000 | 0.84× | 1.27× | 4.12× |
| Insert | 10,000 | 1.66× | 1.48× | 3.69× |
| Insert | 100,000 | 2.13× | 1.36× | 2.37× |
| Insert | 1,000,000 | 2.94× | 1.70× | 0.80×–2.90× |
| Remove | 1,000 | 1.73× | 1.83× | 9.25× |
| Remove | 10,000 | 10.12× | 1.98× | 9.91× |
| Remove | 100,000 | 4.79× | 2.08× | 7.32×–11.53× |
| Remove | 1,000,000 | 4.70× | 2.18× | 1.72×–11.44× |
| Serialize | 1,000 | 1.95× / 1.87× | 5.56× / 4.58× | 53.51×–103× / 37.85× |
| Serialize | 10,000 | 1.50× / 1.24× | 5.95× / 5.23× | 47.16×–92.48× / 32.49× |
| Serialize | 100,000 | 1.85× / 1.50× | 4.24× / 3.38× | 44.25×–88.15× / 31.32× |
| Serialize | 1,000,000 | 1.29× / 1.23× | 3.85× / 3.14× | 14.15×–84.81× / 10.37×–33.31× |
| Deserialize | 1,000 | 6.45× / 2.51× | 14.12× / 5.64× | 3,018×–4,002× / 1,584× |
| Deserialize | 10,000 | 50.31× / 2.54× | 139× / 55.02× | 31,399×–40,132× / 14,886× |
| Deserialize | 100,000 | 101× / 3.86× | 1,372× / 646× | 254,741×–398,216× / 96,853×–147,357× |
| Deserialize | 1,000,000 | 793× / 17.89× | 14,538× / 6,752× | 254,787×–4,412,064× / 97,323×–1,538,984× |

Random values under CRoaring's ten bitmasks: 2^20 random values inserted, then random operations on them. Every mask sets 20 bits; they differ in where. Mask 0 puts them all below bit 16 (16 containers, all the work inside them); masks 1, 2, 3, 5, 6 and 8 put none there (2^20 keys with one value each, all the work in the key index, keys added and removed at random); 4, 7 and 9 mix the two. Grouped that way, as ranges (`--full` prints every mask):

| benchmark | containers only (mask 0) | key index only (1, 2, 3, 5, 6, 8) | mixed (4, 7, 9) |
|---|---|---|---|
| ContainsRandom | 1.28× | 1.21×–1.89× | 0.93×–1.42× |
| InsertRemoveRandom | 1.37× | 0.33×–0.40× | 0.94×–1.42× |

zroar faster than CRoaring (portable where a format is involved) on 175 of 188 rows.
zroar faster than CRoaring frozen on 56 of 56 rows.
