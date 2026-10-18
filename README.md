# CPU Monitor

A compact KDE Plasma 6 panel widget: thin vertical bars for CPU, GPU, VRAM,
memory and swap usage, with a rich hover tooltip.

## Features

- **Thin vertical bars** (1–24 px) for any combination of:
  - CPU usage — on Intel hybrid CPUs one bar per core type (**P-cores and
    E-cores**, each normalized to its own group's capacity); a single
    all-core average bar on uniform CPUs
  - GPU usage
  - VRAM usage
  - Memory — application RAM **plus uncompressed data in zram swap**, measured
    against the whole pool (physical RAM + zram disksize), so the bar reflects
    real distance from out-of-memory on zram systems. Turns orange/red at
    configurable thresholds.
  - Swap (zram) fill
- **Hover tooltip** with:
  - Per-core heatmap tiles, colored by load, with **P-core / E-core grouping**
    on Intel hybrid CPUs (auto-detected via `/sys/devices/cpu_core|cpu_atom`,
    falls back gracefully on non-hybrid CPUs)
  - Separate top-N CPU consumers for P-cores and E-cores, grouped into the
    same recognizable applications as Plasma System Monitor
  - Memory usage bar, RAM / zram / pool breakdown line
  - Top-N applications by memory, so browser and Qt helper processes appear
    under their parent application
- Everything configurable: bar thickness/gap, update interval, per-bar colors,
  thresholds, heatmap on/off + thresholds, application/process list lengths,
  tooltip sections.

## Requirements

- KDE Plasma 6
- `libksysguard` / `ksystemstats` (Plasma's sensor daemon — present on any
  stock Plasma install)
- Python 3 for the unprivileged P-core / E-core activity sampler

## Install

```sh
git clone https://github.com/sir-canada/plasma-cpumonitor.git
cd plasma-cpumonitor
kpackagetool6 -t Plasma/Applet -i .
```

Then add "CPU Monitor" via *Add Widgets…* on your panel. To update an existing
install, replace `-i` with `-u`. Restart plasmashell after updating:

```sh
systemctl --user restart plasma-plasmashell
```

## Notes

- Tooltip CPU percentages use KSysGuard's application model. They are normalized
  to the capacity of the displayed core group and grouped the same way as
  Plasma System Monitor's Applications view.
- Per-core-type attribution samples each thread's CPU-time delta and last CPU.
  A thread that migrates between P-cores and E-cores during the short sampling
  interval is attributed to the core type where it was observed at the end.
- The memory list uses KSysGuard's grouped application totals rather than
  exposing internal helper process names.
- Process names come from `/proc/PID/comm`, but processes whose kernel name is
  generic or truncated are decoded from their full command line — e.g.
  Firefox's "Isolated Web Container" content processes become "Firefox web
  tab", and several instances of the same role are merged into one row with a
  process count. Browsers do not expose per-tab titles to the OS (that mapping
  exists only inside the browser, e.g. Firefox's `about:processes`), so
  attribution stops at the browser-internal role rather than the exact tab.

## License

MIT
