#!/bin/bash
# Read-only health check for MacBook 12-inch Linux fixes (camera/audio/sleep).
# Run as your normal user; nothing here changes system state.
set -u
hr() { printf '\n== %s ==\n' "$1"; }

hr "Kernel"
uname -r

hr "DKMS status (must say 'installed' for the RUNNING kernel)"
dkms status

hr "Loaded module identity (loaded srcversion must match modinfo; path must be updates/dkms)"
for m in facetimehd snd_hda_codec_cs420x; do
  if [ -d "/sys/module/$m" ]; then
    echo "$m: loaded=$(cat /sys/module/$m/srcversion 2>/dev/null)" \
         "modinfo=$(modinfo -F srcversion "$m" 2>/dev/null)" \
         "path=$(modinfo -n "$m" 2>/dev/null)"
  else
    echo "$m: NOT LOADED"
  fi
done

hr "Camera device"
ls /dev/video* 2>/dev/null || echo "no /dev/video* — camera missing"
command -v v4l2-ctl >/dev/null && v4l2-ctl --list-formats-ext -d /dev/video0 2>/dev/null | head -12

hr "ALSA cards"
cat /proc/asound/cards

hr "PipeWire graph (need a sink AND a source under Audio, camera under Video)"
command -v wpctl >/dev/null && wpctl status | sed -n '/^Audio/,/^Settings/p'

hr "Sleep mode (want [deep])"
cat /sys/power/mem_sleep
ls -l /usr/lib/systemd/system-sleep/ /etc/systemd/system-sleep/ 2>/dev/null

hr "Last suspend/resume events (healthy: deep entry -> S3 wake -> suspend exit)"
journalctl --no-pager -g 'PM: suspend entry|Waking up from|PM: suspend exit' -n 12 2>/dev/null

hr "Kernel errors this boot (ACPI/DMAR/brcmfmac/BCM noise is harmless — see README)"
journalctl -k -b -p err --no-pager 2>/dev/null | tail -25

hr "Failed system units (want 0)"
systemctl --failed --no-pager

hr "Camera firmware init (want 'Full memory verification succeeded')"
journalctl -k -b --no-pager 2>/dev/null | grep -E 'facetimehd.*(verification|firmware|1675)' | tail -5

echo
echo "Functional tests (do these manually):"
echo "  camera: ffmpeg -f v4l2 -input_format yuyv422 -video_size 640x480 -i /dev/video0 -frames:v 1 -y /tmp/camtest.jpg"
echo "  speakers: speaker-test -t sine -f 440 -l 1   (listen)"
echo "  mic: arecord -D pipewire -f S16_LE -r 48000 -c 2 -d 3 /tmp/mic.wav   (check non-silent)"
