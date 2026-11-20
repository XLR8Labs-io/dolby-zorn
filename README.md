# Dolby Atmos for Redmi K80 / POCO F7 Pro (zorn)

Restores working Dolby Atmos on custom AOSP ROMs for **zorn**.

If you flashed a custom ROM and Dolby is simply dead — no effect, no sound
change, nothing in the app — this fixes it. It is not a tuning mod.

---

## The problem

zorn's stock firmware ships a complete Dolby stack in `/vendor`: the DAP
effect, the DMS HAL, the tuning XMLs, and the effect registration. Custom ROMs
keep almost all of it. But several of them ship **replacement builds of four
Dolby libraries plus the codec service**, and those replacements do not match
the rest of the device:

| file | stock zorn | shipped by Infinity-X / PixelOS |
|---|---:|---:|
| `vendor/lib64/soundfx/libhwdap.so` | 207,344 | 298,385 |
| `vendor/lib64/soundfx/libdlbvol.so` | 15,264 | 67,721 |
| `vendor/lib64/libdlbpreg.so` | 28,336 | 72,505 |
| `vendor/lib64/libdlbdsservice.so` | 471,408 | 610,577 |
| `vendor/bin/hw/vendor.dolby.media.c2@1.0-service` | 11,528 | 68,049 |

The other 18 effect libraries in `soundfx` are byte-identical to stock, so
only these were swapped.

`libhwdap.so` is the one that matters. The ROM's build expects a different
`libstagefright_foundation` — stock zorn vendor does not ship that library at
all, the ROMs add it — so the moment anything creates the Dolby effect, its
`QdspDriver` event thread dereferences a garbage `ALooper` pointer and takes
the **entire audio HAL** down with it:

```
F libc: Fatal signal 11 (SIGSEGV), SEGV_MAPERR, fault addr 0x74ff00000001b102
        in tid 15950 (QdspDriver Even), pid 1588 (audio.service)
  #00 /vendor/lib64/libstagefright_foundation.so (android::ALooper::loop()+152)
```

AudioFlinger then returns `DEAD_OBJECT` to the caller and the Dolby app
crashes on top of it. Every output thread reports `0 Effect Chains` forever.

Restoring `libhwdap.so` alone makes Dolby start, but profile switching then
fails with `doCommit() Failed to set parameters to DAP module in real time`,
because `libdlbpreg.so` — the parameter registry it talks to — is still the
ROM's build. **The stack has to be restored as a matched set.**

## What this module does

* Overlays the five stock Dolby files back over `/vendor`, read-only.
* Installs a Dolby control app as a priv-app so something can drive the effect.
* Writes nothing to `/vendor` or `/product`. Both stay read-only EROFS; the
  files are mount-time overlays that vanish when the module is removed.

### It mounts itself

KernelSU Next 3.4.2 on this device performs **no module mounting at all** —
its boot log goes straight from running `post-fs-data.sh` scripts to
finishing, and `/proc/1/mountinfo` shows zero module mounts. So the module
does its own, in [`module/post-fs-data.sh`](module/post-fs-data.sh).

Two things that are not obvious there, both learned the hard way:

* **The overlay upperdir must be on tmpfs.** `/data` is fscrypt-encrypted and
  the kernel refuses it outright: `overlayfs: filesystem on ... not supported`.
* **Do not probe SELinux labels with `stat -c %C`.** ksud puts BusyBox ahead
  of toybox on `PATH` during post-fs-data, and BusyBox's `stat` does not
  support `%C` — it silently echoes back the literal string `C`. Directory
  labels are passed explicitly instead.

## Supported

* **Device:** zorn only — Redmi K80 / POCO F7 Pro. Checked against nine
  identity properties, because ROMs disagree about which one carries the
  device name (Infinity-X sets `ro.product.vendor.device=zorn`; PixelOS
  reports `mivendor` there and keeps `zorn` in `ro.product.device`).
* **Root:** KernelSU / KernelSU Next. Magisk layout is honoured but untested.
* **Verified on:** Infinity-X (Android 17), VoltageOS (Android 17).
* **Expected to work on:** PixelOS — it ships byte-identical Dolby libraries —
  but this has not been confirmed on hardware.

### Known issue

`vendor.dolby.media.c2@1.0-service`, the Dolby **video** codec service,
SIGSEGVs at boot on these ROMs and restarts itself. Restoring the stock binary
fixes it on Infinity-X (2 crashes per boot → 0) but **not on VoltageOS**
(2 → 2), because VoltageOS ships a different `android.hardware.media.c2@1.0.so`
and the race resurfaces in `_hidl_createInterface`. The service recovers on
its own and all 11 Dolby decoders stay available, so this is cosmetic. Fixing
it properly would mean replacing a library every codec service on the device
shares — not worth the risk of breaking all media playback.

## Building

The Dolby libraries are proprietary Dolby code licensed to Xiaomi and are
**not** in this repository. You extract them from stock zorn firmware, which
you already own for your own device.

You need:

1. **Stock zorn firmware** — a HyperOS fastboot package. The build script
   wants either the directory containing its `super.img.*` chunks, or an
   already-extracted `vendor.img`.
2. **LunarisDolby.apk** — the control app, by @montfort_1607.

   It is **not** redistributed here. Its upstream repositories declare no
   licence at all, which means all rights reserved by default, so shipping
   the APK would be on weaker ground than the Dolby libraries. Three ways to
   obtain it, easiest first:

   * **Pull it off a ROM that already ships it.** Many AOSP ROMs include it:
     `adb shell find /product /system_ext -iname 'LunarisDolby*.apk'`, then
     `adb pull` the result.
   * **Take it from a published LunarisDolby module zip.** This module is
     based on the *LunarisDolby [Port v2.0]* release posted to Telegram:
     <https://t.me/garnetglobal/656>. The APK sits at
     `system/product/priv-app/LunarisDolby/LunarisDolby.apk` inside the zip.
   * **Build it from source** —
     <https://github.com/project-sm7435/packages_apps_LunarisDolby>.
     Note it is a Soong package (`Android.bp`), not a Gradle project, so it
     builds inside an AOSP tree rather than standalone.

   Any recent build works; the module only needs the package to exist as a
   priv-app so something can instantiate the Dolby effect.

3. `simg2img` and `lpunpack` (Arch: `android-tools`), plus either
   `erofs-utils` or a desktop with `udisksctl` for rootless mounting.

```bash
./build.sh --firmware /path/to/stock_rom/images --apk /path/to/LunarisDolby.apk
```

This produces `dist/DolbyZorn-<version>.zip`. The script verifies every
extracted library against its expected byte size and refuses to build if the
firmware is wrong, so a bad download cannot turn into a module that overlays a
broken library onto a working vendor partition.

## Installing

Flash the zip in the KernelSU manager and reboot. Then open the Dolby app and
turn it on.

Check `/data/adb/dolbyzorn.log` — five `OK` lines means mounting worked:

```
OK   /vendor/lib64             added: libdlbdsservice.so libdlbpreg.so soundfx
OK   /vendor/bin/hw            added: vendor.dolby.media.c2@1.0-service
OK   /product/priv-app         added: LunarisDolby
OK   /product/etc/permissions  added: privapp-permissions-dolby.xml
OK   /product/etc/sysconfig    added: hiddenapi-whitelist-dolby.xml
```

To confirm Dolby is actually attached, not merely installed:

```bash
adb shell su -c 'dumpsys media.audio_flinger | grep -A3 "Effect ID"'
```

You want `name: DAP_offload`, `implementor: Dolby Laboratories`, `Enabled: y`.

## Troubleshooting

**Installer aborts with `This device reports: ...`** — your ROM uses a device
name none of the nine checked properties expose. Open an issue with that exact
string and the output of `getprop | grep -i device`.

**Log says `ABORT: no Dolby stack in /vendor/lib64/soundfx`** — your ROM
stripped Dolby from vendor entirely. This module cannot help; it restores
mismatched libraries, it does not add missing ones.

**Everything mounts but there is no sound change** — collect evidence with
[`tools/dolby-probe.sh`](tools/dolby-probe.sh), a read-only diagnostic that
dumps the Dolby props, effect libraries, effect registration, AudioFlinger's
live effect table and recent SELinux denials:

```bash
adb push tools/dolby-probe.sh /data/local/tmp/
adb shell su -c 'sh /data/local/tmp/dolby-probe.sh' > probe.txt
```

## For ROM maintainers

The cleanest fix is upstream, not here. ROMs hit this by adopting a generic
`hardware/dolby` tree instead of keeping the device's own vendor blobs, and
several incompatible Dolby builds are in circulation:

| | zorn stock | shipped by these ROMs | [Ghosuto/hardware_dolby][hw] |
|---|---:|---:|---:|
| `libhwdap.so` | 207,344 | 298,385 | 195,744 |
| `libdlbpreg.so` | 28,336 | 72,505 | 24,208 |
| `libdlbdsservice.so` | 471,408 | 610,577 | 459,136 |
| `libdlbvol.so` | 15,264 | 67,721 | 15,264 |

Mixing builds is what breaks it. The libraries talk to each other through
private interfaces, so `libhwdap.so` from one set and `libdlbpreg.so` from
another will load, register, and then fail — either by segfaulting the audio
HAL outright or by silently dropping DSP parameter commits.

Two specifics from `hardware/dolby`'s `dolby.mk` that explain the crash:

* It adds **`libstagefright_foundation-v33`** to `PRODUCT_PACKAGES`. Stock
  zorn vendor contains no `libstagefright_foundation` at all — verified
  against the firmware. Dolby libraries built against that shim, dropped onto
  a device whose vendor lacks it, are what hands `QdspDriver` a garbage
  `ALooper` pointer.
* It sets `ro.vendor.dolby.dax.version=DAX3_3.7.0.8_r1`. zorn runs
  **DAX3_3.8.5.20_r1** — a different DAX generation, so these are not
  drop-in replacements for each other in either direction.

It also copies its own `configs/dax/dax-default.xml` over
`vendor/etc/dolby/dax-default.xml`, replacing the device's speaker tuning
with a generic one. Worth checking if your build sounds wrong: zorn's stock
file is 91,440 bytes, and its spatializer counterpart 23,737.

If your tree targets zorn, ship the device's own blobs as a set. If you need
a generic tree, ship all of it consistently and do not mix in per-device
libraries. Note that `hardware/dolby` also carries `libswdap.so`, a software
DAP that zorn's stock firmware does not include — so a device whose config
expects the hardware DAP will not necessarily behave the same way with it.

[hw]: https://github.com/Ghosuto/hardware_dolby

## Credits

* **@montfort_1607** (Telegram) — author of the *LunarisDolby [Port v2.0]*
  module this one is based on: <https://t.me/garnetglobal/656>. Its
  LunarisDolby app is shipped here as the Dolby UI.
* LunarisDolby app source:
  [project-sm7435/packages_apps_LunarisDolby](https://github.com/project-sm7435/packages_apps_LunarisDolby).
* ROM-side Dolby packaging: [Ghosuto/hardware_dolby][hw].
* Dolby libraries: Dolby Laboratories, via Xiaomi's zorn firmware.

What this project adds on top of that base is the diagnosis and the fix for
the mismatched vendor libraries, plus self-mounting for KernelSU builds that
do not mount modules.

## Licence

[MIT](LICENSE), covering the scripts and packaging in this repository only —
not the Dolby libraries and not the LunarisDolby app. "Dolby" and "Dolby
Atmos" are trademarks of Dolby Laboratories. Not affiliated with Dolby or
Xiaomi.
