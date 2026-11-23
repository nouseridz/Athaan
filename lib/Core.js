// Athaan core logic. Pure functions only — no Qt, no Quickshell, no I/O —
// so every rule here (clock parsing, offset application, next-prayer search,
// response validation) can be reasoned about and tested on its own.

.pragma library

var PRAYERS = ["Fajr", "Dhuhr", "Asr", "Maghrib", "Isha"]

// Curated from GET https://api.aladhan.com/v1/methods. Ids are stable.
var METHODS = [
    { id: 3, name: "Muslim World League" },
    { id: 2, name: "Islamic Society of North America" },
    { id: 5, name: "Egyptian General Authority of Survey" },
    { id: 4, name: "Umm Al-Qura, Makkah" },
    { id: 1, name: "University of Islamic Sciences, Karachi" },
    { id: 7, name: "Institute of Geophysics, University of Tehran" },
    { id: 8, name: "Gulf Region" },
    { id: 9, name: "Kuwait" },
    { id: 10, name: "Qatar" },
    { id: 11, name: "Majlis Ugama Islam Singapura" },
    { id: 12, name: "Union Organization Islamic de France" },
    { id: 13, name: "Diyanet Isleri Baskanligi, Turkey" },
    { id: 14, name: "Spiritual Administration of Muslims of Russia" },
    { id: 16, name: "Dubai" },
    { id: 17, name: "JAKIM, Malaysia" },
    { id: 19, name: "KEMENAG, Indonesia" },
    { id: 20, name: "Morocco" },
    { id: 21, name: "Comunidade Islamica de Lisboa" },
    { id: 23, name: "Ministry of Awqaf, Egypt" }
]

// The bundled recordings. `file` is relative to the plugin's sounds/ dir.
var VOICES = [
    { id: "doha", name: "Doha, Qatar", detail: "Recorded 2013–14", file: "adhan-doha.mp3" },
    { id: "imadi", name: "Ahmed al-Imadi", detail: "Warm, measured", file: "adhan-imadi.mp3" },
    { id: "hamathani", name: "Majed al-Hamathani", detail: "Long phrased, resonant", file: "adhan-hamathani.mp3" },
    { id: "qatami", name: "Nasser al-Qatami", detail: "Bright, brisk", file: "adhan-qatami.mp3" }
]

var MAX_CITY_CHARS = 40
var MAX_LABEL_CHARS = 80
var MAX_RESULTS = 8

// ---------------------------------------------------------------- text safety
//
// Everything a plugin displays that did not originate in its own source is
// untrusted: city names come from a network API, so they are stripped of
// markup and control characters and length-capped before they reach any
// component, ours or the shell's.
function sanitizeText(value, max) {
    var s = String(value === undefined || value === null ? "" : value)
    // Control, bidi-override and BOM characters: they can reorder or hide the
    // text around them even though they draw nothing.
    s = s.replace(/[\u0000-\u001f\u007f\u200e\u200f\u202a-\u202e\u2066-\u2069\ufeff]/g, " ")
    s = s.replace(/[<>&"'`]/g, "")
    s = s.replace(/\s+/g, " ")
    s = s.replace(/^\s+|\s+$/g, "")
    var limit = max === undefined ? MAX_LABEL_CHARS : max
    return s.length > limit ? s.substring(0, limit) : s
}

// ---------------------------------------------------------------- clock maths

// "05:06 (WAT)", "05:06", "5:6" -> 306. Null when the field is unusable.
function parseClock(raw) {
    var s = String(raw === undefined || raw === null ? "" : raw)
    var m = s.match(/^\s*(\d{1,2}):(\d{1,2})/)
    if (!m) return null
    var h = parseInt(m[1], 10)
    var min = parseInt(m[2], 10)
    if (!(h >= 0 && h <= 23) || !(min >= 0 && min <= 59)) return null
    return h * 60 + min
}

function clockText(minutes) {
    var total = ((Math.round(minutes) % 1440) + 1440) % 1440
    var h = Math.floor(total / 60)
    var m = total % 60
    return (h < 10 ? "0" + h : "" + h) + ":" + (m < 10 ? "0" + m : "" + m)
}

function addMinutes(clock, delta) {
    var base = parseClock(clock)
    if (base === null) return ""
    return clockText(base + Number(delta || 0))
}

// 12-hour display for users who want it; 24-hour otherwise.
function displayClock(clock, hour12) {
    if (!hour12) return clock
    var base = parseClock(clock)
    if (base === null) return clock
    var h = Math.floor(base / 60)
    var m = base % 60
    var suffix = h < 12 ? "AM" : "PM"
    var h12 = h % 12
    if (h12 === 0) h12 = 12
    return h12 + ":" + (m < 10 ? "0" + m : "" + m) + " " + suffix
}

// ---------------------------------------------------------------- dates/epochs
//
// Prayer times are computed for a place, and a place has its own timezone.
// Rather than convert wall-clock times across timezones ourselves — which
// needs a tz database and gets DST wrong — the fetcher asks Aladhan for the
// same month twice, once in the location's local time (for display) and once
// with timezonestring=UTC (for arithmetic). A UTC wall clock converts to an
// epoch with Date.UTC and no ambiguity, DST handled upstream per day.

function pad2(n) {
    return n < 10 ? "0" + n : "" + n
}

function dayKey(year, month, day) {
    return year + "-" + pad2(month) + "-" + pad2(day)
}

function dayKeyOf(date) {
    return dayKey(date.getFullYear(), date.getMonth() + 1, date.getDate())
}

function monthKey(year, month) {
    return year + "-" + pad2(month)
}

function utcDayKeyOfEpoch(epoch) {
 var d = new Date(Number(epoch) * 1000)
 return dayKey(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate())
}

// "YYYY-MM-DD" + "HH:MM" in UTC -> unix seconds. Null if either is malformed.
function utcEpoch(dayIso, clock) {
    var d = String(dayIso || "").match(/^(\d{4})-(\d{2})-(\d{2})$/)
    var c = parseClock(clock)
    if (!d || c === null) return null
    var h = Math.floor(c / 60)
    var m = c % 60
    var ms = Date.UTC(parseInt(d[1], 10), parseInt(d[2], 10) - 1, parseInt(d[3], 10), h, m, 0, 0)
    return isNaN(ms) ? null : Math.floor(ms / 1000)
}

// Same conversion, but with a signed minute offset that may cross midnight.
// Display clocks wrap at 24h; epochs must not — a -20m shift on a 00:10 Fajr
// belongs to the previous UTC day.
function utcEpochWithOffset(dayIso, clock, offsetMinutes) {
 var d = String(dayIso || "").match(/^(\d{4})-(\d{2})-(\d{2})$/)
 var c = parseClock(clock)
 if (!d || c === null) return null
 var total = c + (Number(offsetMinutes) || 0)
 var ms = Date.UTC(parseInt(d[1], 10), parseInt(d[2], 10) - 1, parseInt(d[3], 10))
 + total * 60000
 return isNaN(ms) ? null : Math.floor(ms / 1000)
}

// ---------------------------------------------------------------- offsets

// Per-prayer offset applied on top of an optional global shift. Offsets are
// what users actually need: Fajr runs early at their masjid, Asr is later
// under a particular madhab, and so on.
function offsetFor(prayer, globalOffset, perPrayer) {
    var g = clampInt(globalOffset, -60, 60, 0)
    var p = perPrayer && typeof perPrayer === "object" ? perPrayer[prayer] : 0
    return g + clampInt(p, -60, 60, 0)
}

function applyOffsets(timings, globalOffset, perPrayer) {
    var out = {}
    for (var i = 0; i < PRAYERS.length; i++) {
        var p = PRAYERS[i]
        var clock = timings ? timings[p] : ""
        out[p] = clock ? addMinutes(clock, offsetFor(p, globalOffset, perPrayer)) : ""
    }
    return out
}

// ---------------------------------------------------------------- validation

function clampInt(value, lo, hi, fallback) {
    var n = Number(value)
    if (!isFinite(n)) return fallback
    n = Math.round(n)
    if (n < lo) return lo
    if (n > hi) return hi
    return n
}

function asBool(value, fallback) {
    if (value === undefined || value === null) return fallback
    if (typeof value === "boolean") return value
    var s = String(value).toLowerCase()
    if (s === "true" || s === "1" || s === "on" || s === "yes") return true
    if (s === "false" || s === "0" || s === "off" || s === "no") return false
    return fallback
}

function asNumber(value, fallback, lo, hi) {
    var n = Number(value)
    if (!isFinite(n)) return fallback
    if (lo !== undefined && n < lo) return lo
    if (hi !== undefined && n > hi) return hi
    return n
}

function isVoiceId(id) {
    for (var i = 0; i < VOICES.length; i++) if (VOICES[i].id === id) return true
    return false
}

function voiceById(id) {
    for (var i = 0; i < VOICES.length; i++) if (VOICES[i].id === id) return VOICES[i]
    return VOICES[0]
}

function methodById(id) {
    var wanted = Number(id)
    for (var i = 0; i < METHODS.length; i++) if (METHODS[i].id === wanted) return METHODS[i]
    return METHODS[0]
}

// ---------------------------------------------------------------- Aladhan

// Response envelope: {"code":200,"status":"OK","data":[...]} for a calendar.
// Returns {"days": {dayIso: {Fajr:"05:06", ...}}, "timezone": "..."} or null.
function parseCalendar(payload) {
    if (!payload || payload.code !== 200 || !payload.data || !payload.data.length) return null
    var days = {}
    var timezone = ""
    for (var i = 0; i < payload.data.length; i++) {
        var entry = payload.data[i]
        if (!entry || !entry.timings || !entry.date) continue
        var greg = entry.date.gregorian
        if (!greg) continue
        var dayIso = String(greg.date || "")
        // Aladhan uses DD-MM-YYYY here.
        var parts = dayIso.split("-")
        if (parts.length !== 3) continue
        var key = parts[2] + "-" + parts[1] + "-" + parts[0]
        var timings = {}
        var usable = false
        for (var j = 0; j < PRAYERS.length; j++) {
            var p = PRAYERS[j]
            var clock = parseClock(entry.timings[p])
            timings[p] = clock === null ? "" : clockText(clock)
            if (clock !== null) usable = true
        }
        if (!usable) continue
        days[key] = timings
        if (!timezone && entry.meta && entry.meta.timezone) timezone = String(entry.meta.timezone)
    }
    // A well-formed envelope whose every entry was unusable is not a calendar;
    // treating it as one would overwrite a good cache with an empty month.
    if (Object.keys(days).length === 0) return null
    if (!timezone && payload.data[0] && payload.data[0].meta) {
        timezone = String(payload.data[0].meta.timezone || "")
    }
    return { days: days, timezone: timezone }
}

// ---------------------------------------------------------------- geo-IP

// ipapi.co returns city/region/country_name/country/latitude/longitude.
// Returns a location object or null when the response is not usable.
function parseGeo(payload) {
    if (!payload || payload.error) return null
    var lat = Number(payload.latitude)
    var lon = Number(payload.longitude)
    var city = sanitizeText(payload.city, MAX_CITY_CHARS)
    var country = sanitizeText(payload.country_name || payload.country, MAX_CITY_CHARS)
    if (!city || !country) return null
    if (!isFinite(lat) || !isFinite(lon)) return null
    if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null
    return {
        city: city,
        region: sanitizeText(payload.region, MAX_CITY_CHARS),
        country: country,
        countryCode: sanitizeText(payload.country_code, 8).toUpperCase(),
        latitude: lat,
        longitude: lon,
        timezone: sanitizeText(payload.timezone, MAX_LABEL_CHARS),
        source: "ip"
    }
}

// ---------------------------------------------------------------- Nominatim

// Settlement results only: Nominatim ranks states and countries alongside
// cities, and a prayer-time lookup wants a place people actually live in.
function parsePlaces(raw) {
    if (!raw || !raw.length) return []
    var out = []
    for (var i = 0; i < raw.length && out.length < MAX_RESULTS; i++) {
        var r = raw[i]
        if (!r) continue
        var rank = Number(r.place_rank)
        if (!isFinite(rank) || rank < 14 || rank > 22) continue
        var lat = Number(r.lat)
        var lon = Number(r.lon)
        if (!isFinite(lat) || !isFinite(lon)) continue
        var address = r.address || {}
        var name = sanitizeText(r.name || address.city || address.town || address.village, MAX_CITY_CHARS)
        if (!name) continue
        var region = sanitizeText(address.state || address.county, MAX_CITY_CHARS)
        var country = sanitizeText(address.country, MAX_CITY_CHARS)
        var label = sanitizeText(
            name + (region ? ", " + region : "") + (country ? ", " + country : ""),
            MAX_LABEL_CHARS)
        out.push({
            name: name,
            region: region,
            country: country,
            countryCode: sanitizeText(address.country_code, 8).toUpperCase(),
            latitude: lat,
            longitude: lon,
            label: label
        })
    }
    return out
}

// ---------------------------------------------------------------- next prayer

// Looks at today and tomorrow so the bar still has an answer after Isha,
// instead of going blank for the rest of the evening.
// days: {dayIso: {Prayer: "HH:MM"}} already offset-adjusted, in UTC wall clock.
// Returns {name, dayIso, epoch, seconds} or null.
function nextPrayer(days, dayIsos, nowSec) {
    var best = null
    for (var d = 0; d < dayIsos.length; d++) {
        var dayIso = dayIsos[d]
        var timings = days[dayIso]
        if (!timings) continue
        for (var i = 0; i < PRAYERS.length; i++) {
            var p = PRAYERS[i]
            var clock = timings[p]
            if (!clock) continue
            var epoch = utcEpoch(dayIso, clock)
            if (epoch === null || epoch <= nowSec) continue
            if (!best || epoch < best.epoch) best = { name: p, dayIso: utcDayKeyOfEpoch(epoch), epoch: epoch }
        }
    }
    if (!best) return null
    best.seconds = best.epoch - nowSec
    return best
}

// Same search, but applies offsets while converting to epochs so an offset
// that crosses midnight lands on the right day. `days` here are the raw UTC
// clocks from the cache, not wrapped display strings.
function nextPrayerWithOffsets(days, dayIsos, nowSec, globalOffset, perPrayer) {
 var best = null
 for (var d = 0; d < dayIsos.length; d++) {
 var dayIso = dayIsos[d]
 var timings = days[dayIso]
 if (!timings) continue
 for (var i = 0; i < PRAYERS.length; i++) {
 var p = PRAYERS[i]
 var clock = timings[p]
 if (!clock) continue
 var epoch = utcEpochWithOffset(dayIso, clock, offsetFor(p, globalOffset, perPrayer))
 if (epoch === null || epoch <= nowSec) continue
 if (!best || epoch < best.epoch) best = { name: p, dayIso: utcDayKeyOfEpoch(epoch), epoch: epoch }
 }
 }
 if (!best) return null
 best.seconds = best.epoch - nowSec
 return best
}

function tomorrowKey(dayIso) {
    var m = String(dayIso || "").match(/^(\d{4})-(\d{2})-(\d{2})$/)
    if (!m) return ""
    var d = new Date(Date.UTC(parseInt(m[1], 10), parseInt(m[2], 10) - 1, parseInt(m[3], 10) + 1))
    return dayKeyOf(new Date(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()))
}

// ---------------------------------------------------------------- formatting

function countdownText(seconds) {
    var s = Math.max(0, Math.round(Number(seconds) || 0))
    if (s < 60) return "<1m"
    var h = Math.floor(s / 3600)
    var m = Math.floor((s % 3600) / 60)
    if (h > 0) return h + "h " + m + "m"
    return m + "m"
}

// The bar's whole label. Kept short: a bar is not a panel.
function barLabel(name, seconds) {
    if (!name) return "—"
    return name + " " + countdownText(seconds)
}

// ---------------------------------------------------------------- config

function defaultConfig() {
    var perPrayer = {}
    var enabled = {}
    var notify = {}
    for (var i = 0; i < PRAYERS.length; i++) {
        perPrayer[PRAYERS[i]] = 0
        enabled[PRAYERS[i]] = true
        notify[PRAYERS[i]] = true
    }
    return {
        schemaVersion: 2,
        location: {
            auto: true,
            city: "",
            region: "",
            country: "",
            countryCode: "",
            latitude: 0,
            longitude: 0,
            timezone: "",
            source: ""
        },
        method: 3,
        asrMadhab: "standard",
        globalOffset: 0,
        offsets: perPrayer,
        enabledPrayers: enabled,
        reminderMinutes: 10,
        notificationsEnabled: true,
        notifyPrayers: notify,
        athanEnabled: true,
        athanVolume: 70,
        athanVoice: "doha",
        hour12: false,
        showSeconds: false
    }
}

// Merges a config read from disk over the defaults, dropping anything that
// fails validation. A hand-edited or corrupted config degrades to defaults
// rather than breaking the plugin.
function normalizeConfig(raw) {
    var cfg = defaultConfig()
    if (!raw || typeof raw !== "object") return cfg

    // Version 1 kept city/country at the top level and nested the adhan
    // settings. Carry those across so an upgrade does not silently forget a
    // location the user already picked.
    if (!raw.location && (raw.city || raw.country)) {
        raw.location = {
            auto: false,
            city: raw.city,
            country: raw.country,
            latitude: 0,
            longitude: 0,
            source: "manual"
        }
    }
    if (raw.reminderMinutes === undefined && raw.reminder_minutes_before !== undefined) {
        raw.reminderMinutes = raw.reminder_minutes_before
    }
    // Version 1 spelled the Asr madhab in snake_case.
    if (raw.asrMadhab === undefined && raw.asr_madhab !== undefined) {
        raw.asrMadhab = raw.asr_madhab
    }
    if (raw.notificationsEnabled === undefined && raw.notifications_enabled !== undefined) {
        raw.notificationsEnabled = raw.notifications_enabled
    }
    if (raw.athanEnabled === undefined && raw.athan && raw.athan.enabled !== undefined) {
        raw.athanEnabled = raw.athan.enabled
    }
    if (raw.athanVolume === undefined && raw.athan && raw.athan.volume !== undefined) {
        raw.athanVolume = raw.athan.volume
    }
    if (!raw.enabledPrayers && raw.enabled_prayers) raw.enabledPrayers = raw.enabled_prayers

    cfg.schemaVersion = 2

    var loc = raw.location && typeof raw.location === "object" ? raw.location : {}
    cfg.location.auto = asBool(loc.auto, cfg.location.auto)
    cfg.location.city = sanitizeText(loc.city, MAX_CITY_CHARS)
    cfg.location.region = sanitizeText(loc.region, MAX_CITY_CHARS)
    cfg.location.country = sanitizeText(loc.country, MAX_CITY_CHARS)
    cfg.location.countryCode = sanitizeText(loc.countryCode, 8).toUpperCase()
    cfg.location.latitude = asNumber(loc.latitude, 0, -90, 90)
    cfg.location.longitude = asNumber(loc.longitude, 0, -180, 180)
    cfg.location.timezone = sanitizeText(loc.timezone, MAX_LABEL_CHARS)
    cfg.location.source = loc.source === "ip" || loc.source === "manual" ? loc.source : ""

    cfg.method = methodById(asNumber(raw.method, 3)).id
    cfg.asrMadhab = raw.asrMadhab === "hanafi" ? "hanafi" : "standard"
    cfg.globalOffset = clampInt(raw.globalOffset, -60, 60, 0)

    var offsets = raw.offsets && typeof raw.offsets === "object" ? raw.offsets : {}
    for (var i = 0; i < PRAYERS.length; i++) {
        var p = PRAYERS[i]
        cfg.offsets[p] = clampInt(offsets[p], -60, 60, 0)
        cfg.enabledPrayers[p] = asBool(raw.enabledPrayers ? raw.enabledPrayers[p] : undefined, true)
        cfg.notifyPrayers[p] = asBool(raw.notifyPrayers ? raw.notifyPrayers[p] : undefined, true)
    }

    cfg.reminderMinutes = clampInt(raw.reminderMinutes, 0, 60, 10)
    cfg.notificationsEnabled = asBool(raw.notificationsEnabled, true)
    cfg.athanEnabled = asBool(raw.athanEnabled, true)
    cfg.athanVolume = clampInt(raw.athanVolume, 0, 100, 70)
    cfg.athanVoice = isVoiceId(raw.athanVoice) ? raw.athanVoice : "doha"
    cfg.hour12 = asBool(raw.hour12, false)
    cfg.showSeconds = asBool(raw.showSeconds, false)

    return cfg
}

function hasUsableLocation(location) {
    if (!location) return false
    if (!location.city || !location.country) return false
    var lat = Number(location.latitude)
    var lon = Number(location.longitude)
    if (!isFinite(lat) || !isFinite(lon)) return false
    if (lat === 0 && lon === 0) return false
    return lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180
}

function locationLabel(location) {
    if (!location) return ""
    var parts = []
    if (location.city) parts.push(location.city)
    if (location.country) parts.push(location.country)
    return sanitizeText(parts.join(", "), MAX_LABEL_CHARS)
}
