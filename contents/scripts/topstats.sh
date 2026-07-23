#!/bin/sh
# Usage: topstats.sh [N_CPU_APPS] [N_MEM_APPS]
# Emits top-N CPU and top-N RSS processes in "TYPE|name|value" lines,
# plus hybrid-CPU topology (TOPO|core|0-3 / TOPO|atom|4-7) when present.
export LC_ALL=C

CPU_N="${1:-3}"
MEM_N="${2:-3}"

for t in core atom; do
    f="/sys/devices/cpu_$t/cpus"
    [ -r "$f" ] && printf "TOPO|%s|%s\n" "$t" "$(cat "$f")"
done

# Instantaneous CPU: second iteration of top (first is since-boot average).
# HOME=/ ignores any custom toprc so column layout stays default.
if [ "$CPU_N" -gt 0 ] 2>/dev/null; then
    COLUMNS=200 HOME=/ top -bn2 -d 0.8 -o %CPU 2>/dev/null | awk -v n="$CPU_N" '
        /^[[:space:]]*PID/ { h++; next }
        h == 2 && $1 ~ /^[0-9]+$/ && $9+0 > 0 {
            cmd = $12
            for (i = 13; i <= NF; i++) cmd = cmd " " $i
            printf "CPU|%s|%s\n", cmd, $9
            if (++c == n) exit
        }'
fi

if [ "$MEM_N" -gt 0 ] 2>/dev/null; then
    ps -eo rss=,comm= --sort=-rss 2>/dev/null | awk -v n="$MEM_N" '
        NR <= n {
            rss = $1
            $1 = ""
            sub(/^ +/, "")
            printf "MEM|%s|%.2f\n", $0, rss / 1048576
        }'
fi
