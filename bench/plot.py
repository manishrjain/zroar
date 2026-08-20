#!/usr/bin/env python3
"""Render the bench's --out TSVs as one SVG dot-strip plot.

    bench/plot.py results/full5-*.tsv -o results/full5-plot.svg

One dot per benchmark comparison: CRoaring's time / zroar's time, on a log
axis, so >1x means zroar is faster. Every comparison is shown -- including
the losses -- which is the point: aggregates summarize, the strip shows.
A diamond marks each row's geometric mean. Stdlib only; the SVG uses
theme-neutral grays on a transparent background so it reads on light and
dark pages alike, and every dot carries a hover tooltip naming its test.

For a PNG (2x scale, transparent background), render the SVG with Chrome:

    google-chrome --headless --screenshot=plot.png --window-size=880,H \
        --default-background-color=00000000 --force-device-scale-factor=2 plot.svg
"""

import argparse
import math
from collections import OrderedDict

REALDATA_ROWS = [
    "SuccessiveIntersection64",
    "SuccessiveIntersectionCardinality64",
    "SuccessiveUnionCardinality64",
    "SuccessiveDifferenceCardinality64",
    "SuccessiveUnion64",
    "RandomAccess64",
    "ToArray64",
    "IterateAll64",
    "ComputeCardinality64",
]
COLD_ROWS = ["Cold" + r for r in REALDATA_ROWS] + ["MixedOLTP"]
SYNTH_FAMILIES = [
    "ContainsHit", "ContainsMiss", "Insert", "Remove",
    "ContainsRandom", "InsertRemoveRandom", "Serialize", "Deserialize",
]
SECTIONS = [
    ("realdata", "realdata -- bitmaps already in memory", REALDATA_ROWS),
    ("cold", "cold -- opened inside the timed call", COLD_ROWS),
    ("synthetic", "synthetic -- generated shapes", SYNTH_FAMILIES),
]

# The color says what the r64 side is: in memory (no format involved),
# opened from the portable format, or opened from the frozen format.
# ColorBrewer Set1 hues, picked apart for color-vision safety.
KIND_COLOR = {"memory": "#4daf4a", "portable": "#377eb8", "frozen": "#ff7f00"}
KIND_LABEL = {
    "memory": "vs r64 in memory",
    "portable": "vs portable",
    "frozen": "vs frozen",
}
GRAY, FAINT = "#888888", "0.25"


def kind(impl, suite, fam):
    """What the CRoaring side of this comparison is."""
    if impl == "r64_frozen":
        return "frozen"
    if suite == "cold" or fam in ("Serialize", "Deserialize"):
        return "portable"
    return "memory"


def parse(path):
    meta, rows = {}, {}
    with open(path) as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if parts[0] == "meta":
                meta[parts[1]] = parts[2]
            elif parts[0] == "row":
                _, suite, name, impl, us = parts
                rows.setdefault(name, {"suite": suite})[impl] = float(us)
    return meta, rows


def fmt_ratio(r):
    return f"{r:,.0f}x" if r >= 100 else f"{r:.2f}x"


def fmt_tick(v):
    if v >= 1_000_000:
        return f"{v / 1_000_000:g}Mx"
    if v >= 1000:
        return f"{v / 1000:g}kx"
    if v >= 1:
        return f"{v:g}x"
    return f"{v:.2f}".rstrip("0").rstrip(".") + "x"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("files", nargs="+")
    ap.add_argument("-o", "--out", default="plot.svg")
    args = ap.parse_args()

    # (suite, family) -> [(ratio, impl, tooltip)]
    data = OrderedDict()
    for path in args.files:
        meta, rows = parse(path)
        ds = meta.get("dataset", path)
        for name, r in rows.items():
            suite = r["suite"]
            fam = name.split("/")[0] if suite == "synthetic" else name
            for impl in ("r64", "r64_frozen"):
                if impl in r and "zroar" in r and r["zroar"] > 0:
                    ratio = r[impl] / r["zroar"]
                    k = kind(impl, suite, fam)
                    tip = f"{ds} {name} {KIND_LABEL[k]}: {fmt_ratio(ratio)}"
                    data.setdefault((suite, fam), []).append((ratio, k, tip))

    ratios = [r for pts in data.values() for r, _, _ in pts]
    wins = sum(1 for r in ratios if r > 1)

    # Geometry. ML leaves room for the longest row label (35 chars at ~6.3px
    # per char of 10.5px monospace) with margin.
    W, ML, MR = 880, 262, 24
    ROW, HEAD = 19, 30
    TOP, BOT = 96, 40
    plot_w = W - ML - MR

    # Piecewise log scale: log-interpolated within each segment, but the
    # segments get different widths, so the region around 1x -- where the
    # interesting warm-op differences live -- gets most of the pixels and
    # the Serialize/Deserialize tail is compressed instead of compressing
    # everything else. (lo, hi, width in relative units.)
    top = 10.0 ** math.ceil(math.log10(max(max(ratios), 1000.0)))
    rmin = min(ratios)
    lo = min(0.3, rmin * 0.93)
    segments = [
        (lo, 1.0, 1.1),
        (1.0, 2.0, 1.0),
        (2.0, 10.0, 1.0),
        (10.0, 1000.0, 1.0),
        (1000.0, top, 1.0),
    ]
    total_units = sum(w for _, _, w in segments)

    def X(r):
        r = min(max(r, segments[0][0]), segments[-1][1])
        u = 0.0
        for slo, shi, w in segments:
            if r >= shi:
                u += w
            else:
                u += w * (math.log10(r) - math.log10(slo)) / (math.log10(shi) - math.log10(slo))
                break
        return ML + u / total_units * plot_w

    # Row layout: section headers + family rows that have data.
    layout, y = [], TOP  # (row kind: "head"/"row", y, text-or-key)
    for suite, title, fams in SECTIONS:
        present = [f for f in fams if (suite, f) in data]
        if not present:
            continue
        y += HEAD
        layout.append(("head", y - 9, title))
        for f in present:
            layout.append(("row", y + ROW / 2, (suite, f)))
            y += ROW
    H = y + BOT

    s = []
    s.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'viewBox="0 0 {W} {H}" font-family="ui-monospace,SFMono-Regular,Menlo,Consolas,monospace">')
    s.append(f'<text x="8" y="24" font-size="15" fill="{GRAY}">'
             'zroar vs CRoaring roaring64 -- every benchmark comparison</text>')
    s.append(f'<text x="8" y="44" font-size="11" fill="{GRAY}">'
             f"CRoaring's time / zroar's; piecewise log scale, stretched near 1x. "
             f'Right of the 1x line = zroar faster: {wins} of {len(ratios)}.</text>')

    # Legend, on its own line so nothing collides with the titles.
    lx, ly = 8, 64
    for k in ("memory", "portable", "frozen"):
        s.append(f'<circle cx="{lx + 4}" cy="{ly}" r="4" fill="{KIND_COLOR[k]}" fill-opacity="0.7"/>')
        s.append(f'<text x="{lx + 13}" y="{ly + 4}" font-size="11" fill="{GRAY}">{KIND_LABEL[k]}</text>')
        lx += 13 + 7 * len(KIND_LABEL[k]) + 22
    s.append(f'<path d="M {lx + 4} {ly - 5} l 5 5 l -5 5 l -5 -5 z" fill="{GRAY}"/>')
    s.append(f'<text x="{lx + 14}" y="{ly + 4}" font-size="11" fill="{GRAY}">geomean of the row</text>')

    # Gridlines and ticks at decades (plus 0.5x).
    ticks = [0.5, 1, 2, 10, 100, 1000]
    d = 10000.0
    while d <= top:
        ticks.append(d)
        d *= 10
    # The worst loss gets its own labeled line, so "how slow is the slowest"
    # is read off the axis instead of guessed. Dashed: a data marker, not a
    # round-number gridline.
    if rmin < 0.45:
        ticks.insert(0, round(rmin, 2))
    for t in ticks:
        x = X(t)
        emph = t == 1
        dash = ' stroke-dasharray="3 3"' if t == ticks[0] and rmin < 0.45 else ""
        s.append(f'<line x1="{x:.1f}" y1="{TOP + 8}" x2="{x:.1f}" y2="{H - BOT + 8}" '
                 f'stroke="{GRAY}" stroke-opacity="{0.85 if emph else FAINT}" '
                 f'stroke-width="{1.4 if emph else 1}"{dash}/>')
        # The compressed tail packs its decades tightly; label every other
        # one there and let the gridlines carry the rest.
        if t < 10000 or math.log10(t) % 2 == 1:
            s.append(f'<text x="{x:.1f}" y="{H - BOT + 24}" font-size="11" fill="{GRAY}" '
                     f'text-anchor="middle">{fmt_tick(t)}</text>')

    # Rows.
    for row_kind, ry, val in layout:
        if row_kind == "head":
            s.append(f'<text x="8" y="{ry}" font-size="12" font-weight="bold" '
                     f'fill="{GRAY}">{val}</text>')
            continue
        suite, fam = val
        s.append(f'<text x="{ML - 10}" y="{ry + 4:.1f}" font-size="10.5" fill="{GRAY}" '
                 f'text-anchor="end">{fam}</text>')
        pts = data[(suite, fam)]
        for r, k, tip in pts:
            s.append(f'<circle cx="{X(r):.1f}" cy="{ry:.1f}" r="3.5" '
                     f'fill="{KIND_COLOR[k]}" fill-opacity="0.55">'
                     f'<title>{tip}</title></circle>')
        g = math.exp(sum(math.log(r) for r, _, _ in pts) / len(pts))
        gx = X(g)
        s.append(f'<path d="M {gx:.1f} {ry - 5:.1f} l 5 5 l -5 5 l -5 -5 z" '
                 f'fill="{GRAY}"><title>{fam} geomean: {fmt_ratio(g)}</title></path>')

    s.append("</svg>")
    with open(args.out, "w") as f:
        f.write("\n".join(s) + "\n")
    print(f"wrote {args.out}: {len(ratios)} comparisons, zroar faster in {wins}")


if __name__ == "__main__":
    main()
