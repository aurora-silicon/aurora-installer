# CHANGES — sleep/display fix round (2026-10-29, ZCode)

## Problem (user-reported, J616s)

1. After sleep/wake, the panel desyncs: with HDR off there is "haloing", greys are
   darker and effective nits drop to what feels like 10–20 % at 100 % brightness.
   Only sleep/wake 1–2 more times restores it. Worse with HDR off than on.
2. "Sleep" leaves the keyboard backlight lit for ~5 s; wake is delayed and sometimes
   needs the power/Touch ID button even with the lid open.

## Root cause (installer-relevant part)

The DCP keeps stale panel state across suspend until a brightness event re-commits
it — which is exactly why repeated sleep/wakes self-heal. The keyboard backlight is
not cleared at suspend boundary. (The wake-source latency half is kernel-side — see
"not fixed here".)

## Change (in the installer, no hardcoding)

- `fedora/files/aurora-sleep-restore` (NEW): a systemd `system-sleep` hook. Generic
  by design: gated on the Apple device tree, driven only by sysfs globs
  (`/sys/class/backlight/*`, `/sys/class/leds/*::kbd_backlight`), no machine- or
  image-specific values. On `pre` it clears and saves the keyboard backlight; on
  `post` it re-commits every backlight level (with a one-step nudge so a deduping
  driver still re-applies the full brightness/EDR mapping) and restores the keyboard
  backlight.
- `fedora/configure.py`: stages that hook into the image root at
  `usr/lib/systemd/system-sleep/aurora-display-restore` (KIWI `root/` overlay), so
  every future image build ships it. Data lives in `fedora/files/`, not in code.

## Applying to the current install

Run on the Fedora side (one command; decodes and installs the same hook file):

    echo '<base64 — see release notes>' | base64 -d | sudo tee \
      /usr/lib/systemd/system-sleep/aurora-display-restore >/dev/null && \
      sudo chmod +x /usr/lib/systemd/system-sleep/aurora-display-restore && \
      echo "aurora-display-restore installed"

A copy is kept at `~/aurora-audio-dsp/patch-sleep-display.sh` (macOS side) with the
same content plus verification.

## Not fixed here (kernel-side, honest note)

Delayed wake / needing the power button despite lid open is a wake-source question
(s2idle wake from lid/keyboard/Touch ID on t6041). That lives in the kernel; the
stock image kernel predates Ryan's `integration/aurora` work, so retest after the
next kernel update from his branch. This hook removes the two symptoms that are
userspace-fixable (backlight at suspend, panel state at resume).

## Backups

- `~/aurora-backup-pre-sleepfix-20261029-212322.zip` — installer tree state before
  this change (git diff + status + `fedora/` + J616sOverride listing/hashes).
- `~/aurora-backup-sleepfix-<ts>.zip` — after this change (same contents + CHANGES.md
  + the staged hook file).

## Rollback

Delete `/usr/lib/systemd/system-sleep/aurora-display-restore` on the Fedora side, or
revert `fedora/configure.py` + `fedora/files/` from the pre-backup zip. Nothing else
is touched; no boot files involved.
