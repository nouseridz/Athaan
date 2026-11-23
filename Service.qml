import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import "lib/Core.js" as Core

// Athaan service: headless singleton, the single owner of prayer state.
//
// The bar widget and the panel both read this object rather than fetching for
// themselves, so the network is touched at most twice a month, the countdown
// is one clock rather than several, and the Adhan that is playing is the same
// Adhan the panel's Stop button is looking at.
//
// Times come from Aladhan's monthly calendar, fetched once per month in both
// the location's local time and UTC. Local is what the panel displays; UTC is
// what turns into an epoch without guessing at the location's timezone.
Item {
    id: root

    // Injected by omarchy-shell.
    property var shell: null

    readonly property string pluginId: "io.github.nouseridz.athaan"
    // resolvedUrl percent-encodes characters such as spaces; decode before
    // handing the path to mpv.
    readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, ""))
    readonly property string soundsDir: pluginDir + "sounds/"

    readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (Commons.Color.home + "/.config")
    readonly property string cacheHome: Quickshell.env("XDG_CACHE_HOME") || (Commons.Color.home + "/.cache")
    readonly property string configDir: configHome + "/athaan"
    readonly property string configPath: configDir + "/config.json"
    readonly property string cacheDir: cacheHome + "/athaan"

    // ------------------------------------------------------------- config

    property var config: Core.defaultConfig()
    property bool configReady: false
    property int bump: 0 // written last, so one save() flushes a whole change

    // Survives a plugin hot-reload. A full shell restart starts empty, which is
    // why checkFiring() also refuses to play a prayer that was already due when
    // the service started.
    PersistentProperties {
        id: persisted
        reloadableId: "athaan"
        property string lastFiredKey: ""
        property string lastRemindedKey: ""
    }

    FileView {
        id: configFile
        path: root.configPath
                watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root.applyConfigText(text())
        // First run: no file yet, so start from defaults and write them.
        onLoadFailed: {
            root.config = Core.defaultConfig()
            root.configReady = true
            root.afterConfigReady()
        }
    }

    FileView {
        id: cacheFile
        path: root.cacheDir + "/times.json"
                watchChanges: false
        atomicWrites: true
        printErrors: false
        onLoaded: root.applyCacheText(text())
        onLoadFailed: root.applyCacheText("")
    }

    function applyConfigText(raw) {
        var parsed = null
        try {
            parsed = JSON.parse(raw || "{}")
        } catch (e) {
            console.warn("athaan: config is not JSON, using defaults")
        }
        root.config = Core.normalizeConfig(parsed)
        root.configReady = true
        root.afterConfigReady()
    }

    function saveConfig() {
        if (!root.configReady) return
        configFile.setText(JSON.stringify(root.config, null, 2) + "\n")
        root.bump++
    }

    // A single setter so the panel cannot write a field the validator would
    // reject: mutate a copy, normalize it, then persist.
    function updateConfig(patch) {
        var next = JSON.parse(JSON.stringify(root.config))
        for (var key in patch) next[key] = patch[key]
        root.config = Core.normalizeConfig(next)
        root.saveConfig()
        root.refreshSchedule()
    }

    // ------------------------------------------------------------- cache

    // { month: "2026-11", local: {dayIso: {...}}, utc: {dayIso: {...}},
    //   timezone: "...", fetchedAt: epoch }
    property var cache: ({ month: "", local: {}, utc: {}, timezone: "", fetchedAt: 0 })
    property bool cacheReady: false

    function applyCacheText(raw) {
        var parsed = null
        try {
            parsed = JSON.parse(raw || "{}")
        } catch (e) {}
        if (parsed && parsed.month && parsed.local && parsed.utc) {
            root.cache = {
                month: String(parsed.month),
                local: parsed.local || {},
                utc: parsed.utc || {},
                timezone: String(parsed.timezone || ""),
                fetchedAt: Number(parsed.fetchedAt) || 0
            }
        }
        root.cacheReady = true
        root.refreshSchedule()
    }

    function saveCache() {
        cacheFile.setText(JSON.stringify(root.cache) + "\n")
    }

    // ------------------------------------------------------------- state read by the UI

    property string status: "starting" // starting | detecting | loading | ready | error
    property string statusDetail: ""

    // Location wall clock, already offset-adjusted: what the panel lists.
    property var times: ({})
    property var timesNextDay: ({})
    property string nextName: ""
    property int nextEpoch: 0
    property int nextSeconds: 0
    property string todayIso: ""
property string nextDayIso: ""

    readonly property string locationLabel: Core.locationLabel(root.config ? root.config.location : null)
    readonly property bool hasLocation: Core.hasUsableLocation(root.config ? root.config.location : null)

    property int nowSec: Math.floor(Date.now() / 1000)
    // When this service was mounted. Used to tell "the adhan is due" from
    // "the adhan was already playing when the shell restarted".
    property int startedAt: Math.floor(Date.now() / 1000)

    Timer {
        interval: 1000
        repeat: true
        running: root.status === "ready"
        onTriggered: root.tick()
    }

    function tick() {
        root.nowSec = Math.floor(Date.now() / 1000)
        var today = Core.dayKeyOf(new Date())
        if (today !== root.todayIso) {
            // Midnight, or the machine woke up on a later day: rebuild the
            // day's schedule before anything else looks at it.
            root.todayIso = today
            root.refreshSchedule()
        }
        root.recomputeNext()
        root.checkFiring()
    }

    // ------------------------------------------------------------- schedule

    function refreshSchedule() {
        if (!root.cacheReady || !root.configReady) return
        if (!root.hasLocation) {
            root.status = "detecting"
            return
        }
        var month = Core.monthKey(new Date().getFullYear(), new Date().getMonth() + 1)
        if (root.cache.month !== month || !root.cache.local[root.todayIso] || !root.cache.utc[root.todayIso]) {
            root.fetchCalendar(month)
            // Keep showing what we have; a stale month beats an empty panel.
        }
        root.applyDay()
    }

    function applyDay() {
        var today = root.todayIso || Core.dayKeyOf(new Date())
        root.todayIso = today
        var tomorrow = Core.tomorrowKey(today)

        var localToday = root.cache.local[today] || null
        var utcToday = root.cache.utc[today] || null

        if (!localToday || !utcToday) {
            root.times = ({})
            root.timesNextDay = ({})
            root.nextName = ""
root.nextDayIso = ""
            root.nextEpoch = 0
            root.nextSeconds = 0
            // The game is not up: the cache may hold the rest of the month
            // but be missing this one day, which a refetch fixes.
            if (root.status !== "loading") root.status = "error"
            root.statusDetail = "No times for today yet."
            return
        }

        var offsets = root.config.offsets
        var globalOffset = root.config.globalOffset
        root.times = Core.applyOffsets(localToday, globalOffset, offsets)
        root.timesNextDay = Core.applyOffsets(root.cache.local[tomorrow] || {}, globalOffset, offsets)
        root.status = "ready"
        root.statusDetail = ""
        root.recomputeNext()
    }

    function recomputeNext() {
        if (!root.configReady) return
        var today = root.todayIso || Core.dayKeyOf(new Date())
        var tomorrow = Core.tomorrowKey(today)

        var days = {}
        var order = []
        var utcToday = root.cache.utc[today]
        var utcTomorrow = root.cache.utc[tomorrow]
        if (utcToday) {
            days[today] = utcToday
            order.push(today)
        }
        if (utcTomorrow) {
            days[tomorrow] = utcTomorrow
            order.push(tomorrow)
        }

        var next = Core.nextPrayerWithOffsets(days, order, root.nowSec,
root.config.globalOffset, root.config.offsets)
        if (!next) {
            root.nextName = ""
root.nextDayIso = ""
            root.nextEpoch = 0
            root.nextSeconds = 0
            return
        }
        root.nextName = next.name
        root.nextEpoch = next.epoch
root.nextDayIso = next.dayIso
        root.nextSeconds = next.seconds
    }

    // ------------------------------------------------------------- fetching

    property int pendingFetches: 0
    property string fetchError: ""

    function fetchCalendar(month) {
        if (!root.hasLocation) return
        if (root.status !== "detecting") root.status = "loading"
        var lat = Number(root.config.location.latitude)
        var lon = Number(root.config.location.longitude)
        var method = root.config.method
        var school = root.config.asrMadhab === "hanafi" ? 1 : 0
        var parts = month.split("-")
        var base = "https://api.aladhan.com/v1/calendar/" + parts[0] + "/" + parseInt(parts[1], 10)
            + "?latitude=" + lat + "&longitude=" + lon
            + "&method=" + method + "&school=" + school

        root.fetchError = ""
        fetchLocal.command = ["curl", "-q", "--fail", "--silent", "--show-error",
            "--max-time", "20", "--max-filesize", "4000000",
            "--proto", "=https", "-A", "athaan-omarchy-plugin/2.0", base]
        fetchLocal.month = month
        fetchLocal.running = true

        fetchUtc.command = ["curl", "-q", "--fail", "--silent", "--show-error",
            "--max-time", "20", "--max-filesize", "4000000",
            "--proto", "=https", "-A", "athaan-omarchy-plugin/2.0", base + "&timezonestring=UTC"]
        fetchUtc.month = month
        fetchUtc.running = true
    }

    property var stagedLocal: null
    property var stagedUtc: null

    Process {
        id: fetchLocal
        property string month: ""
        command: []
        running: false
        stdout: StdioCollector {
            waitForEnd: true
onStreamFinished: {
                var parsed = null
                try {
                    parsed = Core.parseCalendar(JSON.parse(text))
                } catch (e) {}
                if (!parsed) {
                    root.fetchError = "Could not read prayer times. Check the connection, then refresh."
                    root.status = "error"
                    root.statusDetail = root.fetchError
                    return
                }
                root.stagedLocal = parsed
                root.finishStaged(true, fetchLocal.month)
            }
        }
    }

    Process {
        id: fetchUtc
        property string month: ""
        command: []
        running: false
        stdout: StdioCollector {
            waitForEnd: true
onStreamFinished: {
                var parsed = null
                try {
                    parsed = Core.parseCalendar(JSON.parse(text))
                } catch (e) {}
                if (!parsed) {
                    root.status = "error"
                    root.statusDetail = "Could not read UTC prayer times."
                    return
                }
                root.stagedUtc = parsed
                root.finishStaged(false, fetchUtc.month)
            }
        }
    }

    function finishStaged(isLocal, month) {
        if (!root.stagedLocal || !root.stagedUtc) return
        root.cache = {
            month: month,
            local: root.stagedLocal.days,
            utc: root.stagedUtc.days,
            timezone: root.stagedLocal.timezone || root.stagedUtc.timezone || "",
            fetchedAt: Math.floor(Date.now() / 1000)
        }
        root.stagedLocal = null
        root.stagedUtc = null
        root.saveCache()
        root.applyDay()
        root.recomputeNext()
    }

    // ------------------------------------------------------------- location

    property var locationCandidates: []
    property bool locationSearching: false
    property int locationGeneration: 0

    Timer {
        id: locationDebounce
        // Nominatim allows at most one request per second.
        interval: 1000
        repeat: false
        onTriggered: root.runLocationSearch()
    }

    // Called by the panel as the user types. Debounced, and every request
    // carries a generation so a slow earlier reply cannot overwrite a newer one.
    function searchCities(query) {
        var q = Core.sanitizeText(query, Core.MAX_CITY_CHARS)
        // Invalidate any reply already in flight, so a slow result for an older
        // query cannot repopulate the list after the user has typed on.
        root.locationGeneration++
        if (q.length < 2) {
            root.pendingQuery = ""
            root.locationCandidates = []
            root.locationSearching = false
            locationDebounce.stop()
            return
        }
        root.pendingQuery = q
        root.locationSearching = true
        locationDebounce.restart()
    }

    property string pendingQuery: ""

    function runLocationSearch() {
        if (!root.pendingQuery) return
        searchProc.generation = root.locationGeneration
        searchProc.command = ["curl", "-q", "--fail", "--silent", "--show-error",
            "--max-time", "15", "--max-filesize", "2000000",
            "--proto", "=https",
            "-A", "athaan-omarchy-plugin/2.0 (Omarchy shell plugin)",
            "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=8&addressdetails=1&q="
                + encodeURIComponent(root.pendingQuery)]
        searchProc.running = true
    }

    Process {
        id: searchProc
        property int generation: 0
        command: []
        running: false
        stdout: StdioCollector {
            waitForEnd: true
onStreamFinished: {
                if (searchProc.generation !== root.locationGeneration) return
                var places = []
                try {
                    places = Core.parsePlaces(JSON.parse(text))
                } catch (e) {}
                root.locationCandidates = places
                root.locationSearching = false
            }
        }
        onExited: function(exitCode, exitStatus) {
            if (searchProc.generation === root.locationGeneration) root.locationSearching = false
        }
    }

    function chooseCity(place) {
        if (!place) return
        var loc = {
            auto: false,
            city: place.name,
            region: place.region || "",
            country: place.country || "",
            countryCode: place.countryCode || "",
            latitude: place.latitude,
            longitude: place.longitude,
            timezone: "",
            source: "manual"
        }
        root.updateConfig({ location: loc })
        root.locationCandidates = []
        root.cache = { month: "", local: {}, utc: {}, timezone: "", fetchedAt: 0 }
        root.stagedLocal = null
        root.stagedUtc = null
        if (root.hasLocation) root.fetchCalendar(Core.monthKey(new Date().getFullYear(), new Date().getMonth() + 1))
    }

    // Automatic location: one HTTPS GET against ipapi.co, which needs no key.
    // Only ever run on first start or when the user asks for it again.
    function detectLocation() {
        if (geoProc.running) return
        root.status = "detecting"
        root.statusDetail = ""
        geoProc.running = true
    }

    Process {
        id: geoProc
        command: ["curl", "-q", "--fail", "--silent", "--show-error",
            "--max-time", "15", "--max-filesize", "200000",
            "--proto", "=https", "-A", "athaan-omarchy-plugin/2.0",
            "https://ipapi.co/json/"]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
onStreamFinished: {
                var loc = null
                try {
                    loc = Core.parseGeo(JSON.parse(text))
                } catch (e) {}
                if (!loc) {
                    root.status = "error"
                    root.statusDetail = "Could not detect location from this network."
                    return
                }
                loc.auto = true
                root.updateConfig({ location: loc })
                root.cache = { month: "", local: {}, utc: {}, timezone: "", fetchedAt: 0 }
                root.fetchCalendar(Core.monthKey(new Date().getFullYear(), new Date().getMonth() + 1))
            }
        }
    }

    // A migrated config can name a city without coordinates. Resolve it once
    // rather than making the user re-pick the place they already chose.
    function geocodeSavedCity() {
        var loc = root.config.location
        if (!loc || !loc.city) {
            root.detectLocation()
            return
        }
        root.status = "detecting"
        geocodeProc.running = true
    }

    Process {
        id: geocodeProc
        command: ["curl", "-q", "--fail", "--silent", "--show-error",
            "--max-time", "15", "--max-filesize", "2000000",
            "--proto", "=https", "-A", "athaan-omarchy-plugin/2.0 (Omarchy shell plugin)",
            "https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&addressdetails=1&q="
                + encodeURIComponent(Core.sanitizeText(
                    root.config.location.city + ", " + root.config.location.country,
                    Core.MAX_LABEL_CHARS))]
        running: false
        stdout: StdioCollector {
            waitForEnd: true
onStreamFinished: {
                var places = []
                try {
                    places = Core.parsePlaces(JSON.parse(text))
                } catch (e) {}
                if (!places.length) {
                    root.detectLocation()
                    return
                }
                var place = places[0]
                var loc = {
                    auto: false,
                    city: place.name,
                    region: place.region || "",
                    country: place.country || root.config.location.country,
                    countryCode: place.countryCode || "",
                    latitude: place.latitude,
                    longitude: place.longitude,
                    timezone: "",
                    source: "manual"
                }
                root.updateConfig({ location: loc })
                root.fetchCalendar(Core.monthKey(new Date().getFullYear(), new Date().getMonth() + 1))
            }
        }
        onExited: function(exitCode, exitStatus) {
            if (exitCode !== 0 && !root.hasLocation) root.detectLocation()
        }
    }

    function afterConfigReady() {
        root.todayIso = Core.dayKeyOf(new Date())
        if (!root.hasLocation) {
            var loc = root.config.location
            if (loc && loc.city && !loc.auto) {
                root.geocodeSavedCity()
            } else {
                root.detectLocation()
            }
            return
        }
        root.refreshSchedule()
    }

    // ------------------------------------------------------------- firing

    function firedKeyFor(prayer, dayIso) {
        return dayIso + ":" + prayer
    }

    function checkFiring() {
        if (root.status !== "ready") return
        var cfg = root.config
        var today = root.todayIso

        for (var i = 0; i < Core.PRAYERS.length; i++) {
            var p = Core.PRAYERS[i]
            if (!root.times[p]) continue
            // The displayed clock is local to the place; the epoch comes from
            // the UTC series with the same offset applied, so both agree.
            var epoch = root.adjustedEpoch(today, p)
            if (epoch === null) continue

            if (cfg.enabledPrayers[p] === false) continue

            var firedKey = root.firedKeyFor(p, today)
            if (persisted.lastFiredKey === firedKey) continue

            // Lead-time reminder.
            var lead = Number(cfg.reminderMinutes || 0) * 60
            var remindedKey = root.firedKeyFor(p, today)
            if (lead > 0 && persisted.lastRemindedKey !== remindedKey
                    && root.nowSec >= epoch - lead && root.nowSec < epoch) {
                persisted.lastRemindedKey = remindedKey
                if (cfg.notificationsEnabled && cfg.notifyPrayers[p] !== false) {
                    root.notify(p + " in " + cfg.reminderMinutes + " min",
                        "It's almost time for " + p + " prayer in " + (root.locationLabel || "your area") + ".")
                }
            }

            if (root.nowSec >= epoch) {
                persisted.lastFiredKey = firedKey
                // Fire only if the service was already running before the
                // prayer. A shell restart just after the adhan began must not
                // play it again.
                if (root.nowSec < epoch + 120 && root.startedAt <= epoch) {
                    if (cfg.notificationsEnabled && cfg.notifyPrayers[p] !== false) {
                        root.notify(p + " prayer time", "It's time for " + p + ".")
                    }
                    root.playAthan(p)
                }
            }
        }
    }

    function adjustedEpoch(dayIso, prayer) {
        var utcDay = root.cache.utc[dayIso]
        if (!utcDay || !utcDay[prayer]) return null
        return Core.utcEpochWithOffset(dayIso, utcDay[prayer], Core.offsetFor(
            prayer, root.config.globalOffset, root.config.offsets))
            }

    // ------------------------------------------------------------- audio

    property bool athanPlaying: false
    property string athanPrayer: ""

    Process {
        id: athanProc
        command: []
        running: false
        onRunningChanged: {
            if (!running) {
                root.athanPlaying = false
                root.athanPrayer = ""
            }
        }
    }

    function soundPath(voiceId) {
        return root.soundsDir + Core.voiceById(voiceId).file
    }

    function playAthan(prayer) {
        if (!root.config.athanEnabled) return
        root.startAthan(root.config.athanVoice, prayer)
    }

    // The panel's Test button uses this too, so a sample and a real Adhan
    // behave identically — including the Stop that follows.
    function startAthan(voiceId, prayer) {
        var id = Core.isVoiceId(voiceId) ? voiceId : root.config.athanVoice
        root.stopAthan()
        athanProc.command = ["mpv", "--no-video", "--no-terminal", "--really-quiet",
            "--volume=" + Core.clampInt(root.config.athanVolume, 0, 100, 70),
            "--audio-client-name=Athaan",
            root.soundPath(id)]
        athanProc.running = true
        root.athanPlaying = true
        root.athanPrayer = prayer || ""
    }

    function testAthan(voiceId) {
        root.startAthan(voiceId || root.config.athanVoice, "")
    }

    // Setting `running` false asks Quickshell to send SIGTERM, which is how
    // mpv is meant to be interrupted; no IPC socket, no kill(1).
    function stopAthan() {
        if (athanProc.running) athanProc.running = false
        root.athanPlaying = false
        root.athanPrayer = ""
    }

    // ------------------------------------------------------------- notify

    Process {
        id: notifyProc
        command: []
        running: false
        stdout: StdioCollector { waitForEnd: true
onStreamFinished: {} }
    }

    function notify(headline, body) {
        notifyProc.command = ["omarchy-notification-send",
            "--app-name", "Athaan", "-u", "normal", "-g", "🕌",
            Core.sanitizeText(headline, 80), Core.sanitizeText(body, 200)]
        notifyProc.running = true
    }

    // ------------------------------------------------------------- panel actions

    function refreshNow() {
        root.cache = { month: "", local: {}, utc: {}, timezone: "", fetchedAt: 0 }
        root.stagedLocal = null
        root.stagedUtc = null
        if (root.hasLocation) {
            root.fetchCalendar(Core.monthKey(new Date().getFullYear(), new Date().getMonth() + 1))
        } else {
            root.detectLocation()
        }
    }

    function resetToAutomatic() {
        root.updateConfig({ location: {
            auto: true, city: "", region: "", country: "", countryCode: "",
            latitude: 0, longitude: 0, timezone: "", source: ""
        } })
        root.cache = { month: "", local: {}, utc: {}, timezone: "", fetchedAt: 0 }
        root.detectLocation()
    }

    Component.onCompleted: root.todayIso = Core.dayKeyOf(new Date())
}
