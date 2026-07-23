# Thin Bars

A compact KDE Plasma 6 panel widget: thin vertical bars for CPU, GPU, VRAM,
memory and swap usage, with a rich hover tooltip.

## Features

- **Thin vertical bars** (1–24 px) for any combination of:
  - CPU usage (all-core average)
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
  - Top-N processes by instantaneous CPU (sampled with `top`)
  - Memory usage bar, RAM / zram / pool breakdown line
  - Top-N processes by RSS
- Everything configurable: bar thickness/gap, update interval, per-bar colors,
  thresholds, heatmap on/off + thresholds, process list lengths, tooltip
  sections.

## Requirements

- KDE Plasma 6
- `libksysguard` / `ksystemstats` (Plasma's sensor daemon — present on any
  stock Plasma install)
- `top` and `ps` (procps) for the tooltip process lists

## Install

```sh
git clone https://github.com/sir-canada/plasma-thinbars
cd plasma-thinbars
kpackagetool6 -t Plasma/Applet -i .
```

Then add "Thin Bars" via *Add Widgets…* on your panel. To update an existing
install, replace `-i` with `-u`. Restart plasmashell after updating:

```sh
systemctl --user restart plasma-plasmashell
```

## Notes

- Tooltip CPU percentages come from `top` in per-core scale — a multithreaded
  process can legitimately show more than 100%.
- The RSS list counts processes individually (multi-process apps like browsers
  appear once per process) and excludes swapped-out pages.

## License

MIT
