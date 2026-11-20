# Changelog

## v1.2

Fixes installation on ROMs that do not put the device name in
`ro.product.vendor.device`.

* The installer and the boot-time mount script checked that one property
  only. Infinity-X sets it to `zorn`, so it passed there — but PixelOS
  follows Xiaomi's per-partition naming and reports `mivendor`, aborting the
  install with *"This device reports: mivendor"*. Both now check nine
  identity properties, starting with `ro.boot.product.hardware.sku`, which
  the bootloader supplies and no ROM can change.
* The same bug was present in `post-fs-data.sh`, not just the installer.
  Fixing only the installer would have produced a module that installed
  successfully and then silently mounted nothing on every boot.
* Added a second precondition: `/vendor/lib64/soundfx/libhwdap.so` must
  exist. A spoofed build.prop can defeat a name check; this cannot.

Verified on VoltageOS (matched on `ro.boot.product.hardware.sku`). The Dolby
payload is unchanged from v1.1.

## v1.1

Restores the stock Dolby codec service.

* `vendor.dolby.media.c2@1.0-service` is 11,528 bytes in stock firmware and
  68,049 here, while all three of its codec libraries are untouched — the
  same substitution pattern as `libhwdap.so`. It SIGSEGVs at boot in
  `BnHwBase::_hidl_interfaceChain` with a null `getImpl()`, twice per boot,
  until init's third restart sticks.
* Restoring the stock binary takes this to **zero crashes on Infinity-X**.
  It does **not** help on VoltageOS (2 before, 2 after), which ships a
  different `android.hardware.media.c2@1.0.so`; there the race resurfaces in
  `_hidl_createInterface`. Kept because it is a clear win on one ROM and
  measurably neutral on the other.
* `overlay_add` now takes a file mode and a separate directory label.
  `/vendor/bin/hw` must stay `vendor_file` while the binary inside it is
  `mediacodec_exec`, and the merged directory takes the upper's label — so
  labelling both the same would have relabelled every vendor HAL's directory.
* Dropped the `system_ext` Dolby libraries from the payload. They were added
  while testing whether stock MiSound could drive the effect; it cannot
  (`NoClassDefFoundError: Lmiui/os/Build;` — it needs the MIUI framework),
  and the shipped client never loads them.

## v1.0

First working build.

* **Root cause:** these ROMs ship a `libhwdap.so` built against a different
  `libstagefright_foundation` — a library stock zorn vendor does not contain
  at all. Creating the Dolby effect hands `QdspDriver`'s event thread a
  garbage `ALooper` pointer, segfaulting the entire vendor audio HAL.
  AudioFlinger returns `DEAD_OBJECT`, every output thread reports
  `0 Effect Chains`, and Dolby never works.
* Restoring `libhwdap.so` alone starts Dolby but leaves profile switching
  failing with `doCommit() Failed to set parameters to DAP module in real
  time`, because `libdlbpreg.so` — the parameter registry — is still the
  ROM's build. Restoring all four as a matched set fixes both.
* The module mounts itself. KernelSU Next 3.4.2 performs no module mounting
  on this device: its boot log goes straight from running `post-fs-data.sh`
  scripts to finishing, and `/proc/1/mountinfo` shows zero module mounts.
* Overlay upperdirs live on tmpfs. `/data` is fscrypt-encrypted and the
  kernel rejects it outright — `overlayfs: filesystem on ... not supported`.
* Ships LunarisDolby as a priv-app, since something has to instantiate the
  effect. Its upstream `action.sh` launched `.MainActivity`, which does not
  exist in the APK; the real entry point is `.ui.DolbyActivity`.
