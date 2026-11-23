import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "lib/Core.js" as Core

// The Athaan popup: the day's schedule, then everything that decides how that
// schedule is produced — voice, offsets, location, calculation method.
//
// It owns no state. Times, offsets, location candidates and playback all live
// in Service.qml, so the bar, the notification and this panel can never
// disagree about which prayer is next.
//
// The three row types at the bottom are inline components rather than a
// components/ directory: Quickshell refuses to import a module path outside its
// own config folder, so a plugin cannot ship siblings as a QML module.
Panel {
    id: root

    moduleName: "io.github.nouseridz.athaan"
    manageIpc: false

    // Injected by BarWidget.qml — see injectPanel() there.
    property var anchorItem: null
    property var hostWidget: null
    property var service: null

    // The bar identifies a panel by the widget in its slot, not by this
    // nested object.
    readonly property var barIdentity: hostWidget || root

    readonly property var cfg: service && service.config ? service.config : Core.defaultConfig()
    readonly property var times: service && service.times ? service.times : ({})
readonly property var timesNextDay: service && service.timesNextDay ? service.timesNextDay : ({})
    readonly property var location: cfg.location ? cfg.location : ({})
    readonly property bool live: !!service && service.status === "ready"
    readonly property bool playing: !!service && service.athanPlaying === true

    // After Isha the next prayer belongs to tomorrow, so today's row must not
    // light up as though its time were still ahead.
    readonly property bool nextIsToday: {
        if (!root.live || !root.service.nextDayIso) return false
        return root.service.nextDayIso === root.service.todayIso
    }

    readonly property color contentForeground: bar ? bar.foreground : Commons.Color.foreground
    readonly property color contentAccent: Commons.Color.accent
    readonly property color mutedForeground: Qt.darker(contentForeground, 1.35)
    readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

    // Which voice the panel is auditioning right now. Kept here rather than in
    // the service because it is purely a view state: the service only knows
    // that something is playing.
    property string auditioning: ""

    readonly property var methodOptions: {
        var out = []
        for (var i = 0; i < Core.METHODS.length; i++) {
            out.push({ value: String(Core.METHODS[i].id), label: Core.METHODS[i].name })
        }
        return out
    }

    readonly property var madhabOptions: [
        { value: "standard", label: "Standard (Shafi'i, Maliki, Hanbali)" },
        { value: "hanafi", label: "Hanafi" }
    ]

    readonly property string statusLine: {
        if (!service) return "Waiting for the service…"
        if (service.status === "ready") return root.placeLine
        if (service.status === "detecting") return "Looking up your location…"
        if (service.status === "loading") return "Fetching prayer times…"
        if (service.status === "error") return service.statusDetail || "Prayer times unavailable"
        return "Starting…"
    }

    readonly property string placeLine: {
        var place = Core.locationLabel(location)
        if (!place) return "No location set"
        return location.source === "ip" ? place + " · detected" : place
    }

    // ------------------------------------------------------------ panel chrome

    function open() {
        root.controller.show()
    }

    function close() {
        root.controller.hide()
    }

    function toggle() {
        if (root.opened) root.close()
        else root.open()
    }

    function switchPanel(direction) {
        if (root.bar && typeof root.bar.switchPanelFrom === "function")
            return root.bar.switchPanelFrom(root.barIdentity, direction)
        return false
    }

    // ------------------------------------------------------------ writes

    function setConfig(patch) {
        if (root.service) root.service.updateConfig(patch)
    }

    function shiftedOffsets(prayer, delta) {
        var next = {}
        var current = cfg.offsets ? cfg.offsets : {}
        for (var i = 0; i < Core.PRAYERS.length; i++) {
            var key = Core.PRAYERS[i]
            next[key] = Core.clampInt(current[key], -60, 60, 0)
        }
        next[prayer] = Core.clampInt(next[prayer] + delta, -60, 60, 0)
        return next
    }

    function shiftOffset(prayer, delta) {
        root.setConfig({ offsets: root.shiftedOffsets(prayer, delta) })
    }

    function toggledPrayerMap(map, prayer) {
        var next = {}
        var source = map ? map : {}
        for (var i = 0; i < Core.PRAYERS.length; i++) {
            var key = Core.PRAYERS[i]
            next[key] = Core.asBool(source[key], true)
        }
        next[prayer] = !Core.asBool(next[prayer], true)
        return next
    }

    function timeFor(prayer) {
        var raw = root.times ? root.times[prayer] : ""
        if (!raw) return "—"
        return Core.displayClock(raw, root.cfg.hour12)
    }

    function audition(voiceId) {
        if (!root.service) return
        if (root.auditioning === voiceId && root.playing) {
            root.service.stopAthan()
            root.auditioning = ""
            return
        }
        root.auditioning = voiceId
        root.service.testAthan(voiceId)
    }

    Connections {
        target: root.service
        function onAthanPlayingChanged() {
            if (!root.service.athanPlaying) root.auditioning = ""
        }
    }

    // ------------------------------------------------------------ content

    KeyboardPanel {
        id: panel

        anchorItem: root.anchorItem
        owner: root.barIdentity
        bar: root.bar
        open: root.opened
        // Anchored under the widget rather than the middle of the bar.
        centerOnBar: false
        focusTarget: panel.loadedContent
        contentWidth: panel.fittedContentWidth(Style.space(380))
        contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

        content: PanelKeyCatcher {
            id: keyCatcher

            // Let embedded text inputs and dropdown popups own the keys while active.
blocked: cityField.activeFocus || reminderStepper.field.activeFocus || methodDropdown.popupOpen || asrDropdown.popupOpen
            implicitHeight: body.implicitHeight
            anchors.fill: parent
            onCloseRequested: root.close()

            // The search field lives inside this component, so it is cleared
            // here rather than from the panel root, which cannot see its ids.
            function pickCity(place) {
                cityField.text = ""
                if (root.service) root.service.chooseCity(place)
            }

            Flickable {
                id: flick

                anchors.fill: parent
                contentWidth: width
                contentHeight: body.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick

                Column {
                    id: body

                    width: flick.width
                    spacing: Style.spacing.panelGap

                    // -------------------------------------------------- header
                    Item {
                        width: parent.width
                        height: Math.max(headerText.implicitHeight, refreshButton.height)

                        Column {
                            id: headerText

                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width - refreshButton.width - Style.spacing.sm
                            spacing: 0

                            Text {
                                width: parent.width
                                textFormat: Text.PlainText
                                text: "🕌 " + (root.live ? root.service.nextName : "Athaan")
                                color: root.contentForeground
                                font.family: root.contentFontFamily
                                font.pixelSize: Style.font.title
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Text {
                                width: parent.width
                                textFormat: Text.PlainText
                                text: root.live
                                      ? "in " + Core.countdownText(root.service.nextSeconds) + " · " + root.statusLine
                                      : root.statusLine
                                color: root.mutedForeground
                                font.family: root.contentFontFamily
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                            }
                        }

                        PanelActionButton {
                            id: refreshButton

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            iconText: "⟳"
                            tooltipText: "Refresh prayer times"
                            foreground: root.contentForeground
                            onClicked: if (root.service) root.service.refreshNow()
                        }
                    }

                    // -------------------------------------------------- today
                    Column {
                        width: parent.width
                        spacing: Style.spacing.hairline

                        Repeater {
                            model: Core.PRAYERS

                            delegate: PrayerTimeRow {
                                required property var modelData

                                width: body.width
                                name: modelData
                                time: root.timeFor(modelData)
                                upcoming: root.nextIsToday && root.service.nextName === modelData
                                foreground: root.contentForeground
                                accent: root.contentAccent
                                fontFamily: root.contentFontFamily
                            }
                        }
                    }

                    Text {
                        width: parent.width
                        visible: root.live
                        textFormat: Text.PlainText
                        text: "Tomorrow's Fajr: " + (root.timesNextDay && root.timesNextDay.Fajr
                                                     ? Core.displayClock(root.timesNextDay.Fajr, root.cfg.hour12)
                                                     : "—")
                        color: Qt.darker(root.contentForeground, 1.5)
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                    }

                    // -------------------------------------------------- adhan
                    PanelSeparator { foreground: root.contentForeground }

                    PanelSectionHeader {
                        text: "Adhan"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                    }

                    Toggle {
                        width: parent.width
                        label: "Play at prayer time"
                        description: root.cfg.athanEnabled ? "Audible" : "Silent"
                        checked: root.cfg.athanEnabled
                        foreground: root.contentForeground
                        accent: root.contentAccent
                        fontFamily: root.contentFontFamily
                        onClicked: root.setConfig({ athanEnabled: !root.cfg.athanEnabled })
                    }

                    Column {
                        width: parent.width
                        spacing: Style.spacing.hairline

                        Repeater {
                            model: Core.VOICES

                            delegate: VoiceRow {
                                required property var modelData

                                width: body.width
                                name: modelData.name
                                detail: modelData.detail
                                selected: root.cfg.athanVoice === modelData.id
                                playing: root.auditioning === modelData.id && root.playing
                                foreground: root.contentForeground
                                accent: root.contentAccent
                                fontFamily: root.contentFontFamily
                                onPicked: root.setConfig({ athanVoice: modelData.id })
                                onTestRequested: root.audition(modelData.id)
                            }
                        }
                    }

                    Item {
                        width: parent.width
                        height: stopButton.visible ? stopButton.implicitHeight : 0

                        Button {
                            id: stopButton

                            width: parent.width
                            visible: root.playing
                            text: root.service && root.service.athanPrayer
                                  ? "Stop Adhan · " + root.service.athanPrayer
                                  : "Stop Adhan"
                            foreground: root.contentForeground
                            accent: root.contentAccent
                            fontFamily: root.contentFontFamily
                            onClicked: {
                                if (root.service) root.service.stopAthan()
                                root.auditioning = ""
                            }
                        }
                    }

                    Item {
                        width: parent.width
                        height: Math.max(volumeLabel.implicitHeight, volumeSlider.implicitHeight)

                        Text {
                            id: volumeLabel

                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: "Volume"
                            color: root.contentForeground
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.body
                        }

                        Text {
                            id: volumeValue

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: root.cfg.athanVolume + "%"
                            color: root.mutedForeground
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.caption
                        }

                        PanelSlider {
                            id: volumeSlider

                            anchors.left: volumeLabel.right
                            anchors.leftMargin: Style.spacing.md
                            anchors.right: volumeValue.left
                            anchors.rightMargin: Style.spacing.md
                            anchors.verticalCenter: parent.verticalCenter
                            bar: root.bar
                            minimum: 0
                            maximum: 100
                            step: 5
                            integer: true
                            value: root.cfg.athanVolume
                            onReleased: function(v) { root.setConfig({ athanVolume: Math.round(v) }) }
                        }
                    }

                    // -------------------------------------------------- reminders
                    PanelSeparator { foreground: root.contentForeground }

                    PanelSectionHeader {
                        text: "Reminders"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                    }

                    Toggle {
                        width: parent.width
                        label: "Desktop notification"
                        description: "A notice before the Adhan, a note at the time"
                        checked: root.cfg.notificationsEnabled
                        foreground: root.contentForeground
                        accent: root.contentAccent
                        fontFamily: root.contentFontFamily
                        onClicked: root.setConfig({ notificationsEnabled: !root.cfg.notificationsEnabled })
                    }

                    Item {
                        width: parent.width
                        height: Math.max(reminderLabel.implicitHeight, reminderStepper.implicitHeight)

                        Text {
                            id: reminderLabel

                            anchors.left: parent.left
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: "Notify ahead (minutes)"
                            color: root.contentForeground
                            font.family: root.contentFontFamily
                            font.pixelSize: Style.font.body
                        }

                        NumberField {
                            id: reminderStepper

                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            fieldWidth: Style.space(72)
                            from: 0
                            to: 60
                            stepSize: 5
                            value: root.cfg.reminderMinutes
                            foreground: root.contentForeground
                            accent: root.contentAccent
                            fontFamily: root.contentFontFamily
                            onModified: function(v) { root.setConfig({ reminderMinutes: v }) }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Style.spacing.xs

                        Repeater {
                            model: Core.PRAYERS

                            delegate: Button {
                                required property var modelData

                                readonly property bool notifyOn: root.cfg.notifyPrayers
                                                                 ? Core.asBool(root.cfg.notifyPrayers[modelData], true)
                                                                 : true

                                width: (body.width - Style.spacing.xs * (Core.PRAYERS.length - 1))
                                       / Core.PRAYERS.length
                                text: modelData
                                selected: notifyOn
                                enabled: root.cfg.notificationsEnabled
                                foreground: root.contentForeground
                                accent: root.contentAccent
                                fontFamily: root.contentFontFamily
                                fontSize: Style.font.caption
                                horizontalPadding: Style.spacing.xs
                                onClicked: root.setConfig({
                                    notifyPrayers: root.toggledPrayerMap(root.cfg.notifyPrayers, modelData)
                                })
                            }
                        }
                    }

                    // -------------------------------------------------- location
                    PanelSeparator { foreground: root.contentForeground }

                    PanelSectionHeader {
                        text: "Location"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                    }

                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: root.placeLine
                        color: root.mutedForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                    }

                    TextField {
                        id: cityField

                        width: parent.width
                        placeholderText: "Search for a city…"
                        foreground: root.contentForeground
                        accent: root.contentAccent
                        onTextChanged: if (root.service) root.service.searchCities(text)
                    }

                    Text {
                        width: parent.width
                        visible: root.service && root.service.locationSearching
                        textFormat: Text.PlainText
                        text: "Searching…"
                        color: root.mutedForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                    }

                    Column {
                        width: parent.width
                        spacing: Style.spacing.hairline
                        visible: root.service && root.service.locationCandidates.length > 0

                        Repeater {
                            model: root.service ? root.service.locationCandidates : []

                            delegate: Button {
                                required property var modelData

                                width: body.width
                                text: modelData.label
                                leftAlign: true
                                foreground: root.contentForeground
                                accent: root.contentAccent
                                fontFamily: root.contentFontFamily
                                fontSize: Style.font.bodySmall
                                onClicked: keyCatcher.pickCity(modelData)
                            }
                        }
                    }

                    Button {
                        width: parent.width
                        text: "Detect automatically"
                        foreground: root.contentForeground
                        accent: root.contentAccent
                        fontFamily: root.contentFontFamily
                        onClicked: if (root.service) root.service.resetToAutomatic()
                    }

                    // -------------------------------------------------- offsets
                    PanelSeparator { foreground: root.contentForeground }

                    PanelSectionHeader {
                        text: "Adjustments"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                    }

                    Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: "Shift the times to match your masjid. Minutes, per prayer."
                        color: root.mutedForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                    }

                    Column {
                        width: parent.width
                        spacing: Style.spacing.hairline

                        OffsetStepper {
                            width: body.width
                            label: "All prayers"
                            value: root.cfg.globalOffset
                            foreground: root.contentForeground
                            accent: root.contentAccent
                            fontFamily: root.contentFontFamily
                            onStepRequested: function(delta) {
                                root.setConfig({
                                    globalOffset: Core.clampInt(root.cfg.globalOffset + delta, -60, 60, 0)
                                })
                            }
                        }

                        Repeater {
                            model: Core.PRAYERS

                            delegate: OffsetStepper {
                                required property var modelData

                                width: body.width
                                label: modelData
                                value: root.cfg.offsets ? Core.clampInt(root.cfg.offsets[modelData], -60, 60, 0) : 0
                                foreground: root.contentForeground
                                accent: root.contentAccent
                                fontFamily: root.contentFontFamily
                                onStepRequested: function(delta) { root.shiftOffset(modelData, delta) }
                            }
                        }
                    }

                    // -------------------------------------------------- calculation
                    PanelSeparator { foreground: root.contentForeground }

                    PanelSectionHeader {
                        text: "Calculation"
                        foreground: root.contentForeground
                        fontFamily: root.contentFontFamily
                    }

                    Dropdown {
                        width: parent.width
                        id: methodDropdown
label: "Method"
                        value: String(root.cfg.method)
                        options: root.methodOptions
                        foreground: root.contentForeground
                        accent: root.contentAccent
                        fontFamily: root.contentFontFamily
                        onChanged: function(selected) {
                            root.setConfig({ method: Number(selected) })
                        }
                    }

                    Dropdown {
                        width: parent.width
                        id: asrDropdown
label: "Asr"
                        value: root.cfg.asrMadhab
                        options: root.madhabOptions
                        foreground: root.contentForeground
                        accent: root.contentAccent
                        fontFamily: root.contentFontFamily
                        onChanged: function(selected) {
                            root.setConfig({ asrMadhab: selected })
                        }
                    }

                    Toggle {
                        width: parent.width
                        label: "12-hour clock"
                        description: root.cfg.hour12 ? "Shown as 5:06 PM" : "Shown as 17:06"
                        checked: root.cfg.hour12
                        foreground: root.contentForeground
                        accent: root.contentAccent
                        fontFamily: root.contentFontFamily
                        onClicked: root.setConfig({ hour12: !root.cfg.hour12 })
                    }
                }
            }
        }
    }

    // ------------------------------------------------------------ rows
    //
    // Inline rather than separate files: Quickshell will not load a plugin's
    // sibling directory as a QML module, so these live in this file and are
    // instantiated by type name above.

    component PrayerTimeRow: Item {
        id: timeRow

        property string name: ""
        property string time: ""
        property bool upcoming: false
        property color foreground: Commons.Color.foreground
        property color accent: Commons.Color.accent
        property string fontFamily: Style.font.family
        property real titleSize: Style.font.body

        implicitWidth: Style.space(240)
        implicitHeight: Math.max(Style.spacing.controlHeight,
                                 labelText.implicitHeight,
                                 timeText.implicitHeight)

        Text {
            id: labelText

            anchors.left: parent.left
            anchors.right: timeText.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: timeRow.name
            color: timeRow.upcoming ? timeRow.accent : timeRow.foreground
            font.family: timeRow.fontFamily
            font.pixelSize: timeRow.titleSize
            font.bold: timeRow.upcoming
            elide: Text.ElideRight
        }

        Text {
            id: timeText

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: timeRow.time
            color: timeRow.upcoming ? timeRow.accent : Qt.darker(timeRow.foreground, 1.15)
            font.family: timeRow.fontFamily
            font.pixelSize: timeRow.titleSize
            font.bold: timeRow.upcoming
            horizontalAlignment: Text.AlignRight
        }
    }

    // A signed minutes field: − value +, where the value always shows its sign
    // so 0 reads as a deliberate setting rather than an empty one.
    component OffsetStepper: Item {
        id: stepper

        property string label: ""
        property int value: 0
        property color foreground: Commons.Color.foreground
        property color accent: Commons.Color.accent
        property string fontFamily: Style.font.family

        signal stepRequested(int delta)

        readonly property string signedText: (stepper.value > 0 ? "+" : "") + stepper.value + "m"

        implicitWidth: Style.space(240)
        implicitHeight: Math.max(Style.spacing.controlHeight, labelText.implicitHeight)

        Text {
            id: labelText

            anchors.left: parent.left
            anchors.right: minusButton.left
            anchors.rightMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: stepper.label
            color: stepper.foreground
            font.family: stepper.fontFamily
            font.pixelSize: Style.font.body
            elide: Text.ElideRight
        }

        PanelActionButton {
            id: plusButton

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "+"
            tooltipText: "Later"
            foreground: stepper.foreground
            hoverColor: stepper.accent
            onClicked: stepper.stepRequested(1)
        }

        Text {
            id: valueText

            anchors.right: plusButton.left
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(44)
            textFormat: Text.PlainText
            text: stepper.signedText
            color: stepper.value === 0 ? Qt.darker(stepper.foreground, 1.3) : stepper.accent
            font.family: stepper.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
        }

        PanelActionButton {
            id: minusButton

            anchors.right: valueText.left
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            iconText: "−"
            tooltipText: "Earlier"
            foreground: stepper.foreground
            hoverColor: stepper.accent
            onClicked: stepper.stepRequested(-1)
        }
    }

    // One bundled recitation: name and character on the left, a select target,
    // and its own Test button so a voice can be judged before it is chosen.
    component VoiceRow: Item {
        id: voiceRow

        property string name: ""
        property string detail: ""
        property bool selected: false
        property bool playing: false
        property color foreground: Commons.Color.foreground
        property color accent: Commons.Color.accent
        property string fontFamily: Style.font.family

        signal picked()
        signal testRequested()

        implicitWidth: Style.space(240)
        implicitHeight: Math.max(Style.spacing.controlHeight + Style.spacing.md, texts.implicitHeight)

        CursorSurface {
            anchors.fill: parent
            foreground: voiceRow.foreground
            accent: voiceRow.accent
            current: voiceRow.selected
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: voiceRow.picked()
        }

        Column {
            id: texts

            anchors.left: parent.left
            anchors.leftMargin: Style.spacing.rowPaddingX
            anchors.right: testButton.left
            anchors.rightMargin: Style.spacing.sm
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: voiceRow.name
                color: voiceRow.selected ? voiceRow.accent : voiceRow.foreground
                font.family: voiceRow.fontFamily
                font.pixelSize: Style.font.body
                font.bold: voiceRow.selected
                elide: Text.ElideRight
            }

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: voiceRow.detail
                color: Qt.darker(voiceRow.foreground, 1.4)
                font.family: voiceRow.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
            }
        }

        Button {
            id: testButton

            anchors.right: parent.right
            anchors.rightMargin: Style.spacing.xs
            anchors.verticalCenter: parent.verticalCenter
            text: voiceRow.playing ? "Stop" : "Test"
            foreground: voiceRow.foreground
            accent: voiceRow.accent
            fontFamily: voiceRow.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY / 2
            onClicked: voiceRow.testRequested()
        }
    }
}
