# Athaan

Prayer times in the Omarchy bar: the next prayer, a live countdown, the day's
times in a popup, and the adhan played over notification-friendly `mpv`.

## Install

```sh
./install.sh
```

This copies the plugin to `~/.config/omarchy/plugins/io.github.nouseridz.athaan`
and restarts the shell. Then enable **Athaan** in the bar settings.

## Requirements

Omarchy (Quickshell), `mpv`, and `curl`. `omarchy-notification-send` ships with
Omarchy and is used for the prayer notifications.

## Location

On first run the plugin asks [ipapi.co](https://ipapi.co) where you are, then
fetches prayer times for those coordinates. If the guess is wrong, open the
panel and type a city — the search autocompletes from
[Nominatim](https://nominatim.openstreetmap.org) as you type (debounced to one
request per second, their maximum). Typing a city pins the location; *Detect
automatically* returns it to IP detection.

Coordinates are what the Aladhan API is queried with, never a city string: the
API accepts a city string without validating it against the country, so
`Istanbul, Nigeria` silently returns Istanbul's times.

## Times

Times come from the [Aladhan](https://aladhan.com/prayer-times-api) calendar
API, two requests per month, cached in `~/.cache/athaan/times.json`. Both are
made the first time a month is seen:

- the plain calendar, used for the times you read;
- the same calendar with `&timezonestring=UTC`, used to turn those wall-clock
  times into real instants.

The second call is what makes the countdown survive DST changes and travel:
"Maghrib 18:42" is only an instant once you know which zone it was printed in.

A minute-granular countdown is then computed locally against a one-second
timer. Nothing is polled from the network while the app runs; a refetch happens
when the month rolls over, when the location changes, or when you press
*Refresh*.

## Adhan

Four recordings, one per voice:

| Voice | Recording | Length |
| --- | --- | --- |
| Doha | Adhan from Doha, Qatar | 3:37 |
| Imadi | Ahmed al-Imadi | 2:59 |
| Hamathani | Majed al-Hamathani | 3:39 |
| Qatami | Nasser al-Qatami | 2:12 |

The Doha recording is from the Internet Archive item
[`adhan.recordings.from.doha.qatar`](https://archive.org/details/adhan.recordings.from.doha.qatar);
the other three are from
[`adhan.notifications`](https://archive.org/details/adhan.notifications). All
are **Public Domain Mark 1.0**.

Each voice has a **Test** button in the panel. **Stop Adhan** halts playback
immediately — it sends SIGTERM to the player rather than waiting for the file
to end.

## Settings

Everything lives in `~/.config/athaan/config.json`:

- **Method** — 19 calculation conventions, from the Aladhan method list.
- **Asr madhab** — Shafi (standard) or Hanafi.
- **Offsets** — a per-prayer shift in minutes, ±60. Local mosque a minute or
  two off? Fix it here instead of editing times by hand.
- **Reminders** — an advance notification N minutes before each prayer, on the
  prayers you choose.
- **Adhan** — enable, pick a voice, set the volume.
- **Display** — 12/24-hour clock.

A pre-2.0 config is migrated on load, so upgrading does not lose your settings.

## Notes

Times are computed for today *and* tomorrow, so the bar keeps counting down
after Isha instead of showing `--:--`. The last prayer that fired is remembered
across hot reloads, and a prayer that was already due when the shell started is
not replayed, so restarting at 18:01 does not play the sunset adhan again.
