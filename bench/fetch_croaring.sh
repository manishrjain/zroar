#!/usr/bin/env sh
# Fetches CRoaring for `zig build bench` and `zig build difftest`: both compile
# CRoaring from this checkout, and the bench reads its realdata sets from it.
#
# Usage: bench/fetch_croaring.sh [dir]
#
# Clones CRoaring (shallow, at tag $CROARING_REF) into `dir`, which defaults to
# $CROARING_DIR, then /tmp/CRoaring. That default is also where build.zig and
# bench.zig look, so cloning elsewhere means passing -Dcroaring=<dir> to the
# build and a dataset dir to the bench.
#
# The default tag is the CRoaring version BENCHMARKS.md was generated
# against. An existing clone is left as it is, whatever its version.
set -eu

ref="${CROARING_REF:-v5.0.0}"
dest="${1:-${CROARING_DIR:-/tmp/CRoaring}}"
realdata="$dest/benchmarks/realdata"

if [ -d "$dest/src" ] && [ -d "$realdata" ]; then
    have=$(sed -n 's/.*ROARING_VERSION "\(.*\)".*/\1/p' "$dest/include/roaring/roaring_version.h" 2>/dev/null || true)
    echo "already present: $dest (CRoaring ${have:-unknown version}); leaving it alone"
else
    echo "cloning CRoaring $ref into $dest ..."
    git clone --depth 1 --branch "$ref" https://github.com/RoaringBitmap/CRoaring "$dest"
fi

echo
echo "datasets:"
for d in "$realdata"/*/; do
    d="${d%/}"
    n=$(find "$d" -maxdepth 1 -name '*.txt' | wc -l)
    printf '  %-24s %4s files\n' "$(basename "$d")" "$n"
done

echo
if [ "$dest" = /tmp/CRoaring ]; then
    build=""
else
    build=" -Dcroaring=$dest"
fi
echo "run one with:"
echo "  zig build$build bench -- $realdata/census1881"
echo "or a generated OLTP index with no data dir:"
echo "  zig build$build bench -- --oltp | --oltp-random"
