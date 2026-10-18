#!/usr/bin/env python3
"""Sample per-process CPU time split across Intel P-core and E-core CPUs."""

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
        return decode_generic_process(pid, comm).replace("|", " ")
    return comm.replace("|", " ") or str(pid)


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


def load_state(path: Path) -> tuple[float, dict[str, list[int]]]:
    try:
        state = json.loads(path.read_text())
        return float(state["timestamp"]), state["tasks"]
    except (OSError, ValueError, KeyError, TypeError):
        return 0.0, {}


def save_state(path: Path, timestamp: float, tasks: dict[str, tuple[int, int, int, int]]) -> None:
    compact_tasks = {tid: [values[0], values[1]] for tid, values in tasks.items()}
    temporary = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(json.dumps(
            {"timestamp": timestamp, "tasks": compact_tasks},
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
    previous_time, previous_tasks = load_state(path)
    current_time = time.monotonic()
    current_tasks = read_tasks()
    elapsed = current_time - previous_time

    if not previous_tasks or elapsed < 0.1 or elapsed > MAX_REUSE_SECONDS:
        previous_time = current_time
        previous_tasks = {
            tid: [values[0], values[1]] for tid, values in current_tasks.items()
        }
        time.sleep(SAMPLE_SECONDS)
        current_time = time.monotonic()
        current_tasks = read_tasks()
        elapsed = current_time - previous_time

    per_pid: dict[int, list[int]] = {}
    for tid, (ticks, started, pid, last_cpu) in current_tasks.items():
        previous = previous_tasks.get(tid)
        if not previous or previous[1] != started:
            continue
        delta = ticks - previous[0]
        if delta <= 0:
            continue
        totals = per_pid.setdefault(pid, [0, 0])
        if last_cpu in p_cpus:
            totals[0] += delta
        elif last_cpu in e_cpus:
            totals[1] += delta

    save_state(path, current_time, current_tasks)

    ticks_per_second = os.sysconf("SC_CLK_TCK")
    p_capacity = max(1, len(p_cpus))
    e_capacity = max(1, len(e_cpus))
    denominator = max(elapsed, 0.001) * ticks_per_second

    print(f"SAMPLE|{elapsed:.3f}|{len(p_cpus)}|{len(e_cpus)}")
    for pid, (p_ticks, e_ticks) in per_pid.items():
        p_percent = p_ticks / denominator / p_capacity * 100
        e_percent = e_ticks / denominator / e_capacity * 100
        print(
            f"CPU|{pid}|{p_percent:.3f}|{e_percent:.3f}|{read_process_name(pid)}"
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
