import QtQuick
import QtQml
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.plasma5support as P5Support
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.kirigami as Kirigami
import org.kde.ksysguard.sensors as Sensors

PlasmoidItem {
    id: root

    preferredRepresentation: fullRepresentation

    readonly property var cfg: Plasmoid.configuration

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

    Sensors.Sensor { id: cpuSensor; sensorId: "cpu/all/usage"; enabled: root.cfg.showCpu; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: gpuSensor; sensorId: "gpu/all/usage"; enabled: root.cfg.showGpu; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: vramUsed; sensorId: "gpu/all/usedVram"; enabled: root.cfg.showVram; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: vramTotal; sensorId: "gpu/all/totalVram"; enabled: root.cfg.showVram; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: memApp; sensorId: "memory/physical/application"; enabled: root.cfg.showMem; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: memTotal; sensorId: "memory/physical/total"; enabled: root.cfg.showMem; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: swapUsed; sensorId: "memory/swap/used"; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: swapTotal; sensorId: "memory/swap/total"; updateRateLimit: root.cfg.updateInterval }
    Sensors.Sensor { id: coreCount; sensorId: "cpu/all/coreCount"; updateRateLimit: 60000 }

    // --- Tooltip data: per-core usage + top processes ---
    property var coreVals: []
    property var cpuApps: []
    property var memApps: []
    property var pCores: []   // thread indices of P-cores (Intel hybrid)
    property var eCores: []   // thread indices of E-cores

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
        model: coreCount.value || 0
        delegate: Sensors.Sensor {
            sensorId: "cpu/cpu" + index + "/usage"
            updateRateLimit: root.cfg.updateInterval
        }
    }

    Timer {
        interval: root.cfg.updateInterval
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

    P5Support.DataSource {
        id: procStats
        engine: "executable"
        readonly property string scriptPath:
            Qt.resolvedUrl("../scripts/topstats.sh").toString().replace("file://", "")
        connectedSources: ["sh '" + scriptPath + "' "
            + root.cfg.topAppsCpu + " " + root.cfg.topAppsMem]
        interval: Math.max(3000, root.cfg.updateInterval * 2)
        onNewData: (source, data) => {
            const out = data.stdout || "";
            const cpu = [];
            const mem = [];
            out.split("\n").forEach(l => {
                const f = l.split("|");
                if (f[0] === "CPU")
                    cpu.push({ name: f[1], value: f[2] + "%" });
                else if (f[0] === "MEM")
                    mem.push({ name: f[1], value: f[2] + " GiB" });
                else if (f[0] === "TOPO" && f[1] === "core")
                    root.pCores = root.expandCpuList(f[2]);
                else if (f[0] === "TOPO" && f[1] === "atom")
                    root.eCores = root.expandCpuList(f[2]);
            });
            root.cpuApps = cpu;
            root.memApps = mem;
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

    fullRepresentation: Item {
        Layout.minimumWidth: row.implicitWidth + 2
        Layout.preferredWidth: Layout.minimumWidth
        Layout.minimumHeight: Kirigami.Units.gridUnit
        Layout.fillHeight: true

        PlasmaCore.ToolTipArea {
            anchors.fill: parent

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

                    Repeater {
                        model: root.cfg.showCpu ? root.cpuApps : []
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
                    Rectangle {
                        visible: root.cfg.showMem && root.cfg.showMemBar
                        Layout.fillWidth: true
                        height: 4
                        radius: 2
                        color: Qt.alpha(Kirigami.Theme.textColor, 0.15)
                        Rectangle {
                            width: parent.width * Math.min(1, root.memPct)
                            height: parent.height
                            radius: 2
                            color: root.loadColor(root.memPct * 100,
                                root.cfg.warnThreshold, root.cfg.critThreshold)
                            Behavior on width {
                                NumberAnimation { duration: 300; easing.type: Easing.OutQuad }
                            }
                        }
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

            ThinBar {
                visible: root.cfg.showCpu
                height: row.height
                value: root.cpuPct
                barColor: root.cfg.cpuColor
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
