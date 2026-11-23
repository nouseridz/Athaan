import QtQuick
import qs.Ui
import "lib/Core.js" as Core

// Athaan bar widget: the next prayer and how long until it.
//
// It reads the service rather than polling on its own, so the bar, the panel
// and the notification all describe the same prayer at the same moment.
BarWidget {
    id: root
    moduleName: "io.github.nouseridz.athaan"

    readonly property var service: bar && bar.shell ? bar.shell.serviceFor(root.moduleName) : null

    readonly property bool ready: !!service && service.status === "ready" && service.nextName !== ""
    readonly property bool playing: !!service && service.athanPlaying === true
    readonly property string prayerName: ready ? service.nextName : ""
    readonly property string countdown: ready ? Core.countdownText(service.nextSeconds) : ""
    readonly property string place: service && service.locationLabel ? service.locationLabel : ""

    readonly property string label: {
        if (!ready) return service && service.status === "error" ? "—" : "…"
        return prayerName + " " + countdown
    }

    // Draw attention in the last ten minutes without inventing a colour: the
    // bar's own urgent token is what a countdown running out should look like.
    readonly property bool imminent: ready && service.nextSeconds > 0 && service.nextSeconds <= 600

    readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
    readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

    function open() { if (panelLoader.item) panelLoader.item.open() }
    function close() { if (panelLoader.item) panelLoader.item.close() }
    function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
    function closeForPopoutSwitch() {
        if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
    }

    function injectPanel() {
        var target = panelLoader.item
        if (!target) return
        if ("bar" in target) target.bar = root.bar
        if ("settings" in target) target.settings = root.settings
        if ("anchorItem" in target) target.anchorItem = button
        if ("hostWidget" in target) target.hostWidget = root
        if ("service" in target) target.service = root.service
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onBarChanged: injectPanel()
    onSettingsChanged: injectPanel()
    onServiceChanged: injectPanel()

    // The countdown only needs to repaint when the minute turns over, but the
    // service already ticks once a second for the firing check; reading it is
    // free, and QML coalesces the repaint.
    readonly property string tooltip: {
        if (!ready) return service && service.statusDetail ? service.statusDetail : "Athaan"
        var until = prayerName + " in " + countdown
        return place ? until + " · " + place : until
    }

    Loader {
        id: panelLoader
        active: true
        source: Qt.resolvedUrl("Panel.qml")
        visible: false
        onLoaded: {
            root.injectPanel()
            Qt.callLater(root.injectPanel)
        }
    }

    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.label
        active: root.imminent || root.playing
        tooltipText: root.tooltip
        onPressed: function(buttonCode) {
            if (buttonCode === Qt.LeftButton) root.togglePanel()
            else if (buttonCode === Qt.RightButton && root.service) root.service.refreshNow()
        }
    }
}
