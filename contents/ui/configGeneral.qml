import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM
import org.kde.kquickcontrols as KQuickControls

KCM.SimpleKCM {
    id: page

    property alias cfg_barWidth: barWidthSpin.value
    property alias cfg_barSpacing: barSpacingSpin.value
    property alias cfg_updateInterval: updateSpin.value
    property alias cfg_showCpu: cpuCheck.checked
    property alias cfg_showGpu: gpuCheck.checked
    property alias cfg_showVram: vramCheck.checked
    property alias cfg_showMem: memCheck.checked
    property alias cfg_showSwap: swapCheck.checked
    property alias cfg_includeSwap: includeSwapCheck.checked
    property alias cfg_warnThreshold: warnSpin.value
    property alias cfg_critThreshold: critSpin.value
    property alias cfg_cpuColor: cpuColorBtn.color
    property alias cfg_eCpuColor: eCpuColorBtn.color
    property alias cfg_gpuColor: gpuColorBtn.color
    property alias cfg_vramColor: vramColorBtn.color
    property alias cfg_memColor: memColorBtn.color
    property alias cfg_swapColor: swapColorBtn.color
    property alias cfg_showCoreHeatmap: heatmapCheck.checked
    property alias cfg_heatWarnThreshold: heatWarnSpin.value
    property alias cfg_heatCritThreshold: heatCritSpin.value
    property alias cfg_topAppsCpu: topCpuSpin.value
    property alias cfg_topAppsMem: topMemSpin.value
    property alias cfg_showMemBar: memBarCheck.checked
    property alias cfg_showMemDetail: memDetailCheck.checked

    Kirigami.FormLayout {

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Appearance")
        }

        QQC2.SpinBox {
            id: barWidthSpin
            Kirigami.FormData.label: i18n("Bar thickness (px):")
            from: 1
            to: 24
        }

        QQC2.SpinBox {
            id: barSpacingSpin
            Kirigami.FormData.label: i18n("Gap between bars (px):")
            from: 0
            to: 24
        }

        QQC2.SpinBox {
            id: updateSpin
            Kirigami.FormData.label: i18n("Update interval (ms):")
            from: 250
            to: 10000
            stepSize: 250
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Monitors")
        }

        RowLayout {
            Kirigami.FormData.label: i18n("CPU usage:")
            QQC2.CheckBox { id: cpuCheck }
            QQC2.Label {
                text: i18nc("P-core bar color", "P")
                opacity: 0.6
            }
            KQuickControls.ColorButton {
                id: cpuColorBtn
                enabled: cpuCheck.checked
            }
            QQC2.Label {
                text: i18nc("E-core bar color", "E")
                opacity: 0.6
            }
            KQuickControls.ColorButton {
                id: eCpuColorBtn
                enabled: cpuCheck.checked
            }
        }

        RowLayout {
            Kirigami.FormData.label: i18n("GPU usage:")
            QQC2.CheckBox { id: gpuCheck }
            KQuickControls.ColorButton { id: gpuColorBtn; enabled: gpuCheck.checked }
        }

        RowLayout {
            Kirigami.FormData.label: i18n("VRAM:")
            QQC2.CheckBox { id: vramCheck }
            KQuickControls.ColorButton { id: vramColorBtn; enabled: vramCheck.checked }
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Memory:")
            QQC2.CheckBox { id: memCheck }
            KQuickControls.ColorButton { id: memColorBtn; enabled: memCheck.checked }
        }

        RowLayout {
            Kirigami.FormData.label: i18n("Swap (zram):")
            QQC2.CheckBox { id: swapCheck }
            KQuickControls.ColorButton { id: swapColorBtn; enabled: swapCheck.checked }
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Memory bar")
        }

        QQC2.CheckBox {
            id: includeSwapCheck
            text: i18n("Include zram swap in usage and total")
        }

        QQC2.SpinBox {
            id: warnSpin
            Kirigami.FormData.label: i18n("Warning threshold (%):")
            from: 0
            to: 100
        }

        QQC2.SpinBox {
            id: critSpin
            Kirigami.FormData.label: i18n("Critical threshold (%):")
            from: 0
            to: 100
        }

        Item {
            Kirigami.FormData.isSection: true
            Kirigami.FormData.label: i18n("Tooltip")
        }

        QQC2.CheckBox {
            id: heatmapCheck
            text: i18n("Show per-core heatmap")
        }

        QQC2.SpinBox {
            id: heatWarnSpin
            Kirigami.FormData.label: i18n("Heatmap warning (%):")
            enabled: heatmapCheck.checked
            from: 0
            to: 100
        }

        QQC2.SpinBox {
            id: heatCritSpin
            Kirigami.FormData.label: i18n("Heatmap critical (%):")
            enabled: heatmapCheck.checked
            from: 0
            to: 100
        }

        QQC2.SpinBox {
            id: topCpuSpin
            Kirigami.FormData.label: i18n("Top CPU apps per core type (0 = off):")
            from: 0
            to: 10
        }

        QQC2.SpinBox {
            id: topMemSpin
            Kirigami.FormData.label: i18n("Top memory applications (0 = off):")
            from: 0
            to: 10
        }

        QQC2.CheckBox {
            id: memBarCheck
            text: i18n("Show memory usage bar")
        }

        QQC2.CheckBox {
            id: memDetailCheck
            text: i18n("Show memory breakdown line")
        }
    }
}
