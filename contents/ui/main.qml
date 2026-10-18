import QtQuick
import QtQml
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import org.kde.ksysguard.process as Process
import org.kde.ksysguard.sensors as Sensors

PlasmoidItem {
    id: root

    preferredRepresentation: fullRepresentation

    readonly property var cfg: Plasmoid.configuration
    property bool tooltipActive: false
    property bool tooltipHovered: false
    readonly property bool tooltipEngaged: tooltipActive || tooltipHovered

    // Percent values, 0.0 - 1.0
    readonly property real cpuPct: (cpuSensor.value || 0) / 100
    readonly property real gpuPct: (gpuSensor.value || 0) / 100
    readonly property real vramPct: (vramTotal.value || 0) > 0
        ? (vramUsed.value || 0) / vramTotal.value : 0

    // Memory: application-used RAM + uncompressed data sitting in swap (zram),
    // over the total addressable pool (physical RAM + zram disksize).
    readonly property real memUsedBytes: (memApp.value || 0)
        + (cfg.includeSwap ? (swapUsed.value || 0) : 0)
    readonly property real memTotalBytes: (memTotal.value || 0)
        + (cfg.includeSwap ? (swapTotal.value || 0) : 0)
    readonly property real memPct: memTotalBytes > 0 ? memUsedBytes / memTotalBytes : 0

    readonly property real swapPct: (swapTotal.value || 0) > 0
        ? (swapUsed.value || 0) / swapTotal.value : 0

    function gib(b) {
        return (b / 1073741824).toFixed(1);
    }

    function loadColor(v, warn, crit) {
        if (v >= crit) return Kirigami.Theme.negativeTextColor;
        if (v >= warn) return Kirigami.Theme.neutralTextColor;
        return Kirigami.Theme.positiveTextColor;
    }

    function cpuItems(items, limit) {
        items.sort((a, b) => b.amount - a.amount);
        return items.slice(0, limit).map(item => ({
            name: item.name,
            value: Math.min(100, item.amount).toFixed(1) + "%"
        }));
    }

    // The sampler reports P-core and E-core use as a share of each group's own
    // capacity; combine them into a share of all logical cores.
    function totalCpuPercent(p, e) {
        const pCap = Math.max(1, root.pCores.length);
        const eCap = root.eCores.length;
        if (eCap === 0)
            return p;
        return (p * pCap + e * eCap) / (pCap + eCap);
    }

    // Group label for a thread's core index: P/E when hybrid, C otherwise.
    function coreGroupLabel(idx) {
        const i = Number(idx);
        if (root.pCores.indexOf(i) >= 0)
            return "P" + i;
        if (root.eCores.indexOf(i) >= 0)
            return "E" + i;
        return "C" + i;
    }

    // Fast attack, slow decay: jump up immediately, fall with tau seconds.
    function dispValue(cur, target, dt, tau) {
        if (!root.cfg.smoothBars)
            return target;
        if (target >= cur)
            return target;
        return target + (cur - target) * Math.exp(-(dt || 0) / tau);
    }

    // CPU bar color with responsiveness overrides; PSI pressure is
    // machine-wide, so the same override hue applies to both hybrid bars.
    function cpuBarColor(base) {
        if (root.cfg.cpuBarMode !== 1)
            return base;
        if (root.psiCpu >= root.cfg.psiCrit || root.hotStallCount >= 2)
            return Kirigami.Theme.negativeTextColor;
        if (root.psiCpu >= root.cfg.psiWarn)
            return Kirigami.Theme.neutralTextColor;
        return base;
    }

    function friendlyApplicationName(name) {
        const value = String(name);
        // Ghostty's transient terminal scopes are exposed by KSysGuard as
        // "surface", which is its internal scope name rather than an app name.
        return value === "surface" ? i18n("Ghostty terminals") : value;
    }

    // Memory bar color: activity-based overrides over the existing size-based
    // logic (warn/crit thresholds on the displayed value, cfg.memColor base).
    function memBarColor(fracPct) {
        if (root.psiMem >= root.cfg.memPsiThreshold
            || root.swapInRate >= root.cfg.swapInThreshold)
            return Kirigami.Theme.negativeTextColor;
        if (root.memAvailKB > 0
            && root.memAvailKB < 0.1 * (root.memTotal.value || 0))
            return Kirigami.Theme.neutralTextColor;
        if (fracPct >= root.cfg.critThreshold)
            return Kirigami.Theme.negativeTextColor;
        if (fracPct >= root.cfg.warnThreshold)
            return Kirigami.Theme.neutralTextColor;
        return root.cfg.memColor;
    }

    // Rough rate formatting: "x.xk" for thousands and up.
    function rateText(r) {
        const v = Number(r) || 0;
        return v >= 1000 ? (v / 1000).toFixed(1) + "k" : v.toFixed(1);
    }

    // Verdict word + precedence: Stalled > Swapping > Contended > Smooth.
    function responsivenessVerdict() {
        if (root.hotStallCount >= 2)
            return [i18n("Stalled thread"), Kirigami.Theme.negativeTextColor];
        if (root.swapInRate >= root.cfg.swapInThreshold)
            return [i18n("Swapping"), Kirigami.Theme.neutralTextColor];
        if (root.psiCpu >= root.cfg.psiWarn)
            return [i18n("Contended"), Kirigami.Theme.neutralTextColor];
        return [i18n("Smooth"), Kirigami.Theme.positiveTextColor];
    }

    // Composite CPU bar targets, fast-attack/slow-decay smoothing and the
    // lag trend push. Called once per valid SAMPLE batch; dt is the SAMPLE
    // elapsed in seconds.
    function updateTargets(dt) {
        const tau = 3.0;
        const avgUniform = cpuSensor.value || 0;
        const hotMax = root.hotThreads.length > 0 ? root.hotThreads[0].pct : 0;
        let uniformTarget = 0;
        let pTarget = 0;
        let eTarget = 0;
        if (root.cfg.cpuBarMode === 1) {
            const psiTerm = root.psiCpu * 3;
            const aMax = root.coreMaxA.length > 0 ? root.coreMaxA[0].pct : 0;
            uniformTarget = Math.min(100,
                Math.max(avgUniform, psiTerm, aMax, hotMax));
        } else {
            uniformTarget = avgUniform;
            pTarget = root.pCpuGroupPct;
            eTarget = root.eCpuGroupPct;
        }
        if (root.cfg.cpuBarMode === 1 && root.hybridTopology) {
            const psiTerm = root.psiCpu * 3;
            const pMax = root.coreMaxP.length > 0 ? root.coreMaxP[0].pct : 0;
            const eMax = root.coreMaxE.length > 0 ? root.coreMaxE[0].pct : 0;
            let hotP = 0;
            let hotE = 0;
            for (const t of root.hotThreads) {
                const i = Number(t.cpuIdx);
                if (root.pCores.indexOf(i) >= 0) {
                    hotP = Math.max(hotP, t.pct);
                } else if (root.eCores.indexOf(i) >= 0) {
                    hotE = Math.max(hotE, t.pct);
                }
            }
            pTarget = Math.min(100,
                Math.max(root.pCpuGroupPct, psiTerm, pMax, hotP));
            eTarget = Math.min(100,
                Math.max(root.eCpuGroupPct, psiTerm, eMax, hotE));
        }
        root.dispUniform = root.dispValue(root.dispUniform, uniformTarget, dt, tau);
        root.dispP = root.dispValue(root.dispP, pTarget, dt, tau);
        root.dispE = root.dispValue(root.dispE, eTarget, dt, tau);

        // Trend ring buffer: the uniform / P composite target, max 60 entries,
        // pushed on every valid SAMPLE regardless of hover.
        root.lagHistory = root.lagHistory.concat([Math.max(uniformTarget, pTarget)]);
        while (root.lagHistory.length > 60)
            root.lagHistory.shift();
        root.lagRevision++;
    }

    function refreshApplicationLists() {
        if (!applicationModel.available) {
            root.cpuApps = [];
            root.pCpuApps = [];
            root.eCpuApps = [];
            root.memApps = [];
            return;
        }

        const overall = [];
        const pApps = [];
        const eApps = [];
        const memory = [];
        const services = [];
        const groupedPids = {};
        const nameColumn = applicationModel.enabledAttributes.indexOf("appName");
        const usageColumn = applicationModel.enabledAttributes.indexOf("usage");
        const memoryColumn = applicationModel.enabledAttributes.indexOf("memory");
        const menuIdColumn = applicationModel.enabledAttributes.indexOf("menuId");

        for (let row = 0; row < applicationModel.rowCount(); row++) {
            const nameIndex = applicationModel.index(row, nameColumn);
            const usageIndex = applicationModel.index(row, usageColumn);
            const memoryIndex = applicationModel.index(row, memoryColumn);
            const name = applicationModel.data(
                nameIndex, Process.ProcessDataModel.Value) || i18n("Unknown");
            const displayName = root.friendlyApplicationName(name);
            const menuId = menuIdColumn >= 0 ? String(applicationModel.data(
                applicationModel.index(row, menuIdColumn),
                Process.ProcessDataModel.Value) || "") : "";
            const usage = Number(applicationModel.data(
                usageIndex, Process.ProcessDataModel.Value)) || 0;
            const maximum = Number(applicationModel.data(
                usageIndex, Process.ProcessDataModel.Maximum)) || 0;
            const memoryKiB = Number(applicationModel.data(
                memoryIndex, Process.ProcessDataModel.Value)) || 0;
            const pids = applicationModel.data(
                applicationModel.index(row, 0), Process.ProcessDataModel.PIDs) || [];
            let pPercent = 0;
            let ePercent = 0;
            // Sum this application's per-pid VmSwap from the sampler.
            let swapKiB = 0;

            for (const pid of pids) {
                const key = String(pid);
                groupedPids[key] = true;
                const coreUsage = root.coreCpuByPid[key];
                if (coreUsage) {
                    pPercent += coreUsage.p;
                    ePercent += coreUsage.e;
                }
                swapKiB += Number(root.swapByPid[key]) || 0;
            }

            if (menuId === "services") {
                // The shared "Background Services" application lumps unrelated
                // daemons together, which hides what actually uses CPU. List
                // its processes individually by their sampled names and keep
                // only those above the whole-machine CPU threshold.
                if (memoryKiB > 0)
                    memory.push({ name: displayName, amount: memoryKiB, swap: swapKiB });

                const grouped = {};
                for (const pid of pids) {
                    const coreUsage = root.coreCpuByPid[String(pid)];
                    if (!coreUsage)
                        continue;
                    const svcName = root.friendlyApplicationName(coreUsage.name);
                    if (!grouped[svcName])
                        grouped[svcName] = { p: 0, e: 0, count: 0 };
                    grouped[svcName].p += coreUsage.p;
                    grouped[svcName].e += coreUsage.e;
                    grouped[svcName].count++;
                }
                for (const svcName in grouped) {
                    const groupedSvc = grouped[svcName];
                    const total = root.totalCpuPercent(groupedSvc.p, groupedSvc.e);
                    if (total <= root.servicesCpuThreshold)
                        continue;
                    services.push({
                        name: groupedSvc.count > 1
                            ? i18n("%1 (%2 procs)", svcName, groupedSvc.count) : svcName,
                        p: groupedSvc.p,
                        e: groupedSvc.e,
                        total: total
                    });
                }
                continue;
            }

            if (usage > 0 && maximum > 0)
                overall.push({
                    name: displayName,
                    amount: Math.floor(usage) / maximum * 100
                });
            if (pPercent > 0)
                pApps.push({ name: displayName, amount: pPercent });
            if (ePercent > 0)
                eApps.push({ name: displayName, amount: ePercent });
            if (memoryKiB > 0)
                memory.push({ name: displayName, amount: memoryKiB, swap: swapKiB });
        }

        for (const svc of services) {
            if (svc.p > 0)
                pApps.push({ name: svc.name, amount: svc.p });
            if (svc.e > 0)
                eApps.push({ name: svc.name, amount: svc.e });
            overall.push({ name: svc.name, amount: svc.total });
        }

        // Include system processes that Plasma's application model does not
        // associate with a desktop application or Background Services.
        const ungrouped = {};
        const ungroupedCounts = {};
        for (const pid in root.coreCpuByPid) {
            if (groupedPids[pid])
                continue;
            const usage = root.coreCpuByPid[pid];
            const name = usage.name || pid;
            if (!ungrouped[name])
                ungrouped[name] = { p: 0, e: 0 };
            ungrouped[name].p += usage.p;
            ungrouped[name].e += usage.e;
            ungroupedCounts[name] = (ungroupedCounts[name] || 0) + 1;
        }
        for (const name in ungrouped) {
            const label = ungroupedCounts[name] > 1
                ? i18n("%1 (%2 procs)", name, ungroupedCounts[name]) : name;
            if (ungrouped[name].p > 0)
                pApps.push({ name: label, amount: ungrouped[name].p });
            if (ungrouped[name].e > 0)
                eApps.push({ name: label, amount: ungrouped[name].e });
        }

        root.cpuApps = root.cpuItems(overall, root.cfg.topAppsCpu);
        root.pCpuApps = root.cpuItems(pApps, root.cfg.topAppsCpu);
        root.eCpuApps = root.cpuItems(eApps, root.cfg.topAppsCpu);

        memory.sort((a, b) => b.amount - a.amount);
        root.memApps = memory.slice(0, root.cfg.topAppsMem).map(item => {
            const base = (item.amount / 1048576).toFixed(2) + " GiB";
            return {
                name: item.name,
                value: item.swap > 0
                    ? i18n("%1 (+%2 swap)", base, root.gib(item.swap * 1024))
                    : base
            };
        });
    }

    Sensors.Sensor { id: cpuSensor; sensorId: "cpu/all/usage"; enabled: root.cfg.showCpu; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: gpuSensor; sensorId: "gpu/all/usage"; enabled: root.cfg.showGpu; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: vramUsed; sensorId: "gpu/all/usedVram"; enabled: root.cfg.showVram; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: vramTotal; sensorId: "gpu/all/totalVram"; enabled: root.cfg.showVram; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: memApp; sensorId: "memory/physical/application"; enabled: root.cfg.showMem; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: memTotal; sensorId: "memory/physical/total"; enabled: root.cfg.showMem; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: swapUsed; sensorId: "memory/swap/used"; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: swapTotal; sensorId: "memory/swap/total"; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor {
        id: coreCount
        sensorId: "cpu/all/coreCount"
        enabled: root.cfg.showCpu && root.cfg.showCoreHeatmap
        updateRateLimit: 60000
    }

    // --- Tooltip data: per-core usage + grouped applications ---
    property var coreVals: []
    property var cpuApps: []
    property var pCpuApps: []
    property var eCpuApps: []
    property var memApps: []
    property var coreCpuByPid: ({})
    property bool coreSampleReady: false
    // The merged "Background Services" row is broken into individual services;
    // only ones using more than this share of all logical cores are listed.
    readonly property real servicesCpuThreshold: 0.5
    // Per-type group totals (0-100, normalized to that group's capacity),
    // sampled by corestats.py. Used by the tooltip headers and, on hybrid
    // CPUs, by the P/E panel bars.
    property real pCpuGroupPct: 0
    property real eCpuGroupPct: 0
    property var pCores: []   // thread indices of P-cores (Intel hybrid)
    property var eCores: []   // thread indices of E-cores
    readonly property bool hybridTopology: pCores.length > 0 && eCores.length > 0

    // --- Responsiveness sampler additions (PSI / hot threads / VM / zram) ---
    property real psiCpu: 0            // CPU "some" pressure, percent
    property real psiMem: 0            // memory "some" pressure, percent
    property real psiIo: 0             // I/O "some" pressure, percent
    property var hotThreads: []        // [{tid, pid, pct, cpuIdx, name}]
    property real swapInRate: 0        // pages/s, from /proc/vmstat deltas
    property real swapOutRate: 0
    property real majfltRate: 0
    property int procsRunning: 0
    property int procsBlocked: 0
    property real zramOrig: 0          // uncompressed bytes stored in zram
    property real zramReal: 0          // bytes of RAM used to store them
    property real memAvailKB: 0        // MemAvailable (kB)
    property real memCacheKB: 0        // page cache (kB)
    property var coreMaxP: []          // [{idx, pct}] busiest core per group
    property var coreMaxE: []
    property var coreMaxA: []
    property var swapByPid: ({})       // pid string -> VmSwap KiB
    property var swapGroups: []        // [{kB, name}] aggregated, top 5
    property var lagHistory: []        // composite CPU target ring buffer
    property int lagRevision: 0        // bumped per push so the Canvas repaints
    property int hotStallCount: 0      // consecutive samples with a >=95% thread
    property real hotStallMaxPct: 0

    // Smoothed bar display values: fast attack, slow decay (tau = 3 s).
    property real dispUniform: 0
    property real dispP: 0
    property real dispE: 0
    property real swapFlashOpacity: 0

    readonly property int logicalCores: root.hybridTopology
        ? root.pCores.length + root.eCores.length
        : ((root.cfg.showCoreHeatmap && (coreCount.value || 0) > 0)
            ? coreCount.value : 0)

    // Memory bar segments as fractions of the addressable pool (honors
    // cfg.includeSwap). Falls back to the old memPct when the sampler
    // MEMINFO/ZRAM data is absent (both inputs zero).
    readonly property real memSegApp: memTotalBytes > 0
        ? (memApp.value || 0) / memTotalBytes : 0
    readonly property real memSegZram: memTotalBytes > 0 && cfg.includeSwap
        ? zramReal / memTotalBytes : 0
    readonly property real memSegCache: memTotalBytes > 0
        ? (memCacheKB * 1024) / memTotalBytes : 0
    readonly property bool memHasSamplerData: zramReal > 0 || memCacheKB > 0
    readonly property real memBarValue: memHasSamplerData
        ? Math.min(1, memSegApp + memSegZram + memSegCache) : memPct

    // [{label, cores}] — split into P/E groups on hybrid CPUs, single group otherwise
    readonly property var coreSegments: {
        if (pCores.length > 0 && eCores.length > 0)
            return [{ label: "P", cores: pCores }, { label: "E", cores: eCores }];
        return [{ label: "", cores: coreVals.map((_, i) => i) }];
    }

    function expandCpuList(s) {
        const out = [];
        s.trim().split(",").forEach(part => {
            const m = part.split("-");
            if (m.length === 2) {
                for (let i = parseInt(m[0]); i <= parseInt(m[1]); i++)
                    out.push(i);
            } else if (part !== "") {
                out.push(parseInt(part));
            }
        });
        return out;
    }

    Instantiator {
        id: coreSensors
        model: root.cfg.showCpu && root.cfg.showCoreHeatmap
            ? (coreCount.value || 0) : 0
        delegate: Sensors.Sensor {
            sensorId: "cpu/cpu" + index + "/usage"
            updateRateLimit: root.tooltipEngaged ? root.cfg.updateInterval : 5000
        }
    }

    Timer {
        interval: root.tooltipEngaged ? root.cfg.updateInterval : 5000
        running: root.cfg.showCpu && root.cfg.showCoreHeatmap
        repeat: true
        onTriggered: {
            const vals = [];
            for (let i = 0; i < coreSensors.count; i++) {
                const s = coreSensors.objectAt(i);
                vals.push(Math.round((s && s.value) ? s.value : 0));
            }
            root.coreVals = vals;
        }
    }

    // Match Plasma System Monitor's Applications view: group processes by their
    // systemd application cgroup and normalize CPU use across all logical CPUs.
    Process.ApplicationDataModel {
        id: applicationModel

        enabled: root.tooltipEngaged
            && ((root.cfg.showCpu && root.cfg.topAppsCpu > 0)
                || (root.cfg.showMem && root.cfg.topAppsMem > 0))
        enabledAttributes: ["appName", "usage", "memory", "menuId"]

        cgroupMapping: {
            "session.slice": "services",
            "background.slice": "services",
            "org.a11y.atspi.Registry": "services",
            "org.kde.discover.notifier": "services",
            "geoclue": "services",
            "org.kde.kunifiedpush": "services",
            "dconf.service": "services",
            "flatpak-session-helper.service": "services",
            "gpg-agent.service": "services",
            "org.kde.xwaylandvideobridge": "services",
            "org.kde.kalendarac": "services",
            "xdg-desktop-portal-gtk.service": "services",
            "org.kde.kdeconnect": "services",
            "org.kde.kwalletd6": "services",
            "org.kde.kclockd": "services"
        }

        applicationOverrides: {
            "services": {
                "menuId": "services",
                "appName": i18nc("@label", "Background Services"),
                "iconName": "preferences-system-services"
            }
        }
    }

    Timer {
        interval: 2000
        running: applicationModel.enabled
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshApplicationLists()
    }

    // One-shot pulse for the memory bar's swap-in flash strip.
    Timer {
        id: flashTimer
        interval: 700
        onTriggered: root.swapFlashOpacity = 0
    }

    P5Support.DataSource {
        id: coreStats
        engine: "executable"
        readonly property string scriptPath:
            Qt.resolvedUrl("../scripts/corestats.py").toString().replace("file://", "")
        readonly property string command: "python3 '" + scriptPath + "' "
            + Plasmoid.id
        // The sampler also feeds the P/E panel bars on hybrid CPUs, so it
        // runs whenever the CPU bar is shown, not only with the tooltip up.
        connectedSources: root.cfg.showCpu ? [command] : []
        interval: Math.max(1000, root.cfg.updateInterval)
        onNewData: (source, data) => {
            const out = data.stdout || "";
            const usage = {};
            let totalP = 0;
            let totalE = 0;
            let sampleReady = false;
            let sampleElapsed = 0;
            let hotLines = [];
            let hotMax = 0;
            let swapPidMap = {};
            let sawSwapPid = false;
            let sawSwapGrp = false;
            let swapGrpLines = [];
            out.split("\n").forEach(l => {
                const f = l.split("|");
                if (f[0] === "CPU") {
                    const p = Number(f[2]) || 0;
                    const e = Number(f[3]) || 0;
                    usage[f[1]] = {
                        p: p,
                        e: e,
                        name: f.slice(4).join("|")
                    };
                    totalP += p;
                    totalE += e;
                } else if (f[0] === "SAMPLE") {
                    sampleReady = true;
                    sampleElapsed = Number(f[1]) || 0;
                } else if (f[0] === "TOPO" && f[1] === "core") {
                    root.pCores = root.expandCpuList(f[2]);
                } else if (f[0] === "TOPO" && f[1] === "atom") {
                    root.eCores = root.expandCpuList(f[2]);
                } else if (f[0] === "PSI") {
                    root.psiCpu = Number(f[1]) || 0;
                    root.psiMem = Number(f[2]) || 0;
                    root.psiIo = Number(f[3]) || 0;
                } else if (f[0] === "HOT") {
                    const pct = Number(f[3]) || 0;
                    hotMax = Math.max(hotMax, pct);
                    hotLines.push({
                        tid: f[1] || "",
                        pid: f[2] || "0",
                        pct: pct,
                        cpuIdx: Number(f[4]) || 0,
                        name: f.slice(5).join("|") || "?"
                    });
                } else if (f[0] === "VM") {
                    root.swapInRate = Number(f[1]) || 0;
                    root.swapOutRate = Number(f[2]) || 0;
                    root.majfltRate = Number(f[3]) || 0;
                    root.procsRunning = Number(f[4]) || 0;
                    root.procsBlocked = Number(f[5]) || 0;
                } else if (f[0] === "ZRAM") {
                    root.zramOrig = Number(f[1]) || 0;
                    // ZRAM|orig|compr|real — the compressed footprint we cost
                    // is the THIRD field; compr alone understates it.
                    root.zramReal = Number(f[3]) || 0;
                } else if (f[0] === "MEMINFO") {
                    root.memAvailKB = Number(f[1]) || 0;
                    root.memCacheKB = Number(f[2]) || 0;
                } else if (f[0] === "COREMAX") {
                    const entry = [{ idx: Number(f[2]) || 0, pct: Number(f[3]) || 0 }];
                    if (f[1] === "P") {
                        root.coreMaxP = entry;
                    } else if (f[1] === "E") {
                        root.coreMaxE = entry;
                    } else if (f[1] === "A") {
                        root.coreMaxA = entry;
                    }
                } else if (f[0] === "SWAPPID") {
                    sawSwapPid = true;
                    swapPidMap[String(f[1])] = Number(f[2]) || 0;
                } else if (f[0] === "SWAPGRP") {
                    sawSwapGrp = true;
                    swapGrpLines.push({
                        kB: Number(f[1]) || 0,
                        name: f.slice(2).join("|") || "?"
                    });
                }
            });
            root.coreCpuByPid = usage;

            // Commit sampler-batch results. Swap data is refreshed only on
            // the sampler's every-5th pass, so keep previous values otherwise.
            hotLines.sort((a, b) => b.pct - a.pct);
            root.hotThreads = hotLines;
            root.hotStallMaxPct = hotMax;
            root.hotStallCount = hotMax >= 95 ? root.hotStallCount + 1 : 0;
            root.swapByPid = sawSwapPid ? swapPidMap : root.swapByPid;
            root.swapGroups = sawSwapGrp ? swapGrpLines : root.swapGroups;
            if (root.swapInRate > 0 && root.cfg.swapInThreshold > 0) {
                root.swapFlashOpacity =
                    Math.min(1, root.swapInRate / root.cfg.swapInThreshold);
                flashTimer.restart();
            }
            if (sampleReady) {
                root.coreSampleReady = true;
                root.pCpuGroupPct = Math.min(100, totalP);
                root.eCpuGroupPct = Math.min(100, totalE);
                root.updateTargets(sampleElapsed);
            }
            root.refreshApplicationLists();
        }
    }

    component ThinBar: Item {
        id: bar
        property real value: 0
        property color barColor: Kirigami.Theme.highlightColor
        width: Math.max(1, root.cfg.barWidth)

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Kirigami.Theme.textColor
            opacity: 0.25
        }
        Rectangle {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: Math.max(width, parent.height * Math.min(1, bar.value))
            radius: width / 2
            color: bar.barColor
            Behavior on height {
                NumberAnimation { duration: 300; easing.type: Easing.OutQuad }
            }
        }
    }

    // Stacked memory bar: app RAM (solid), zram compressed (lighter) and
    // reclaimable page cache (faint) piled from the bottom of the pool.
    // A short strip flashes above the fill while pages are swapping in.
    component MemBar: Item {
        id: memBar
        property real appFraction: 0
        property real zramFraction: 0
        property real cacheFraction: 0
        property real fillFraction: 0
        property color barColor: root.cfg.memColor
        property real flash: 0
        width: Math.max(1, root.cfg.barWidth)

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Kirigami.Theme.textColor
            opacity: 0.25
        }
        // Track background + stacked segments, anchored to the bottom.
        Item {
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: Math.max(memBar.width,
                parent.height * Math.min(1, Math.max(0, memBar.fillFraction)))

            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: memBar.barColor
            }
            // Page cache sits on top of app RAM, above zram's compressed block.
            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                height: parent.height * memBar.zramFraction
                radius: width / 2
                color: Qt.alpha(root.cfg.swapColor, 0.7)
            }
            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                height: parent.height
                radius: width / 2
                color: Qt.alpha(Kirigami.Theme.textColor, 0.18)
            }
            Rectangle {
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                }
                height: parent.height * memBar.appFraction
                radius: width / 2
                color: memBar.barColor
            }
        }
        // Swap-in flash above the fill.
        Rectangle {
            visible: memBar.flash > 0
            anchors {
                left: parent.left
                right: parent.right
                bottom: parent.bottom
            }
            height: Math.max(memBar.width,
                parent.height * Math.min(1, Math.max(0, memBar.fillFraction)))
            radius: width / 2
            color: Kirigami.Theme.negativeTextColor
            opacity: memBar.flash * 0.85
        }

        Behavior on fillFraction {
            NumberAnimation { duration: 300; easing.type: Easing.OutQuad }
        }
    }

    // Section header: dim small-caps title left, bold value right
    component TipHeader: RowLayout {
        property alias title: titleLabel.text
        property alias value: valueLabel.text
        Layout.fillWidth: true
        PC3.Label {
            id: titleLabel
            opacity: 0.6
            font.capitalization: Font.AllUppercase
            font.letterSpacing: 1
            font.pointSize: Kirigami.Theme.smallFont.pointSize
        }
        Item { Layout.fillWidth: true }
        PC3.Label {
            id: valueLabel
            font.bold: true
        }
    }

    // Detail row: name left, value right
    component TipRow: RowLayout {
        property alias name: nameLabel.text
        property alias value: valueLabel.text
        Layout.fillWidth: true
        PC3.Label {
            id: nameLabel
            opacity: 0.85
            elide: Text.ElideRight
            Layout.fillWidth: true
            Layout.maximumWidth: Kirigami.Units.gridUnit * 11
        }
        PC3.Label {
            id: valueLabel
            horizontalAlignment: Text.AlignRight
        }
    }

    // Dim single-line detail in small font
    component TipDetail: PC3.Label {
        opacity: 0.6
        font.pointSize: Kirigami.Theme.smallFont.pointSize
    }

    component TipSeparator: Kirigami.Separator {
        Layout.fillWidth: true
        Layout.topMargin: Kirigami.Units.smallSpacing
        Layout.bottomMargin: Kirigami.Units.smallSpacing
        opacity: 0.4
    }

    component TipUsageBar: Rectangle {
        id: usageBar
        property real value: 0
        property color fillColor: Kirigami.Theme.highlightColor

        Layout.fillWidth: true
        height: 4
        radius: 2
        color: Qt.alpha(Kirigami.Theme.textColor, 0.15)

        Rectangle {
            width: parent.width * Math.min(1, Math.max(0, usageBar.value))
            height: parent.height
            radius: parent.radius
            color: usageBar.fillColor
            Behavior on width {
                NumberAnimation { duration: 300; easing.type: Easing.OutQuad }
            }
        }
    }

    fullRepresentation: Item {
        Layout.minimumWidth: row.implicitWidth + 2
        Layout.preferredWidth: Layout.minimumWidth
        Layout.minimumHeight: Kirigami.Units.gridUnit
        Layout.fillHeight: true

        PlasmaCore.ToolTipArea {
            id: toolTipArea
            anchors.fill: parent

            onContainsMouseChanged: {
                root.tooltipHovered = containsMouse;
                if (containsMouse)
                    showToolTip();
            }
            onToolTipVisibleChanged: (toolTipVisible) =>
                root.tooltipActive = toolTipVisible
            Component.onDestruction: {
                root.tooltipActive = false;
                root.tooltipHovered = false;
            }

            mainItem: Item {
                implicitWidth: Math.max(tipLayout.implicitWidth, Kirigami.Units.gridUnit * 13)
                    + Kirigami.Units.largeSpacing * 2
                implicitHeight: tipLayout.implicitHeight + Kirigami.Units.largeSpacing * 2
                width: implicitWidth
                height: implicitHeight

                ColumnLayout {
                    id: tipLayout
                    anchors.fill: parent
                    anchors.margins: Kirigami.Units.largeSpacing
                    spacing: Kirigami.Units.smallSpacing

                    // ---- Responsiveness (first, per plan) ----
                    RowLayout {
                        visible: root.cfg.showResponsiveness
                            && (root.cfg.showCpu || root.cfg.showMem)
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.smallSpacing
                        TipDetail {
                            text: i18n("Stall: cpu %1% · mem %2% · io %3%",
                                root.psiCpu.toFixed(1), root.psiMem.toFixed(1),
                                root.psiIo.toFixed(1))
                        }
                        Item { Layout.fillWidth: true }
                        PC3.Label {
                            readonly property var verdict:
                                root.responsivenessVerdict()
                            text: verdict[0]
                            color: verdict[1]
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            font.bold: true
                        }
                    }

                    // Hottest threads, so a single stuck thread is visible.
                    Repeater {
                        model: root.cfg.showResponsiveness && root.cfg.showCpu
                            ? root.hotThreads : []
                        TipRow {
                            required property var modelData
                            name: modelData.name
                            value: i18n("%1% on %2",
                                Number(modelData.pct).toFixed(1),
                                root.coreGroupLabel(modelData.cpuIdx))
                        }
                    }

                    TipDetail {
                        visible: root.cfg.showResponsiveness && root.logicalCores > 0
                        text: i18n("run queue %1/%2 · blocked %3",
                            root.procsRunning, root.logicalCores, root.procsBlocked)
                    }

                    // ---- CPU ----
                    TipHeader {
                        visible: root.cfg.showCpu
                        title: i18n("CPU")
                        value: Math.round(root.cpuPct * 100) + "%"
                    }

                    // Core heatmap: one tinted tile per thread, grouped P/E on hybrid
                    RowLayout {
                        visible: root.cfg.showCpu && root.cfg.showCoreHeatmap
                            && root.coreVals.length > 0
                        spacing: Kirigami.Units.smallSpacing
                        Repeater {
                            model: root.coreSegments
                            RowLayout {
                                required property var modelData
                                spacing: 2
                                PC3.Label {
                                    visible: modelData.label !== ""
                                    text: modelData.label
                                    opacity: 0.5
                                    font.pointSize: Kirigami.Theme.smallFont.pointSize
                                }
                                Repeater {
                                    model: modelData.cores
                                    Rectangle {
                                        required property int modelData
                                        readonly property int load:
                                            root.coreVals[modelData] !== undefined
                                                ? root.coreVals[modelData] : 0
                                        width: Kirigami.Units.gridUnit * 1.5
                                        height: Kirigami.Units.gridUnit
                                        radius: 4
                                        color: Qt.alpha(root.loadColor(load,
                                            root.cfg.heatWarnThreshold,
                                            root.cfg.heatCritThreshold), 0.22)
                                        PC3.Label {
                                            anchors.centerIn: parent
                                            text: parent.load
                                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                                        }
                                    }
                                }
                            }
                        }
                    }

                    TipSeparator {
                        visible: root.cfg.showCpu && root.cfg.topAppsCpu > 0
                            && root.hybridTopology
                    }
                    TipHeader {
                        visible: root.cfg.showCpu && root.cfg.topAppsCpu > 0
                            && root.hybridTopology
                        title: i18n("P-cores")
                        value: Math.round(root.pCpuGroupPct) + "%"
                    }
                    TipUsageBar {
                        visible: root.cfg.showCpu && root.cfg.topAppsCpu > 0
                            && root.hybridTopology
                        value: root.pCpuGroupPct / 100
                        fillColor: root.loadColor(root.pCpuGroupPct,
                            root.cfg.heatWarnThreshold,
                            root.cfg.heatCritThreshold)
                    }
                    Repeater {
                        model: root.cfg.showCpu && root.hybridTopology
                            ? root.pCpuApps : []
                        TipRow {
                            required property var modelData
                            name: modelData.name
                            value: modelData.value
                        }
                    }
                    TipDetail {
                        visible: root.cfg.showCpu && root.cfg.topAppsCpu > 0
                            && root.hybridTopology && root.coreSampleReady
                            && root.pCpuApps.length === 0
                        text: i18n("No sampled P-core activity")
                    }

                    TipSeparator {
                        visible: root.cfg.showCpu && root.cfg.topAppsCpu > 0
                            && root.hybridTopology
                    }
                    TipHeader {
                        visible: root.cfg.showCpu && root.cfg.topAppsCpu > 0
                            && root.hybridTopology
                        title: i18n("E-cores")
                        value: Math.round(root.eCpuGroupPct) + "%"
                    }
                    TipUsageBar {
                        visible: root.cfg.showCpu && root.cfg.topAppsCpu > 0
                            && root.hybridTopology
                        value: root.eCpuGroupPct / 100
                        fillColor: root.loadColor(root.eCpuGroupPct,
                            root.cfg.heatWarnThreshold,
                            root.cfg.heatCritThreshold)
                    }
                    Repeater {
                        model: root.cfg.showCpu && root.hybridTopology
                            ? root.eCpuApps : []
                        TipRow {
                            required property var modelData
                            name: modelData.name
                            value: modelData.value
                        }
                    }
                    TipDetail {
                        visible: root.cfg.showCpu && root.cfg.topAppsCpu > 0
                            && root.hybridTopology && root.coreSampleReady
                            && root.eCpuApps.length === 0
                        text: i18n("No sampled E-core activity")
                    }

                    Repeater {
                        model: root.cfg.showCpu && !root.hybridTopology
                            ? root.cpuApps : []
                        TipRow {
                            required property var modelData
                            name: modelData.name
                            value: modelData.value
                        }
                    }

                    TipSeparator {
                        visible: root.cfg.showCpu && root.cfg.showMem
                    }

                    // ---- Memory ----
                    TipHeader {
                        visible: root.cfg.showMem
                        title: i18n("Memory")
                        value: Math.round(root.memBarValue * 100) + "%"
                    }

                    // Thin usage bar over the whole pool
                    TipUsageBar {
                        visible: root.cfg.showMem && root.cfg.showMemBar
                        value: root.memBarValue
                        fillColor: root.memBarColor(root.memBarValue * 100)
                    }

                    TipDetail {
                        visible: root.cfg.showMem && root.cfg.showMemDetail
                            && !root.cfg.showResponsiveness
                        text: {
                            let t = i18n("apps %1", root.gib(memApp.value || 0));
                            if (root.cfg.includeSwap)
                                t += i18n(" · zram %1", root.gib(swapUsed.value || 0));
                            t += i18n(" · pool %1 / %2 GiB",
                                root.gib(root.memUsedBytes), root.gib(root.memTotalBytes));
                            return t;
                        }
                    }

                    // Honest memory line: real zram footprint, reclaimable cache.
                    TipDetail {
                        visible: root.cfg.showMem && root.cfg.showResponsiveness
                        text: {
                            let t = i18n("RAM %1/%2 GB",
                                root.gib(memApp.value || 0),
                                root.gib(memTotal.value || 0));
                            if (root.memCacheKB > 0)
                                t += i18n(" · cache %1 GB",
                                    root.gib(root.memCacheKB * 1024));
                            if (root.zramReal > 0) {
                                t += i18n(" · zram %1 → %2 GB (%3×)",
                                    root.gib(root.zramOrig),
                                    root.gib(root.zramReal),
                                    (root.zramOrig / root.zramReal).toFixed(1));
                            }
                            if (root.memAvailKB > 0)
                                t += i18n(" · avail %1 GB",
                                    root.gib(root.memAvailKB * 1024));
                            return t;
                        }
                    }

                    // Swap activity + the processes paying for it.
                    TipDetail {
                        visible: root.cfg.showMem && root.cfg.showResponsiveness
                        text: i18n("swap-in %1 pg/s · majfault %2/s",
                            root.rateText(root.swapInRate),
                            root.rateText(root.majfltRate))
                    }
                    Repeater {
                        model: root.cfg.showMem && root.cfg.showResponsiveness
                            ? root.swapGroups : []
                        TipRow {
                            required property var modelData
                            name: i18n("%1 swapped", modelData.name)
                            value: i18n("%1 GiB", root.gib(modelData.kB * 1024))
                        }
                    }

                    Repeater {
                        model: root.cfg.showMem ? root.memApps : []
                        TipRow {
                            required property var modelData
                            name: modelData.name
                            value: modelData.value
                        }
                    }

                    TipSeparator {
                        visible: root.cfg.showGpu || root.cfg.showVram || root.cfg.showSwap
                    }

                    // ---- Extras ----
                    TipHeader {
                        visible: root.cfg.showGpu
                        title: i18n("GPU")
                        value: Math.round(root.gpuPct * 100) + "%"
                    }
                    TipRow {
                        visible: root.cfg.showVram
                        name: i18n("VRAM")
                        value: i18n("%1 / %2 GiB",
                            root.gib(vramUsed.value || 0), root.gib(vramTotal.value || 0))
                    }
                    TipRow {
                        visible: root.cfg.showSwap
                        name: i18n("Swap (zram fill)")
                        value: Math.round(root.swapPct * 100) + "%"
                    }

                    // ---- Trend: 60 s sparkline of the lag value ----
                    TipSeparator {
                        visible: root.cfg.showResponsiveness && root.cfg.showCpu
                    }
                    TipHeader {
                        visible: root.cfg.showResponsiveness && root.cfg.showCpu
                        title: i18n("Trend")
                        value: i18n("last 60 s")
                    }
                    Canvas {
                        id: trendCanvas
                        visible: root.cfg.showResponsiveness && root.cfg.showCpu
                        Layout.fillWidth: true
                        Layout.preferredHeight: Kirigami.Units.gridUnit
                        onPaint: {
                            const ctx = getContext("2d");
                            ctx.reset();
                            const h = height;
                            const w = width;
                            if (h <= 0 || w <= 0)
                                return;
                            ctx.strokeStyle =
                                (root.lagHistory.length > 0
                                    && root.lagHistory[root.lagHistory.length - 1]
                                        >= root.cfg.psiWarn)
                                    ? Kirigami.Theme.negativeTextColor
                                    : Kirigami.Theme.highlightColor;
                            ctx.lineWidth = 1.5;
                            ctx.beginPath();
                            const n = root.lagHistory.length;
                            for (let i = 0; i < n; i++) {
                                const x = n > 1 ? (i / (n - 1)) * w : 0;
                                const v = Math.min(100,
                                    Math.max(0, root.lagHistory[i]));
                                const y = h - (v / 100) * h;
                                if (i === 0)
                                    ctx.moveTo(x, y);
                                else
                                    ctx.lineTo(x, y);
                            }
                            ctx.stroke();
                        }
                        Connections {
                            target: root
                            function onLagRevisionChanged() {
                                trendCanvas.requestPaint();
                            }
                        }
                        onVisibleChanged: requestPaint()
                    }
                }
            }
        }

        Row {
            id: row
            anchors.centerIn: parent
            height: parent.height - Kirigami.Units.smallSpacing
            spacing: root.cfg.barSpacing

            // On hybrid CPUs the all-core bar splits into one bar per core
            // type (P first, E second); uniform CPUs keep a single bar.
            ThinBar {
                visible: root.cfg.showCpu && !root.hybridTopology
                height: row.height
                value: root.dispUniform / 100
                barColor: root.cpuBarColor(root.cfg.cpuColor)
            }
            ThinBar {
                visible: root.cfg.showCpu && root.hybridTopology
                height: row.height
                value: root.dispP / 100
                barColor: root.cpuBarColor(root.cfg.cpuColor)
            }
            ThinBar {
                visible: root.cfg.showCpu && root.hybridTopology
                height: row.height
                value: root.dispE / 100
                barColor: root.cpuBarColor(root.cfg.eCpuColor)
            }
            ThinBar {
                visible: root.cfg.showGpu
                height: row.height
                value: root.gpuPct
                barColor: root.cfg.gpuColor
            }
            ThinBar {
                visible: root.cfg.showVram
                height: row.height
                value: root.vramPct
                barColor: root.cfg.vramColor
            }
            // Extra breathing room between the CPU/GPU group and memory
            Item {
                visible: root.cfg.showMem
                    && (root.cfg.showCpu || root.cfg.showGpu || root.cfg.showVram)
                width: visible ? 2 : 0
                height: row.height
            }
            MemBar {
                visible: root.cfg.showMem
                height: row.height
                appFraction: root.memSegApp
                zramFraction: root.memSegZram
                cacheFraction: root.memSegCache
                fillFraction: root.memBarValue
                flash: root.swapFlashOpacity
                barColor: root.memBarColor(root.memBarValue * 100)
            }
            ThinBar {
                visible: root.cfg.showSwap
                height: row.height
                value: root.swapPct
                barColor: root.cfg.swapColor
            }
        }
    }
}
