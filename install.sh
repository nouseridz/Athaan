#!/bin/sh
# Install Athaan into the user's Omarchy plugins directory.
set -eu

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
dest="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/io.github.nouseridz.athaan"

for cmd in mpv curl; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "athaan: '$cmd' is required but not installed" >&2
    exit 1
  }
done

echo "Installing to $dest"
mkdir -p "$dest"
# The pre-2.0 plugin shipped a Python backend and one recording per prayer;
# neither exists any more.
rm -rf "$dest/bin"
rm -f "$dest"/sounds/Fajr.mp3 "$dest"/sounds/Dhuhr.mp3 \
      "$dest"/sounds/Asr.mp3 "$dest"/sounds/Maghrib.mp3 "$dest"/sounds/Isha.mp3

if [ "$here" != "$dest" ]; then
  # Copy the plugin without .git or the installer itself.
  ( cd "$here" && tar -cf - --exclude=.git --exclude=install.sh . ) \
    | ( cd "$dest" && tar -xf - )
fi
rm -f "$dest/install.sh"

if command -v omarchy-restart-shell >/dev/null 2>&1; then
  omarchy-restart-shell
else
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
fi

echo "Done. Enable Athaan in the bar settings if it is not showing."
