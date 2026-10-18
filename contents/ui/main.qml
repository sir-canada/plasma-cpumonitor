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

    function friendlyApplicationName(name) {
        const value = String(name);
        // Ghostty's transient terminal scopes are exposed by KSysGuard as
        // "surface", which is its internal scope name rather than an app name.
        return value === "surface" ? i18n("Ghostty terminals") : value;
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

            for (const pid of pids) {
                const key = String(pid);
                groupedPids[key] = true;
                const coreUsage = root.coreCpuByPid[key];
                if (coreUsage) {
                    pPercent += coreUsage.p;
                    ePercent += coreUsage.e;
                }
            }

            if (menuId === "services") {
                // The shared "Background Services" application lumps unrelated
                // daemons together, which hides what actually uses CPU. List
                // its processes individually by their sampled names and keep
                // only those above the whole-machine CPU threshold.
                if (memoryKiB > 0)
                    memory.push({ name: displayName, amount: memoryKiB });

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
                memory.push({ name: displayName, amount: memoryKiB });
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
        root.memApps = memory.slice(0, root.cfg.topAppsMem).map(item => ({
            name: item.name,
            value: (item.amount / 1048576).toFixed(2) + " GiB"
        }));
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
                } else if (f[0] === "TOPO" && f[1] === "core") {
                    root.pCores = root.expandCpuList(f[2]);
                } else if (f[0] === "TOPO" && f[1] === "atom") {
                    root.eCores = root.expandCpuList(f[2]);
                }
            });
            root.coreCpuByPid = usage;
            if (sampleReady) {
                root.coreSampleReady = true;
                root.pCpuGroupPct = Math.min(100, totalP);
                root.eCpuGroupPct = Math.min(100, totalE);
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
                        value: Math.round(root.memPct * 100) + "%"
                    }

                    // Thin usage bar over the whole pool
                    TipUsageBar {
                        visible: root.cfg.showMem && root.cfg.showMemBar
                        value: root.memPct
                        fillColor: root.loadColor(root.memPct * 100,
                            root.cfg.warnThreshold, root.cfg.critThreshold)
                    }

                    TipDetail {
                        visible: root.cfg.showMem && root.cfg.showMemDetail
                        text: {
                            let t = i18n("apps %1", root.gib(memApp.value || 0));
                            if (root.cfg.includeSwap)
                                t += i18n(" · zram %1", root.gib(swapUsed.value || 0));
                            t += i18n(" · pool %1 / %2 GiB",
                                root.gib(root.memUsedBytes), root.gib(root.memTotalBytes));
                            return t;
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
                value: root.cpuPct
                barColor: root.cfg.cpuColor
            }
            ThinBar {
                visible: root.cfg.showCpu && root.hybridTopology
                height: row.height
                value: root.pCpuGroupPct / 100
                barColor: root.cfg.cpuColor
            }
            ThinBar {
                visible: root.cfg.showCpu && root.hybridTopology
                height: row.height
                value: root.eCpuGroupPct / 100
                barColor: root.cfg.eCpuColor
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
            ThinBar {
                visible: root.cfg.showMem
                height: row.height
                value: root.memPct
                barColor: {
                    const pct = root.memPct * 100;
                    if (pct >= root.cfg.critThreshold)
                        return Kirigami.Theme.negativeTextColor;
                    if (pct >= root.cfg.warnThreshold)
                        return Kirigami.Theme.neutralTextColor;
                    return root.cfg.memColor;
                }
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
