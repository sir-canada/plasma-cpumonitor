#!/usr/bin/env python3
"""Sample per-process CPU time split across Intel P-core and E-core CPUs.

Also emits pipeline/responsiveness lines (PSI, hottest threads, VM/zram,
memory, busiest-core, swap) as specified in docs/SPEC-responsiveness.md §1.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
import tempfile
import time


SAMPLE_SECONDS = 0.35
MAX_REUSE_SECONDS = 10.0
HOT_THREAD_LIMIT = 3
SWAP_SCAN_INTERVAL = 5
SWAP_PID_LIMIT = 80
SWAP_GROUP_LIMIT = 5
VMSTAT_COUNTERS = ("pswpin", "pswpout", "pgmajfault")


def expand_cpu_list(value: str) -> set[int]:
    cpus: set[int] = set()
    for part in value.strip().split(","):
        if not part:
            continue
        bounds = part.split("-", 1)
        try:
            start = int(bounds[0])
            end = int(bounds[1]) if len(bounds) == 2 else start
        except ValueError:
            continue
        cpus.update(range(start, end + 1))
    return cpus


def read_topology() -> tuple[str, str, set[int], set[int]]:
    def read(kind: str) -> str:
        try:
            return Path(f"/sys/devices/cpu_{kind}/cpus").read_text().strip()
        except OSError:
            return ""

    p_text = read("core")
    e_text = read("atom")
    return p_text, e_text, expand_cpu_list(p_text), expand_cpu_list(e_text)


# Firefox renames its child processes ("Isolated Web Container" for per-site
# content, "Privileged Browser Container" for the UI process, ...), which the
# 15-character comm limit then truncates.  Route those to the command line to
# recover what the process actually is.  Chromium keeps its binary name in
# comm, so it is only decoded through the --type= path below when hit anyway.
GENERIC_COMM_PREFIXES = (
    "isolated web",
    "privileged bro",
    "web content",
    "web extensions",
)

GENERIC_COMMS = {
    "socket process",
    "rdd process",
    "utility process",
    "gpu process",
}

FALLBACK_LABELS = {
    "isolated web co": "Firefox web tab",
    "isolated web container": "Firefox web tab",
    "web content": "Firefox web tab",
    "privileged bro": "Firefox browser UI",
    "privileged browser": "Firefox browser UI",
    "web extensions": "Firefox extensions",
    "socket process": "Firefox network",
    "rdd process": "Firefox media decoder",
    "utility process": "Firefox helper",
    "gpu process": "Firefox GPU",
}

# Gecko content processes end their command line with a role token.
FIREFOX_CONTENT_ROLES = {
    "tab": "Firefox web tab",
    "privileged": "Firefox browser UI",
    "gpu": "Firefox GPU process",
    "socket": "Firefox network process",
    "rdd": "Firefox media decoder",
    "utility": "Firefox helper process",
    "extension": "Firefox extensions",
    "forkserver": "Firefox process spawner",
    "crashhelper": "Firefox crash reporter",
}

CHROMIUM_APP_NAMES = {
    "chrome": "Chrome",
    "google-chrome": "Chrome",
    "google-chrome-stable": "Chrome",
    "chromium": "Chromium",
    "brave": "Brave",
    "brave-bin": "Brave",
    "brave-origin": "Brave",
    "brave-origin-bin": "Brave",
    "msedge": "Edge",
    "vivaldi-bin": "Vivaldi",
    "opera": "Opera",
    "electron": "Electron",
}

def sanitize_protocol_name(name: str) -> str:
    return name.replace("|", " ").replace("\n", " ").strip()


def read_cmdline(pid: int) -> list[str]:
    try:
        raw = Path(f"/proc/{pid}/cmdline").read_bytes()
    except OSError:
        return []
    return [part.decode("utf-8", "replace") for part in raw.split(b"\0") if part]


def decode_generic_process(pid: int, comm: str) -> str:
    argv = read_cmdline(pid)
    if argv:
        if "-contentproc" in argv:
            role = FIREFOX_CONTENT_ROLES.get(argv[-1])
            if role:
                return role
        for arg in argv:
            if not arg.startswith("--type="):
                continue
            kind = arg[7:]
            app = CHROMIUM_APP_NAMES.get(Path(argv[0]).name, Path(argv[0]).name)
            if kind == "renderer":
                return f"{app} web tab"
            if kind == "gpu-process":
                return f"{app} GPU process"
            if kind == "utility":
                sub = next(
                    (a.split("=", 1)[1] for a in argv
                     if a.startswith("--utility-sub-type=")), ""
                )
                sub = sub.split(".", 1)[0] if sub else "helper"
                return f"{app} {sub} helper"
            return f"{app} ({kind})"
    return FALLBACK_LABELS.get(comm.lower(), comm)


def read_process_name(pid: int) -> str:
    try:
        comm = Path(f"/proc/{pid}/comm").read_text().strip()
    except OSError:
        return str(pid)
    if not comm:
        comm = str(pid)
    lowered = comm.lower()
    if lowered.startswith(GENERIC_COMM_PREFIXES) or lowered in GENERIC_COMMS:
        return decode_generic_process(pid, comm).replace("|", " ").replace("\n", " ")
    return sanitize_protocol_name(comm) or str(pid)


def read_thread_name(pid: int, tid: str) -> str:
    try:
        comm = Path(f"/proc/{pid}/task/{tid}/comm").read_text().strip()
    except OSError:
        return "?"
    return sanitize_protocol_name(comm) or "?"


def read_stat_cpus() -> tuple[list[tuple[int, int, int]], int, int]:
    """Parse /proc/stat: per-cpu (idx, busy_sum, total_sum) plus runnable
    and blocked process counts."""
    cpus: list[tuple[int, int, int]] = []
    running = 0
    blocked = 0
    try:
        text = Path("/proc/stat").read_text()
    except OSError:
        return cpus, running, blocked
    for line in text.splitlines():
        fields = line.split()
        if not fields:
            continue
        key = fields[0]
        if key == "procs_running":
            running = int(fields[1]) if len(fields) > 1 and fields[1].isdigit() else 0
        elif key == "procs_blocked":
            blocked = int(fields[1]) if len(fields) > 1 and fields[1].isdigit() else 0
        elif key.startswith("cpu") and key[3:].isdigit():
            try:
                times = [int(value) for value in fields[1:9]]
            except ValueError:
                continue
            total = sum(times)
            idle = times[3] + (times[4] if len(times) > 4 else 0)
            cpus.append((int(key[3:]), total - idle, total))
    cpus.sort(key=lambda item: item[0])
    return cpus, running, blocked


def read_vmstat() -> dict[str, int]:
    counters: dict[str, int] = {}
    try:
        text = Path("/proc/vmstat").read_text()
    except OSError:
        return counters
    wanted = set(VMSTAT_COUNTERS)
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0] in wanted and fields[1].isdigit():
            counters[fields[0]] = int(fields[1])
    return counters


def read_pressure(kind: str) -> float:
    """avg10 stall percent from the 'some' line of /proc/pressure/<kind>."""
    try:
        text = Path(f"/proc/pressure/{kind}").read_text()
    except OSError:
        return 0.0
    for line in text.splitlines():
        if not line.startswith("some"):
            continue
        match = re.search(r"avg10=([0-9.]+)", line)
        if match:
            try:
                return float(match.group(1))
            except ValueError:
                return 0.0
    return 0.0


def read_meminfo() -> tuple[int, int]:
    """Return (MemAvailable, Cached + SReclaimable + Buffers - Shmem) in kB."""
    values: dict[str, int] = {}
    try:
        text = Path("/proc/meminfo").read_text()
    except OSError:
        return 0, 0
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[1].isdigit():
            values[fields[0].rstrip(":")] = int(fields[1])
    available = values.get("MemAvailable", 0)
    cache = max(
        0,
        values.get("Cached", 0)
        + values.get("SReclaimable", 0)
        + values.get("Buffers", 0)
        - values.get("Shmem", 0),
    )
    return available, cache


def read_zram() -> tuple[int, int, int]:
    """Return (orig, compr, real) byte totals from zram0 mm_stat."""
    try:
        text = Path("/sys/block/zram0/mm_stat").read_text()
    except OSError:
        return 0, 0, 0
    fields = text.split()
    if len(fields) < 3:
        return 0, 0, 0
    try:
        return int(fields[0]), int(fields[1]), int(fields[2])
    except ValueError:
        return 0, 0, 0


def read_swap_usage() -> list[tuple[int, int, str]]:
    """Scan /proc for VmSwap per pid: list of (pid, kB, comm)."""
    found: list[tuple[int, int, str]] = []
    try:
        processes = os.scandir("/proc")
    except OSError:
        return found
    swap_re = re.compile(r"VmSwap:\s+(\d+)\s+kB")
    with processes:
        for process in processes:
            if not process.name.isdigit():
                continue
            pid = int(process.name)
            try:
                status = Path(process.path, "status").read_text()
            except OSError:
                continue
            match = swap_re.search(status)
            if not match or int(match.group(1)) <= 0:
                continue
            try:
                comm = Path(process.path, "comm").read_text().strip()
            except OSError:
                comm = ""
            found.append((pid, int(match.group(1)), comm))
    return found


def read_tasks() -> dict[str, tuple[int, int, int, int]]:
    """Return tid -> (ticks, start_time, pid, last_cpu)."""
    tasks: dict[str, tuple[int, int, int, int]] = {}
    try:
        processes = os.scandir("/proc")
    except OSError:
        return tasks

    with processes:
        for process in processes:
            if not process.name.isdigit():
                continue
            pid = int(process.name)
            try:
                threads = os.scandir(f"/proc/{pid}/task")
            except OSError:
                continue
            with threads:
                for thread in threads:
                    if not thread.name.isdigit():
                        continue
                    try:
                        stat = Path(thread.path, "stat").read_text()
                        close = stat.rfind(")")
                        fields = stat[close + 2 :].split()
                        ticks = int(fields[11]) + int(fields[12])
                        start_time = int(fields[19])
                        last_cpu = int(fields[36])
                    except (OSError, ValueError, IndexError):
                        continue
                    tasks[thread.name] = (ticks, start_time, pid, last_cpu)
    return tasks


def state_path(instance: str) -> Path:
    safe_instance = re.sub(r"[^A-Za-z0-9_.-]", "_", instance)[:64] or "default"
    runtime = Path(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir())
    return runtime / f"thinbars-corestats-{os.getuid()}-{safe_instance}.json"


def load_state(path: Path) -> tuple[float, dict[str, list[int]], dict | list | None, dict | None, int]:
    """Backward-tolerant state load.

    Returns (timestamp, tasks, cpus_snapshot_or_None, vm_snapshot_or_None,
    run_counter).  cpus_snapshot is [(idx, busy, total)], vm_snapshot is a
    counter dict; both are None for old v1 state files or missing fields.
    """
    try:
        state = json.loads(path.read_text())
        timestamp = float(state["timestamp"])
        tasks = state["tasks"]
    except (OSError, ValueError, KeyError, TypeError):
        return 0.0, {}, None, None, 0

    # A corrupt file must never take the widget down: fall back to an empty
    # task map when the persisted shape is not a tid -> [ticks, start] mapping.
    if not isinstance(tasks, dict):
        tasks = {}

    cpus_current: dict | None = state.get("cpus")
    cpus_snapshot: list[tuple[int, int, int]] | None = None
    if isinstance(cpus_current, dict):
        try:
            busy = cpus_current["busy"]
            total = cpus_current["total"]
            if isinstance(busy, list) and isinstance(total, list):
                cpus_snapshot = [
                    (idx, int(busy[idx]), int(total[idx]))
                    for idx in range(min(len(busy), len(total)))
                ]
        except (KeyError, TypeError, ValueError, IndexError):
            cpus_snapshot = None

    vm_current = state.get("vm")
    vm_snapshot: dict[str, int] | None = None
    if isinstance(vm_current, dict):
        vm_snapshot = {}
        for counter in VMSTAT_COUNTERS:
            try:
                vm_snapshot[counter] = int(vm_current.get(counter, 0))
            except (TypeError, ValueError):
                pass

    try:
        run = int(state.get("run", 0))
    except (TypeError, ValueError):
        run = 0

    return timestamp, tasks, cpus_snapshot, vm_snapshot, run


def save_state(
    path: Path,
    timestamp: float,
    tasks: dict[str, tuple[int, int, int, int]],
    cpus: list[tuple[int, int, int]],
    vm: dict[str, int] | None,
    run: int,
) -> None:
    cpu_count_line = max((idx for idx, _, _ in cpus), default=-1) + 1
    busy = [0] * cpu_count_line
    total = [0] * cpu_count_line
    for idx, busy_sum, total_sum in cpus:
        if 0 <= idx < cpu_count_line:
            busy[idx] = busy_sum
            total[idx] = total_sum
    compact_tasks = {tid: [values[0], values[1]] for tid, values in tasks.items()}
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(
            {
                "timestamp": timestamp,
                "tasks": compact_tasks,
                "cpus": {"busy": busy, "total": total},
                # Persist vm only when the snapshot is complete; a partial or
                # missing /proc/vmstat must NOT be stored as zeros, or the next
                # run would treat the whole accumulated total as one delta.
                "vm": (None if vm is None else
                       {counter: vm.get(counter, 0) for counter in VMSTAT_COUNTERS}),
                "run": run,
            },
            separators=(",", ":"),
        ))
        os.replace(temporary, path)
    except OSError:
        try:
            temporary.unlink()
        except OSError:
            pass


def main() -> int:
    instance = sys.argv[1] if len(sys.argv) > 1 else "default"
    p_text, e_text, p_cpus, e_cpus = read_topology()

    if p_text:
        print(f"TOPO|core|{p_text}")
    if e_text:
        print(f"TOPO|atom|{e_text}")

    path = state_path(instance)
    previous_time, previous_tasks, previous_cpus, previous_vm, run_counter = (
        load_state(path)
    )
    current_time = time.monotonic()
    current_tasks = read_tasks()
    current_cpus, procs_running, procs_blocked = read_stat_cpus()
    current_vm = read_vmstat()
    elapsed = current_time - previous_time

    if not previous_tasks or elapsed < 0.1 or elapsed > MAX_REUSE_SECONDS:
        # Stale or absent state: take a fresh base snapshot so every delta
        # below comes from the same 0.35 s window (and treat the previous
        # cpu/vm snapshots as absent, so COREMAX/VM stay silent this run).
        previous_time = current_time
        previous_tasks = {
            tid: [values[0], values[1]] for tid, values in current_tasks.items()
        }
        previous_cpus = None
        previous_vm = None
        time.sleep(SAMPLE_SECONDS)
        current_time = time.monotonic()
        current_tasks = read_tasks()
        current_cpus, procs_running, procs_blocked = read_stat_cpus()
        current_vm = read_vmstat()
        elapsed = current_time - previous_time

    denominator = max(elapsed, 0.001) * os.sysconf("SC_CLK_TCK")

    per_pid: dict[int, list[int]] = {}
    hot_threads: list[tuple[float, str, int, str]] = []
    for tid, (ticks, started, pid, last_cpu) in current_tasks.items():
        previous = previous_tasks.get(tid)
        if not isinstance(previous, (list, tuple)) or len(previous) < 2:
            continue
        if previous[1] != started:
            continue
        delta = ticks - previous[0]
        if delta <= 0:
            continue
        totals = per_pid.setdefault(pid, [0, 0])
        if last_cpu in p_cpus:
            totals[0] += delta
        elif last_cpu in e_cpus:
            totals[1] += delta
        thread_pct = delta / denominator * 100
        if thread_pct > 0.5:
            hot_threads.append(
                (thread_pct, tid, last_cpu, read_thread_name(pid, tid))
            )
    hot_threads.sort(reverse=True)

    psi_cpu = read_pressure("cpu")
    psi_mem = read_pressure("memory")
    psi_io = read_pressure("io")
    mem_available_kb, mem_cache_kb = read_meminfo()
    zram_orig, zram_compr, zram_real = read_zram()

    def busiest(group: set[int] | None) -> tuple[int, float] | None:
        if previous_cpus is None:
            return None
        best: tuple[int, float] | None = None
        for idx, busy_sum, total_sum in current_cpus:
            if group is not None and idx not in group:
                continue
            prev_busy = prev_total = 0
            found = False
            for prev_idx, prev_busy_sum, prev_total_sum in previous_cpus:
                if prev_idx == idx:
                    prev_busy, prev_total, found = prev_busy_sum, prev_total_sum, True
                    break
            if not found:
                continue
            delta_total = total_sum - prev_total
            if delta_total <= 0:
                continue
            pct = min(100.0, max(0.0, (busy_sum - prev_busy) / delta_total * 100))
            if best is None or pct >= best[1]:
                best = (idx, pct)
        return best

    core_max: dict[str, tuple[int, float]] = {}
    for group, cpus_set in (("P", p_cpus), ("E", e_cpus), ("A", None)):
        entry = busiest(cpus_set)
        if entry is not None:
            core_max[group] = entry

    do_swap_scan = run_counter % SWAP_SCAN_INTERVAL == 0
    swap_pids: list[tuple[int, int, str]] = []
    if do_swap_scan:
        swap_pids = read_swap_usage()

    vm_snapshot = current_vm if len(current_vm) == len(VMSTAT_COUNTERS) else None
    save_state(
        path, current_time, current_tasks, current_cpus, vm_snapshot,
        run_counter + 1,
    )

    ticks_per_second = os.sysconf("SC_CLK_TCK")
    p_capacity = max(1, len(p_cpus))
    e_capacity = max(1, len(e_cpus))

    print(f"SAMPLE|{elapsed:.3f}|{len(p_cpus)}|{len(e_cpus)}")

    print(f"PSI|{psi_cpu:.2f}|{psi_mem:.2f}|{psi_io:.2f}")
    for thread_pct, tid, last_cpu, name in hot_threads[:HOT_THREAD_LIMIT]:
        thread_pid = current_tasks[tid][2]
        print(f"HOT|{tid}|{thread_pid}|{thread_pct:.1f}|{last_cpu}|{name}")

    if previous_vm is None:
        swap_in_rate = swap_out_rate = majflt_rate = 0.0
    else:
        swap_in_rate = (current_vm.get("pswpin", 0) - previous_vm.get("pswpin", 0)) / max(elapsed, 0.001)
        swap_out_rate = (current_vm.get("pswpout", 0) - previous_vm.get("pswpout", 0)) / max(elapsed, 0.001)
        majflt_rate = (current_vm.get("pgmajfault", 0) - previous_vm.get("pgmajfault", 0)) / max(elapsed, 0.001)
    print(
        f"VM|{swap_in_rate:.1f}|{swap_out_rate:.1f}|{majflt_rate:.1f}"
        f"|{procs_running}|{procs_blocked}"
    )

    print(f"ZRAM|{zram_orig}|{zram_compr}|{zram_real}")
    print(f"MEMINFO|{mem_available_kb}|{mem_cache_kb}")
    for group in ("P", "E", "A"):
        entry = core_max.get(group)
        if entry is not None:
            print(f"COREMAX|{group}|{entry[0]}|{entry[1]:.1f}")

    if do_swap_scan:
        swap_pids.sort(key=lambda item: item[1], reverse=True)
        for pid, kilobytes, _comm in swap_pids[:SWAP_PID_LIMIT]:
            print(f"SWAPPID|{pid}|{kilobytes}")
        groups: dict[str, int] = {}
        for _pid, kilobytes, comm in swap_pids:
            name = sanitize_protocol_name(comm) or str(_pid)
            groups[name] = groups.get(name, 0) + kilobytes
        ranked = sorted(groups.items(), key=lambda item: item[1], reverse=True)
        for name, kilobytes in ranked[:SWAP_GROUP_LIMIT]:
            print(f"SWAPGRP|{kilobytes}|{name}")

    for pid, (p_ticks, e_ticks) in per_pid.items():
        p_percent = p_ticks / denominator / p_capacity * 100
        e_percent = e_ticks / denominator / e_capacity * 100
        print(
            f"CPU|{pid}|{p_percent:.3f}|{e_percent:.3f}|{read_process_name(pid)}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
