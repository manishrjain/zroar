# zroar vs CRoaring roaring64

Generated 2026-08-20 by `bench/report.py` from `zig build bench --out` files (Zig 0.16.0, CRoaring 5.0.0, ReleaseFast). Ratios; absolute times (µs) are in the .tsv files.

Measured on AMD Ryzen 9 5950X 16-Core Processor; governor performance, boost on, freq range [4.00, 4.00] GHz, SMT on, pinned to CPU(s) 6.

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
| realdata, bitmaps in memory (all data sets) | 36 | 2.20× | – |
| cold, every bitmap opened inside the call (all data sets) | 40 | 6.92× (portable) | 3.44× |
| synthetic, operations (Contains/Insert/Remove/Random; families weighted equally) | 132 | 2.18× | – |
| synthetic, Serialize + Deserialize | 56 | 615× (portable) | 259× |
| synthetic, all families | 188 | 8.92× (portable where a format is involved) | – |

| set | table | typical row | total time |
|---|---|---|---|
| census1881 | realdata (in memory) | 2.64× (0.93×–19.11×) | zroar 1.02 ms · r64 6.94 ms (6.81×) |
| census1881 | cold, opened portable | 12.57× (1.78×–103×) | zroar 2.03 ms · portable 11.55 ms (5.69×) |
| census1881 | cold, opened frozen | 4.94× (1.34×–23.04×) | zroar 2.03 ms · frozen 9.49 ms (4.67×) |
| census-income | realdata (in memory) | 2.26× (0.92×–12.57×) | zroar 12.16 ms · r64 57.61 ms (4.74×) |
| census-income | cold, opened portable | 5.24× (1.14×–158×) | zroar 12.42 ms · portable 62.25 ms (5.01×) |
| census-income | cold, opened frozen | 2.53× (0.94×–17.57×) | zroar 12.42 ms · frozen 58.42 ms (4.70×) |
| weather_sept_85 | realdata (in memory) | 2.14× (0.91×–12.48×) | zroar 32.04 ms · r64 116.25 ms (3.63×) |
| weather_sept_85 | cold, opened portable | 6.08× (1.09×–286×) | zroar 32.64 ms · portable 131.60 ms (4.03×) |
| weather_sept_85 | cold, opened frozen | 2.82× (0.91×–30.32×) | zroar 32.64 ms · frozen 118.20 ms (3.62×) |
| oltp | realdata (in memory) | 1.84× (0.86×–12.21×) | zroar 32.45 ms · r64 47.36 ms (1.46×) |
| oltp | cold, opened portable | 5.71× (1.09×–214×) | zroar 34.00 ms · portable 79.65 ms (2.34×) |
| oltp | cold, opened frozen | 3.99× (0.97×–84.42×) | zroar 34.00 ms · frozen 62.42 ms (1.84×) |

| synthetic family | typical row (vs CRoaring; portable where a format is involved) | vs frozen | total time |
|---|---|---|---|
| ContainsHit | 3.01× (1.36×–4.64×) | – | zroar 153 ns · r64 433 ns (2.83×) |
| ContainsMiss | 2.95× (1.29×–4.99×) | – | zroar 141 ns · r64 378 ns (2.68×) |
| Insert | 2.21× (0.80×–4.31×) | – | zroar 819.68 ms · r64 731.89 ms (0.89×) |
| Remove | 6.89× (1.73×–11.78×) | – | zroar 52.79 ms · r64 350.20 ms (6.63×) |
| Serialize | 23.74× (1.15×–107×) | 13.46× (1.10×–42.67×) | zroar 9.58 ms · portable 208.01 ms (21.71×) · frozen 106.38 ms (11.10×) |
| Deserialize | 15,909× (6.51×–4,313,980×) | 4,982× (2.43×–1,505,678×) | zroar 738 ns · portable 466.90 ms (632,534×) · frozen 178.49 ms (241,811×) |
| ContainsRandom | 1.31× (0.92×–1.85×) | – | zroar 1.3 µs · r64 1.8 µs (1.36×) |
| InsertRemoveRandom | 0.60× (0.33×–1.42×) | – | zroar 102.4 µs · r64 40.4 µs (0.39×) |
| **across the operation families** (Serialize/Deserialize excluded, each family weighted equally) | **2.18×** | | |
| **across all families** (each weighted equally) | **8.92×** | | |

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
| SuccessiveIntersection64 | 0.93× | 1.57× | 1.67× | 1.44× |
| SuccessiveIntersectionCardinality64 | 1.18× | 1.45× | 1.35× | 1.14× |
| SuccessiveUnionCardinality64 | 3.35× | 1.51× | 1.40× | 1.31× |
| SuccessiveDifferenceCardinality64 | 2.44× | 1.48× | 1.38× | 1.22× |
| SuccessiveUnion64 | 1.40× | 0.92× | 1.04× | 0.90× |
| RandomAccess64 | 1.52× | 2.42× | 2.11× | 1.45× |
| ToArray64 | 1.25× | 1.02× | 0.91× | 0.86× |
| IterateAll64 | 19.11× | 10.54× | 8.47× | 6.50× |
| ComputeCardinality64 | 13.41× | 12.57× | 12.48× | 12.21× |

zroar faster than CRoaring on 31 of 36 cells.

## cold — the same rows, but every bitmap is opened inside the timed call

Cells read `portable / frozen`: CRoaring's time opening its bitmaps from that format and doing the work, ÷ zroar's time doing the same from its buffer.

| benchmark | census1881 | census-income | weather_sept_85 | oltp |
|---|---|---|---|---|
| ColdSuccessiveIntersection64 | 10.52× / 2.71× | 2.22× / 1.65× | 2.31× / 1.71× | 2.45× / 1.82× |
| ColdSuccessiveIntersectionCardinality64 | 19.02× / 4.34× | 2.83× / 1.59× | 2.45× / 1.50× | 2.21× / 1.55× |
| ColdSuccessiveUnionCardinality64 | 19.48× / 5.82× | 2.91× / 1.65× | 2.50× / 1.50× | 2.36× / 1.71× |
| ColdSuccessiveDifferenceCardinality64 | 19.36× / 5.21× | 2.86× / 1.62× | 2.48× / 1.48× | 2.27× / 1.63× |
| ColdSuccessiveUnion64 | 1.78× / 1.34× | 1.23× / 0.94× | 1.33× / 1.06× | 1.09× / 0.97× |
| ColdRandomAccess64 | 60.75× / 11.88× | 50.93× / 6.23× | 118× / 11.83× | 214× / 84.42× |
| ColdToArray64 | 3.44× / 1.72× | 1.14× / 1.03× | 1.09× / 0.91× | 2.75× / 1.58× |
| ColdIterateAll64 | 17.55× / 16.73× | 10.66× / 10.55× | 8.66× / 8.48× | 7.75× / 6.80× |
| ColdComputeCardinality64 | 103× / 23.04× | 158× / 17.57× | 286× / 30.32× | 119× / 51.77× |
| MixedOLTP | 1.94× / 2.29× | 2.51× / 1.36× | 4.65× / 1.91× | 2.14× / 2.81× |

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
| ContainsHit | 1,000 | 1.36× | 1.54× | 2.81× |
| ContainsHit | 10,000 | 1.87× | 1.64× | 3.09× |
| ContainsHit | 100,000 | 2.87× | 1.93× | 3.12×–4.00× |
| ContainsHit | 1,000,000 | 4.21× | 2.20× | 3.14×–4.64× |
| ContainsMiss | 1,000 | 1.29× | 1.52× | 2.67×–3.29× |
| ContainsMiss | 10,000 | 1.75× | 1.63× | 2.93×–3.55× |
| ContainsMiss | 100,000 | 2.71× | 1.88× | 2.83×–4.25× |
| ContainsMiss | 1,000,000 | 3.91× | 2.16× | 2.85×–4.99× |
| Insert | 1,000 | 0.98× | 1.35× | 4.12× |
| Insert | 10,000 | 1.66× | 1.48× | 3.74×–4.31× |
| Insert | 100,000 | 1.76× | 1.66× | 2.14×–2.51× |
| Insert | 1,000,000 | 2.89× | 1.71× | 0.80×–2.80× |
| Remove | 1,000 | 1.73× | 1.90× | 9.35× |
| Remove | 10,000 | 10.36× | 1.98× | 10.16× |
| Remove | 100,000 | 4.90× | 2.06× | 7.39×–11.78× |
| Remove | 1,000,000 | 4.59× | 2.18× | 1.78×–11.71× |
| Serialize | 1,000 | 2.49× / 2.30× | 4.09× / 3.26× | 54.75×–107× / 37.29× |
| Serialize | 10,000 | 1.70× / 1.45× | 5.31× / 4.28× | 47.28×–95.04× / 32.57× |
| Serialize | 100,000 | 2.03× / 1.58× | 4.36× / 3.52× | 44.32×–89.35× / 30.99× |
| Serialize | 1,000,000 | 1.15× / 1.10× | 3.84× / 3.07× | 13.44×–86.13× / 9.83×–33.56× |
| Deserialize | 1,000 | 6.51× / 2.43× | 13.79× / 5.53× | 2,941×–3,906× / 1,504× |
| Deserialize | 10,000 | 48.86× / 2.43× | 131× / 47.66× | 30,167×–39,228× / 14,307× |
| Deserialize | 100,000 | 98.47× / 3.71× | 1,326× / 620× | 248,220×–389,468× / 93,586×–142,235× |
| Deserialize | 1,000,000 | 777× / 17.78× | 13,370× / 6,453× | 247,795×–4,313,980× / 93,850×–1,505,678× |

Random values under CRoaring's ten bitmasks: 2^20 random values inserted, then random operations on them. Every mask sets 20 bits; they differ in where. Mask 0 puts them all below bit 16 (16 containers, all the work inside them); masks 1, 2, 3, 5, 6 and 8 put none there (2^20 keys with one value each, all the work in the key index, keys added and removed at random); 4, 7 and 9 mix the two. Grouped that way, as ranges (`--full` prints every mask):

| benchmark | containers only (mask 0) | key index only (1, 2, 3, 5, 6, 8) | mixed (4, 7, 9) |
|---|---|---|---|
| ContainsRandom | 1.31× | 1.21×–1.85× | 0.92×–1.42× |
| InsertRemoveRandom | 1.40× | 0.33×–0.40× | 0.95×–1.42× |

zroar faster than CRoaring (portable where a format is involved) on 175 of 188 rows.
zroar faster than CRoaring frozen on 56 of 56 rows.
