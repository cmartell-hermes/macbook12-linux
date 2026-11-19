# MacBook 12-inch (MacBook9,1 / A1534, 2016) on Linux

Working fixes for the three things that break out of the box on the 12-inch
MacBook: **webcam, audio, and suspend**. Tested on Manjaro (kernel 7.2.9,
November 2026); the steps are distro-generic apart from package names.

| Subsystem | Status | Fix |
|---|---|---|
| FaceTime HD camera | ✅ 640×480 YUYV @ 30 fps | patched `facetimehd` DKMS driver |
| Speakers / mic / headphones | ✅ incl. auto-switching | `macbook12-audio-driver` DKMS + WirePlumber soft-volume |
| Suspend / resume | ✅ deep (S3), verified overnight | corrected `systemd-sleep` hook |
| Wi-Fi, keyboard, trackpad, Bluetooth | ✅ mainline | see [other hardware](#other-hardware) |

All three fixes are **kernel-upgrade-sensitive** (out-of-tree DKMS modules).
Both modules ship `AUTOINSTALL=yes`, so DKMS normally rebuilds them
automatically — see [after a kernel upgrade](#after-a-kernel-upgrade).

---

## 1. Camera — FaceTime HD (Broadcom 14e4:1570)

There is no mainline driver yet (staging submissions are under review on
lore.kernel.org). The working solution is
[patjak/facetimehd](https://github.com/patjak/facetimehd) plus a 3-file patch
from [id1man23/macbook12-camera-fix](https://github.com/id1man23/macbook12-camera-fix)
that adds 12-inch support:

- `fthd_drv.c` — DMI detection for 12-inch MacBooks, caps resolution to 640×480
- `fthd_isp.c` — correct crop dimensions and frame timing for the 480p sensor
- `fthd_v4l2.c` — default format 640×480 instead of 1280×720

### Install

1. Install the driver as a DKMS module (on Manjaro/Arch:
   `facetimehd-dkms-git` from AUR, or build patjak's repo manually).
2. Apply the three patched files from the fix repo above into
   `/usr/src/facetimehd-<version>/`.
3. Build and install:

```bash
sudo dkms build   -m facetimehd -v <version> -k $(uname -r) --force
sudo dkms install -m facetimehd -v <version> -k $(uname -r) --force
sudo modprobe facetimehd
```

### Kernel 7.2+ build fix

Kernel 7.2 removed `strncpy`. If the build fails with
`implicit declaration of function 'strncpy'`, edit
`/usr/src/facetimehd-<version>/fthd_v4l2.c` (~line 414) and replace
`strncpy(fmt->description, ...)` with `strscpy(fmt->description, ...)`,
then rebuild.

> Upstream note: patjak/facetimehd **0.7.2+** builds on 7.2 kernels officially
> and adds 12-inch support (targeting MacBook8,1 first). It's a candidate
> upgrade path — test on your exact model before switching, and keep the
> patched 0.7.0.x as fallback.

### Verify

```bash
v4l2-ctl --list-formats-ext -d /dev/video0     # should list 640x480 YUYV
ffmpeg -f v4l2 -input_format yuyv422 -video_size 640x480 \
       -i /dev/video0 -frames:v 1 -y /tmp/camtest.jpg
```

Open the JPEG — a real image means the whole pipeline works.

### Known limitations

- `Direct firmware load for facetimehd/1675_01XX.dat failed (-2)` in dmesg is
  **harmless** — a missing per-unit calibration file; the image is slightly
  darker/noisier than macOS but fully usable. Newer upstream makes it non-fatal.
- AUR updates of `facetimehd-dkms-git` overwrite the patched source — re-apply
  the patch (and the `strscpy` fix) after every update.

---

## 2. Audio — Cirrus Logic CS4208 (speakers, mic, headphone jack)

The stock `snd_hda_codec_cs420x` driver misdetects this machine: the speaker
amp is never enabled, so you get **no speaker sound**. The fix is
[leifliddy/macbook12-audio-driver](https://github.com/leifliddy/macbook12-audio-driver),
which replaces the codec module via DKMS (`macbook12-audio-driver/0.1`).
Current upstream supports speakers, internal mic, and headphone jack with
auto-switching. (Old snapshots were playback-only — if your mic is missing,
your installed version is stale; upgrade.)

### Install

```bash
git clone https://github.com/leifliddy/macbook12-audio-driver
cd macbook12-audio-driver
sudo ./install.cirrus.driver.sh -i
```

The first build per kernel downloads the kernel.org source tarball
(SHA-256 verified, cached in `/var/cache/macbook12-audio-driver`).

> If you previously installed the older module named `macbook12-audio`,
> remove it explicitly first (`sudo dkms remove macbook12-audio/<ver> --all`)
> — old and new fight over the same `.ko` otherwise.

### Required: software volume (WirePlumber 0.5+)

The internal speaker has **no hardware volume control** — PipeWire must apply
volume in software, or the desktop volume slider does nothing. Install
[`config/51-macbook-cs4208-softvol.conf`](config/51-macbook-cs4208-softvol.conf)
(also in the driver repo under `contrib/wireplumber/`) to
`/etc/wireplumber/wireplumber.conf.d/`, then:

```bash
systemctl --user restart wireplumber
amixer -c0 sset Master 100% unmute
sudo alsactl store
```

If your audio controller is not at PCI `00:1f.3`, adjust `device.name` in the
conf (find it with `wpctl status`).

### Reload without rebooting

PipeWire holds the device, so stop consumers **and their activation sockets**
first, or socket activation re-grabs the card mid-reload:

```bash
systemctl --user stop pipewire-pulse.socket pipewire.socket \
    pipewire-pulse.service pipewire.service wireplumber.service
sudo modprobe -r snd_hda_intel snd_hda_codec_cs420x
sudo modprobe snd_hda_intel
amixer -c0 sset Master 100% unmute && sudo alsactl store
systemctl --user start pipewire.socket pipewire-pulse.socket wireplumber.service
```

### Verify

```bash
wpctl status                       # must show a sink AND a source
speaker-test -t sine -f 440 -l 1   # or: aplay any wav — listen for it
arecord -D pipewire -f S16_LE -r 48000 -c 2 -d 3 /tmp/mic.wav
# then check the recording isn't silent (RMS near zero = dead mic)
```

### Harmless log noise

dmesg will still show `speaker_outs=0` and `picked fixup (empty)` for the
CS4208 — **normal for this driver**. It initializes the codec via custom
`setup_a1534`/`play_a1534` verbs, not standard autoconfig. Judge by the
functional test, not the log aesthetics.

---

## 3. Suspend / resume — use deep (S3), not s2idle

This MacBook **hangs in s2idle** (suspend-to-idle): the journal shows
`PM: suspend entry (s2idle)` followed by a fresh boot with no resume lines —
i.e. it hung and had to be force-rebooted. **Deep (S3) is the reliable mode**,
verified including a ~20-hour overnight suspend with a clean wake.

Install [`scripts/sleep-config`](scripts/sleep-config) to
`/usr/lib/systemd/system-sleep/sleep-config` (mode 755). It:

- forces `deep` before every suspend,
- keeps **LID0** (lid-open) wake enabled,
- disables **XHC1** (USB) wake to prevent instant re-wake — idempotently,
  because writing a name to `/proc/acpi/wakeup` *toggles* it.

Also install [`scripts/wifi-resume`](scripts/wifi-resume) (same directory) if
you get dead Wi-Fi after resume — it turns off `power_save` on `wlp2s0` post-resume.
(This is a common community snippet for brcmfmac resume issues, not original to
this repo; adjust the interface name if yours differs.)

### Pitfalls that cost us debugging time

- **systemd-sleep executes EVERY executable file in the hook directory,
  alphabetically.** An executable backup left in the dir (`sleep-config.bak`)
  ran *after* the new hook and undid it. Keep backups elsewhere
  (e.g. `/var/backups/`).
- **The desktop power manager can mask your test.** On XFCE,
  `lid-action-on-ac` unset = do nothing on lid close while on AC. Check
  `xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lid-action-on-ac`
  (set to `1` = suspend) before trusting a "closed the lid" test.
- Verify the mode actually used via the journal, not just
  `/sys/power/mem_sleep` beforehand:

```bash
cat /sys/power/mem_sleep                      # should show [deep]
journalctl -b -1 -g 'PM: suspend entry|Waking up|suspend exit'
# healthy: suspend entry (deep) -> Waking up from system sleep state S3 -> suspend exit
```

Optional hardening: `mem_sleep_default=deep` on the kernel cmdline (not
required if the hook is installed). If deep ever hangs, suspect the facetimehd
PCIe camera not resuming cleanly — test by unloading it before suspend.

---

## After a kernel upgrade

DKMS with `AUTOINSTALL=yes` should rebuild both modules automatically. Check:

```bash
uname -r
dkms status
# every module must say "installed" for the RUNNING kernel —
# "installed" for an older kernel, or "added", means it won't load
```

Make sure headers match (`linuxNN-headers` on Manjaro, `linux-headers-$(uname -r)`
on Debian/Ubuntu). Manual rebuild:

```bash
# camera
sudo dkms build   -m facetimehd -v <version> -k $(uname -r) --force
sudo dkms install -m facetimehd -v <version> -k $(uname -r) --force
# audio
cd macbook12-audio-driver && sudo ./install.cirrus.driver.sh -i
```

On build failure read `/var/lib/dkms/<name>/<ver>/build/make.log` — new kernels
remove APIs (the `strncpy` → `strscpy` change above is one example). Check the
upstream repo's latest release first; it may already fix the build officially.

Run [`scripts/healthcheck.sh`](scripts/healthcheck.sh) for a full read-only
verification sweep (modules, devices, PipeWire graph, sleep mode, journal errors).

---

## Other hardware

All working with mainline drivers on this unit:

- **Wi-Fi** — BCM4350 (`brcmfmac`). Missing CLM blob + 2015 firmware may limit
  some 5 GHz/DFS channels; cosmetic, not broken.
- **Keyboard / trackpad** — Apple SPI (`applespi`, mainline). Keyboard
  backlight: `spi::kbd_backlight`; display backlight: `acpi_video0`.
- **Bluetooth** — BCM4350C0 (UART). Works once unblocked
  (`rfkill unblock bluetooth`). Boot warnings `BCM.hcd not found`,
  `failed to write update baudrate (-16)`, `No reset resource` are
  **harmless** — firmware is in ROM. Do **not** fetch random `.hcd` files
  because of them. If it ever genuinely fails:
  [leifliddy/macbook12-bluetooth-driver](https://github.com/leifliddy/macbook12-bluetooth-driver).

### Harmless boot-log noise (don't chase these)

| Message | Why it's fine |
|---|---|
| ACPI `AE_ALREADY_EXISTS` SSDT / `\_PR.CPUx.GCAP` errors | Apple firmware quirks; no functional impact |
| `DMAR: Failed to find handle for ACPI object` | firmware describes devices oddly; harmless |
| `brcmfmac: no clm_blob / txcap_blob available` | limits some channels only |
| `Bluetooth: BCM.hcd not found`, baudrate `-16` | firmware in ROM, BT works |
| `facetimehd/1675_01XX.dat failed (-2)` | missing calibration file, slightly darker image |
| `CS4208: speaker_outs=0 / picked fixup (empty)` | driver uses custom codec verbs, audio works |

---

## Credits & attribution

This repo is a guide plus small helper scripts; the actual drivers are other
people's work:

- [patjak/facetimehd](https://github.com/patjak/facetimehd) (GPL-2.0) — the
  reverse-engineered camera driver this guide builds on.
- [id1man23/macbook12-camera-fix](https://github.com/id1man23/macbook12-camera-fix)
  (GPL-2.0) — the three patched source files (`fthd_drv.c`, `fthd_isp.c`,
  `fthd_v4l2.c`) that make the camera work on 12-inch models.
- [leifliddy/macbook12-audio-driver](https://github.com/leifliddy/macbook12-audio-driver)
  (no license declared) — the CS4208 audio driver.
  [`config/51-macbook-cs4208-softvol.conf`](config/51-macbook-cs4208-softvol.conf)
  in this repo is reproduced **verbatim** from its `contrib/wireplumber/`
  directory, with attribution; all rights to it remain with that author.
- `scripts/sleep-config` — written for this project (deep-sleep + idempotent
  wake-source handling). `scripts/wifi-resume` — a common community snippet
  for brcmfmac dead-Wi-Fi-after-resume. `scripts/healthcheck.sh` — original to
  this repo.
- The linux-on-macbook community whose notes made this possible.

Fixes assembled and verified on a MacBook9,1 running Manjaro, November 2026.
Issues and corrections welcome — especially reports from MacBook8,1 (2015)
and MacBook10,1 (2017) owners.

## License

MIT covers the original scripts and documentation in this repo only.
Third-party material keeps its upstream terms: facetimehd and the camera patch
are GPL-2.0; macbook12-audio-driver (including the reproduced softvol config)
has no declared license — all rights remain with its author, and it is
reproduced here with attribution for convenience. If you redistribute the
drivers themselves, get them from upstream.
