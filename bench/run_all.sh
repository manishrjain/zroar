#!/usr/bin/env sh
# Runs benchmark data sets and renders a report from the results.
#
# Usage: bench/run_all.sh [-d set]... [-o prefix] [-c cpu] [-- bench args]
#
#   -d set     data set to run; repeat for several: -d census1881 -d oltp
#                census1881, census-income, weather_sept_85   CRoaring realdata
#                oltp                                         generated index
#                synthetic                                    the shape grid
#              Any other CRoaring realdata directory name also works.
#              Default: all five above.
#   -o prefix  output prefix (default bench/results/run); writes
#              <prefix>-<set>.tsv and <prefix>-report.md
#   -c cpu     CPU to pin the bench to (default $BENCH_CPU, else 3)
#   -n         run at nice -20, asking sudo for a one-time renice if needed;
#              without -n the priority is still taken when it is free
#              (RLIMIT_NICE), but sudo is never prompted
#   -- ...     passed to every bench run, e.g. -- --time 200
#
# The report is rebuilt from every <prefix>-*.tsv present, so running one
# set refreshes its column and keeps the others.
#
# Avoid data sets that lean heavily on run containers, which zroar does not
# have: wikileaks-noquotes and every _srt set (run containers shrink CRoaring's
# bitmaps there by 64-90%, versus 1-6% on the three above). The report shows
# the saving per set. uscensus2000 is tiny (30 values per file) and says
# little either way.
#
# Frequency policy is left alone: the bench records the governor, boost,
# frequency range (scaling_min_freq/scaling_max_freq) and SMT state it ran
# under and the report shows them, so set the machine up first if the numbers
# are meant to be kept. The full default set takes about 25 minutes at 500 ms
# per row; the synthetic grid is most of it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$here")
realdata=${CROARING_DIR:-/tmp/CRoaring}/benchmarks/realdata

prefix=$here/results/run
cpu=${BENCH_CPU:-3}
sets=""
want_nice=0
while getopts "d:o:c:nh" opt; do
    case $opt in
        d) sets="$sets $OPTARG" ;;
        o) prefix=$OPTARG ;;
        c) cpu=$OPTARG ;;
        n) want_nice=1 ;;
        *) sed -n '2,/^set -eu/{/^set -eu/!s/^# \{0,1\}//p}' "$0"; exit 2 ;;
    esac
done
shift $((OPTIND - 1))
[ -z "$sets" ] && sets="census1881 census-income weather_sept_85 oltp synthetic"
# The prefix is relative to where the script was invoked, not to the repo
# root the build runs from below.
case $prefix in /*) ;; *) prefix=$PWD/$prefix ;; esac

cd "$root"
zig build bench-exe
if command -v taskset >/dev/null 2>&1; then
    bench="taskset -c $cpu $root/zig-out/bin/bench"
else
    echo "taskset not found; running unpinned" >&2
    bench="$root/zig-out/bin/bench"
fi

# Highest scheduling priority available, so that another runnable task
# landing on the pinned core barely gets a slice. Negative nice needs root
# or RLIMIT_NICE (ulimit -e), so probe first: the inner `nice` prints the
# niceness the outer one obtained. Without the limit, -n asks sudo to renice
# this shell instead: children inherit the niceness, so the bench runs at
# -20 while everything still executes as the invoking user — root runs
# nothing but the renice, and the output files stay ours. Priority only
# biases the scheduler; for hard exclusion, isolate the core (chrt -f,
# cset shield, isolcpus).
if [ "$(nice -n -20 nice 2>/dev/null)" = "-20" ]; then
    bench="nice -n -20 $bench"
elif [ "$want_nice" = 1 ] && [ -t 0 ] && command -v sudo >/dev/null 2>&1; then
    echo "asking sudo to renice this shell to -20" >&2
    sudo renice -n -20 -p $$ >/dev/null \
        || echo "sudo declined; continuing at normal priority" >&2
elif [ "$want_nice" = 1 ]; then
    echo "cannot set nice -20 (needs root or RLIMIT_NICE); normal priority" >&2
fi

mkdir -p "$(dirname "$prefix")"
for set in $sets; do
    case $set in
        synthetic)   $bench --suite synthetic --out "$prefix-synthetic.tsv" "$@" ;;
        oltp)        $bench --oltp --suite realdata --suite cold --out "$prefix-oltp.tsv" "$@" ;;
        *)           $bench "$realdata/$set" --suite realdata --suite cold --out "$prefix-$set.tsv" "$@" ;;
    esac
done

python3 "$here/report.py" "$prefix"-*.tsv > "$prefix-report.md"
python3 "$here/plot.py" "$prefix"-*.tsv -o "$prefix-plot.svg"
echo "wrote $prefix-report.md"
