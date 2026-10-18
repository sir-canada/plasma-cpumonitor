# SPEC: responsiveness upgrade (implements docs/PLAN-responsiveness.md)

This is the binding contract between the three edited files. Field orders, names
and defaults MUST match exactly. Repo: `~/Documents/projects/plasma-cpumonitor`
(Package id `org.local.cpumonitor`).

Files touched: `contents/scripts/corestats.py` (Agent A), `contents/ui/main.qml`
(Agent C), `contents/config/main.xml` + `contents/ui/configGeneral.qml`
(Agent B). No file may be touched by two agents. All platform facts verified on
this machine: zram0 exists, `/sys/block/zram0/mm_stat` present, PSI files
present, vmstat counters present.

Existing protocol (unchanged): `TOPO|core|<cpulist>`, `TOPO|atom|<cpulist>`,
`SAMPLE|<elapsed>|<nP>|<nE>`, `CPU|pid|pPct|ePct|name...`.
A `SAMPLE` line means the sample window is valid.

## 1. corestats.py additions (Agent A)

Emit these lines AFTER the existing lines, BEFORE the per-pid `CPU|` loop is
fine too — order among new lines doesn't matter, but all use the SAME sample
window `elapsed` (e.g. read /proc/stat, /proc/pressure, /proc/vmstat at the
START of the second sampling pass, right before/after `read_tasks`, so their
delta window equals the ticks window).

Read each file once per run; wrap in try/except OSError and emit zeros if a
file is missing. Never crash the script. Keep the current code style
(type hints, pathlib).

### 1.1 PSI line

    PSI|cpuSome|memSome|ioSome

From `/proc/pressure/{cpu,memory,io}`, first line (`some ...`). Parse
`avg10=` field → percent with 2 decimals (`%.2f`). cpu's file has only a
`some` line; memory/io have `some` + `full` — take `some`. Missing file → 0.00.

### 1.2 Hottest threads

    HOT|tid|pid|pct|cpuIdx|name

Top 3 threads by thread CPU. Compute the per-thread tick delta exactly like the
per-pid totals (current `previous_tasks` state already stores per-tid ticks and
start_time); pct = delta / (elapsed * SC_CLK_TCK) * 100, `%.1f`. This is a
share of ONE core, 0–100. `cpuIdx` = the thread's `last_cpu` (field index 36 of
stat, already parsed). `name` = thread comm read from
`/proc/<pid>/task/<tid>/comm` (15-char comm limit is fine); replace `|` and
newlines with space; fallback `?` if unreadable. Only emit when pct > 0.5.
Sort desc by pct, take 3.

### 1.3 VM line

    VM|pswpinRate|pswpoutRate|majfltRate|procsRunning|procsBlocked

Counters from `/proc/vmstat`: `pswpin`, `pswpout`, `pgmajfault`. Rates =
delta / elapsed, `%.1f` pages/s. On first run (no previous snapshot stored)
rates are 0.0. `procsRunning` / `procsBlocked` from `/proc/stat` keys
`procs_running`, `procs_blocked` (integer, 0 if missing).

### 1.4 ZRAM line

    ZRAM|origBytes|comprBytes|realBytes

From `/sys/block/zram0/mm_stat`: fields 0 (orig_data_size), 1
(compr_data_size), 2 (mem_used_total), in bytes, integers. Missing/short file
(or no zram) → `ZRAM|0|0|0`.

### 1.5 MEMINFO line

    MEMINFO|availKB|cacheKB

From `/proc/meminfo`: `MemAvailable` and
`cacheKB = Cached + SReclaimable + Buffers - Shmem` (floor at 0). kB units.

### 1.6 COREMAX lines (busiest core per group)

    COREMAX|group|cpuIdx|pct

Parse `/proc/stat` `cpuN` lines (N ≥ 0): columns after cpuN are
user nice system idle iowait irq softirq steal guest guest_nice.
busy = total − idle − iowait; total = sum of all columns.
Store per-cpu (busy_total_sum, total_sum) in the persisted state; pct =
delta_busy / delta_total * 100 clamped 0–100, `%.1f`, `cpuIdx` = N.
Emit for the busiest core within each group (needs `last_cpu`-based group
mapping? NO — group is determined by cpu index vs the parsed p_cpus / e_cpus
sets from `read_topology()`):
- `COREMAX|P|idx|pct` — busiest core whose idx ∈ p_cpus
- `COREMAX|E|idx|pct` — busiest core whose idx ∈ e_cpus
- `COREMAX|A|idx|pct` — busiest overall core (always emitted, all cpus)
Skip a group line when the group set is empty, or when delta_total is 0 for
every cpu in it (e.g. first run) — but still emit `A` when possible.
On the very first run after state reset (no previous cpu snapshot) emit
nothing for COREMAX at all.

### 1.7 Swap process lines (every ~5th run)

Persist a run counter in the state file. On runs where `counter % 5 == 0`
(first run counts as pass #1 → emit):

    SWAPPID|pid|kB        (and)    SWAPGRP|kB|name

Scan `/proc/<pid>/status` for `VmSwap: N kB`, N > 0 only.
- `SWAPPID` lines: per-pid, sorted desc by kB, capped at 80 lines.
- `SWAPGRP` lines: aggregate kB by comm (read `/proc/<pid>/comm`), sort desc,
  top 5, name = comm sanitized (`|`, newline → space); if comm unreadable the
  pid string. Aggregate BEFORE sorting; ties arbitrary.
Passes that don't emit these lines emit nothing — the QML side keeps the last
values, so the every-5th cadence must not clear anything client-side.

### 1.8 State file format (backward-tolerant load)

    { "timestamp": t,
      "tasks": {tid: [ticks, startTime]},
      "cpus":  {"busy": [per-cpu busy sums], "total": [per-cpu total sums]},
      "vm":    {"pswpin": n, "pswpout": n, "pgmajfault": n},
      "run":   n }

`load_state` must tolerate missing `cpus`/`vm`/`run` (old v1 files) and missing
cpu indices (resized/shorter lists → 0). `save_state` writes the new format.
Keep the atomic tmp+os.replace write.

## 2. Config: main.xml defaults + configGeneral.qml (Agent B)

Add to `<group name="General">` in contents/config/main.xml:

    cpuBarMode          Enum, choices [average, responsiveness], default:
                        <default>1</default>  (index 1 = responsiveness)
    smoothBars          Bool,   default true
    psiWarn             Int,    default 10      (CPU PSI % → orange)
    psiCrit             Int,    default 25      (CPU PSI % → red)
    memPsiThreshold     Int,    default 2       (memory PSI % → red)
    swapInThreshold     Int,    default 500     (pages/s swap-in → red/verdict)
    showResponsiveness  Bool,   default true    (new popup sections)

configGeneral.qml: add aliases (`cfg_` prefix, same pattern as existing) and
widgets in the FormLayout:
- New section "Responsiveness" (Kirigami.FormData.isSection Item) placed BEFORE
  the "Tooltip" section, containing:
  - ComboBox `cpuBarMode` — label "CPU bar mode:", items `Average`,
    `Responsiveness` (i18n-cased TextRole not needed; plain model strings),
    `currentIndex: cfg_cpuBarMode` style binding via the existing alias
    pattern: `property alias cfg_cpuBarMode: modeBox.currentIndex`, and
    `onActivated: cfg_cpuBarMode = currentIndex` … actually with the alias
    pattern used above (`cfg_x` aliases), only the initial binding is needed;
    follow the existing pattern exactly (alias to widget value property).
  - CheckBox `smoothBars`, text i18n("Smooth falling values")
  - SpinBox `psiWarn` 0–100, label `i18n("CPU PSI warning (%):")`
  - SpinBox `psiCrit` 0–100, label `i18n("CPU PSI critical (%):")`
  - SpinBox `memPsiThreshold` 0–20, label `i18n("Memory PSI critical (%):")`
  - SpinBox `swapInThreshold` from 0 to 5000 step 100,
    label `i18n("Swap-in alert (pages/s):")`
  - CheckBox `showResponsiveness`, text i18n("Show responsiveness details in
    tooltip")

## 3. main.qml (Agent C)

Parse the new lines in the existing `onNewData` and add behavior per section.
Reuse the existing code style (properties on root, i18n(), TipHeader/TipRow/
TipDetail components). Numbers formatted with existing helpers
(`root.gib()` for bytes→GiB).

### 3.1 New root properties (parsed from sampler)

    psiCpu, psiMem, psiIo        real % (0 default)
    hotThreads                   [] of {tid, pid, pct, cpuIdx, name}
    swapInRate, swapOutRate, majfltRate   real pages/s
    procsRunning, procsBlocked   int
    zramOrig, zramReal           bytes (0 default)
    memAvailKB, memCacheKB       kB (0 default)
    coreMaxP, coreMaxE, coreMaxA [] of {idx, pct}
    swapByPid                    object {pidString: kB}
    swapGroups                   [] of {kB, name}
    lagHistory                   [] ring buffer, max 60 entries (see 3.4)
    hotStallCount, hotStallMaxPct int/real  (stall detector, see 3.2)

Parsing is inside the existing forEach over `out.split("\n")`, by `f[0]`:
`PSI` (f[1..3]), `HOT` (collect, sort desc, keep top 3 afterwards),
`VM` (f[1..5]), `ZRAM` (f[1..3] bytes), `MEMINFO` (f[1..2]),
`COREMAX` (group f[1], idx f[2], pct f[3] → set `coreMaxP/E/A` to
`[{idx, pct}]`, i.e. replace, taking one line per group),
`SWAPPID` (accumulate map, replace at end of batch),
`SWAPGRP` (collect list, replace). Numbers via `Number(x) || 0`.

### 3.2 CPU bar value, smoothing and color

Composite target (percent 0–100), computed per sampler batch:

    uniform (non-hybrid): target = max(cpuSensor avg %, psiCpu*3,
                                        coreMaxA.pct, hottest thread pct)
    hybrid P bar: target = max(average group %, psiCpu*3, coreMaxP.pct,
                               hottest thread pct when its coreIdx ∈ pCores)
    hybrid E bar: same with E group.

Plan wording: `max(average usage, CPU PSI some×3, busiest core %, busiest
thread %)`. In `average` mode (`cfg.cpuBarMode === 0`) targets degrade to the
CURRENT behavior (ksysguard average / group totals, no PSI, no core/hot max).

Smoothing (fast attack, slow decay), toggle `cfg.smoothBars`:
keep per-bar smoothed display values (`dispUniform`, `dispP`, `dispE` as real
percent). On each valid SAMPLE with dt = `SAMPLE` elapsed:
- target ≥ current → jump: current = target
- else decay: current = target + (current − target) * Math.exp(−dt / 3.0)
  (τ = 3 s → a 1-sample 100% spike stays visibly elevated for a few seconds).
When smoothBars off: current = target.

Stall detector: in each batch compute hottest pct across `HOT` lines; if ≥ 95
increment `hotStallCount` else reset to 0; track `hotStallMaxPct` for the
display. "Stalled thread" = `hotStallCount >= 2` (2 consecutive samples ≥95% —
the plasmashell-freeze signature).

Cause-based color (responsiveness mode only; average mode keeps existing plain
`cfg.cpuColor` / `cfg.eCpuColor`):
- crit (red = Kirigami.Theme.negativeTextColor) if
  `psiCpu >= cfg.psiCrit` OR stalled-thread condition
- warn (orange = Kirigami.Theme.neutralTextColor) if
  `psiCpu >= cfg.psiWarn`
- else group/base color (`cfg.cpuColor`, `cfg.eCpuColor`).
Apply the same one color to both hybrid bars (PSI is machine-wide).

Bar bindings: uniform ThinBar `value: root.dispUniform / 100`; hybrid bars
`dispP / 100`, `dispE / 100`.

### 3.3 Memory bar: stacked segments + activity color + swap-in flash

Replace the single memory ThinBar with a `MemBar` component (same footprint /
width / radius visuals as ThinBar; content stacked from bottom):

Segments as fractions of pool = `memTotalBytes` (unchanged formula, honors
`cfg.includeSwap`):
1. app RAM      : `memApp.value / pool`            — solid `cfg.memColor`
2. zram compressed: `(cfg.includeSwap ? zramReal : 0) / pool` —
   `cfg.swapColor` at alpha ~0.7 ("lighter" than solid)
3. page cache   : `(memCacheKB * 1024) / pool`     — textColor at alpha ~0.18
   ("faint, reclaimable")

Bar value (total height) = sum of the three segments (fallback to the old
`memPct` when sampler data is missing, i.e. zramReal == 0 AND memCacheKB == 0).

Color (activity-based, overrides size-based when triggered):
- red (negativeTextColor): `psiMem >= cfg.memPsiThreshold` OR
  `swapInRate >= cfg.swapInThreshold`
- orange (neutralTextColor): `memAvailKB < 0.1 * (memTotal.value)`
- else keep the existing size-based logic (warn/crit thresholds on the bar
  value, `cfg.memColor` base).

Swap-in flash: a thin overlay strip ABOVE the rendered fill, shown for ~700 ms
by a short one-shot Timer whenever a batch has `swapInRate > 0`, with peak
opacity `min(1, swapInRate / cfg.swapInThreshold)`; the pulse uses the
negativeTextColor. Only when `cfg.showMem`.

### 3.4 Popup reorganisation (inside existing tooltip ColumnLayout)

All new sections gated by `cfg.showResponsiveness` (and the relevant
`cfg.showCpu` / `cfg.showMem`), positioned as follows — plan order:

1. **Responsiveness line FIRST** (before the existing CPU TipHeader):
   TipDetail text: `Stall: cpu %1% · mem %2% · io %3%` (psiCpu/psiMem/psiIo,
   one decimal) plus a verdict word rendered as a second small Label on the
   same row, colored: Smooth = positiveTextColor; Contended = neutralTextColor
   (when `psiCpu >= cfg.psiWarn` and nothing stronger);
   Swapping = neutralTextColor (`swapInRate >= cfg.swapInThreshold`);
   Stalled thread = negativeTextColor (`hotStallCount >= 2`). Precedence:
   Stalled > Swapping > Contended > Smooth.
2. **Hottest threads** top 3: TipRow each, name = thread comm, value =
   `%1% on %2` where %2 = `P`/`E`/`C` + cpuIdx (P if idx ∈ pCores, E if ∈
   eCores, C otherwise). Hidden when `hotThreads` empty.
3. **Who is waiting**: TipDetail `run queue %1/%2 · blocked %3` =
   procsRunning / total logical cores / procsBlocked. Total cores =
   `pCores.length + eCores.length` when hybrid, else fall back to
   `coreCount.value` (only bound when showCoreHeatmap) else 0.
4. **Memory, honestly** (replaces the old `TipDetail` memory breakdown line,
   which stays as fallback when sampler MEMINFO/ZRAM data absent):
   `RAM %1/%2 GB · cache %3 GB · zram %4 → %5 GB (%6×) · avail %7 GB`
   using memApp.value, memTotal.value, memCacheKB*1024, zramOrig, zramReal,
   ratio `zramOrig / zramReal` (1 decimal, only when zramReal > 0),
   memAvailKB*1024 — all via `gib()`. Omit the zram and avail clauses when
   their inputs are 0.
5. **Swap activity**: TipDetail `swap-in %1 pg/s · majfault %2/s`
   (rates, thousands-separated rough formatting: if ≥ 1000 show `x.xk`);
   then Repeater over `swapGroups` top 5: TipRow name = group name+"
   swapped", value `%1 GB/s`… no — value = `%1 GiB` swapped size via gib(kB*1024).
6. **Top apps**: existing P/E/overall CPU lists unchanged. Memory apps: extend
   `refreshApplicationLists()` so each memApps entry also carries the summed
   `VmSwap` of that app's pids from `swapByPid`; render value as
   `%1 (+%2 swap)` when swap > 0, else as before.
7. **Trend sparkline** at the BOTTOM of the tooltip: push the composite target
   (the responsiveness-mode uniform/P target max) into `lagHistory` (cap 60)
   on every valid SAMPLE regardless of hover; draw as a Canvas ~60×18 px with
   a polyline of the history (x spread evenly, y scaled to 100%), stroke
   color: negativeTextColor when last value ≥ cfg.psiWarn else
   Kirigami.Theme.highlightColor; `requestPaint()` on lagHistory change and
   onVisibleChanged. Section header `TipHeader title: i18n("Trend")` +
   small caption `last 60 s`.

Keep all pre-existing tooltip sections working (P/E headers, heatmap, top
lists, GPU/VRAM/swap rows). Sparkline ids banned: none.

### 3.5 Wiring notes

- `SAMPLE` line still sets `coreSampleReady`; the dt for smoothing comes from
  `f[1]` of SAMPLE (parse `sampleElapsed`).
- New properties must not break when the sampler is disabled
  (`cfg.showCpu` false → connectedSources empty) — all new UI must tolerate
  zero/missing data (guards like `> 0` / length checks).
- Do NOT rename existing properties; only additive changes.
