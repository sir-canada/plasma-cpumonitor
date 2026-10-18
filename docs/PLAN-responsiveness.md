# Plan: make the bars reflect lag, not just load

Right now both bars are **averages of capacity**, and lag comes from **the worst thing anyone is waiting on**. I'd change them like this. Everything below is a proposal; I haven't touched the repo.

## CPU bar

At the moment it shows `cpu/all/usage`, the average over all 16 threads. One stuck thread barely moves it.

- **Bar height = max(average usage, CPU PSI `some avg10` ×3, busiest core %, busiest thread %).** A single pegged thread or real run-queue contention then shows up even when the average is 20%.
- **Keep the P/E split, but use the busiest core in each group,** not the group average. A saturated P-core is what you actually feel.
- **Change colour by cause:** CPU colour normally, orange when PSI is above ~10%, red above ~25% or when one thread has been at 95%+ for 2+ samples. That last case is exactly the plasmashell freeze.
- **Smooth falling values** (fast attack, slow decay) so a 1 s stall stays visible for a few seconds and doesn't vanish between polls.

## Memory bar

At the moment it shows `memory/physical/application ÷ total`. That number says how full RAM is, not whether you're paying for it.

- **Split the bar into stacked segments:** app RAM (solid), zram *compressed* size (lighter), page cache (faint, reclaimable). Read zram's real footprint from `/sys/block/zram0/mm_stat`. `memory/swap/used` reports the uncompressed size, which overstates the cost about 3×.
- **Base the warning colour on activity, not size:** turn red when memory PSI `some` > ~2% or swap-in > ~500 pages/s (`pswpin` delta in `/proc/vmstat`). Orange when MemAvailable < ~10%.
- **Add a small swap-in tick or flash on top of the bar** whenever pages are coming back from zram. That's the "ghostty window is slow to switch" moment.

## Hover popup

The popup currently shows the per-core heatmap, top apps by CPU and memory, and a RAM/zram line. I'd reorganise it into this order:

1. **Responsiveness line first:** `Stall: cpu 12% · mem 0.8% · io 0.1%`, plus a one-word verdict (Smooth / Contended / Swapping / Stalled thread).
2. **Hottest threads, not just apps:** the top 3 threads by CPU in the last interval, as `plasmashell (main) 96% on P3`. `corestats.py` already reads every thread's ticks, so this is a sort plus thread names from `/proc/PID/task/TID/comm`. It's the single most useful addition: it would have found the pcmcp bug in seconds.
3. **Who is waiting:** run-queue length (`procs_running` from `/proc/stat`) vs core count, and the number of tasks in D state.
4. **Memory, honestly:** `RAM 24.1/39 GB · cache 8 GB (reclaimable) · zram 16.9 GB → 5.2 GB real (3.3×) · available 15 GB`.
5. **Swap activity:** `swap-in 3.2k pg/s · major faults 410/s`, plus **top swapped processes** (`VmSwap` from `/proc/PID/status`), e.g. `ghostty 1.4 GB swapped`. That tells you which window will stutter when you switch to it.
6. **Top apps by CPU/RAM:** keep these, but show RSS + swap per app so a 360 MB app with 1.4 GB in swap isn't hidden.
7. **Trend:** a 60 s sparkline of the lag value, so you can see whether a hitch is ongoing or was a one-off.

## Implementation

- **`corestats.py`:** add `PSI|…`, `HOT|tid|pid|pct|cpu|name` (top 3), `VM|pswpin/s|pgmajfault/s|procs_running|blocked`, `ZRAM|orig|compr|used` and `SWAP|pid|kB|name` (top 5, reads `/proc/*/status` only every ~5th run). It already scans `/proc`, so the extra cost is small.
- **`main.qml`:** parse the new lines in `onNewData`, compute the CPU bar value and memory segments from them, and add the popup sections.
- **`main.xml` / `configGeneral.qml`:** add PSI and swap-in thresholds, a smoothing toggle, and a choice between "average" and "responsiveness" mode for the CPU bar.

If you want me to build it, I'll implement it in `~/Documents/projects/plasma-cpumonitor`, commit, reinstall with `kpackagetool6 -u .`, and restart only plasmashell, which leaves ghostty and pi alone as before.
