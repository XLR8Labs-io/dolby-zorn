#!/system/bin/sh
# Install-time checks. The payload is zorn's own stock firmware, so refuse to
# install anywhere else rather than overlay another device's vendor libraries.

SKIPUNZIP=0

ui_print " "
ui_print "  Lunaris Dolby for K80/F7 Pro (zorn)"
ui_print "  by Merajul Islam"
ui_print " "

# Do not trust a single property. ROMs disagree about which partition-scoped
# device name they set: Infinity-X puts zorn in ro.product.vendor.device,
# while PixelOS follows Xiaomi's convention and reports mivendor there
# (miproduct / misystem likewise), keeping zorn only in ro.product.device and
# the bootimage/attestation names. ro.boot.* comes from the bootloader and is
# ROM-independent, so it is checked first.
DEV=""
for p in ro.boot.product.hardware.sku \
         ro.product.device \
         ro.product.bootimage.device \
         ro.product.device_for_attestation \
         ro.product.vendor.device \
         ro.product.system.device \
         ro.product.product.device \
         ro.product.odm.device \
         ro.vendor.product.device; do
    v=$(getprop "$p" 2>/dev/null)
    [ -n "$v" ] && [ -z "$DEV" ] && DEV="$v"
    if [ "$v" = "zorn" ]; then
        ui_print "- Device: zorn  OK  ($p)"
        DEV="zorn"
        break
    fi
done

if [ "$DEV" != "zorn" ]; then
    ui_print "! This device reports: ${DEV:-unknown}"
    ui_print "! These libraries come from zorn's stock firmware and"
    ui_print "! will not work on other devices."
    abort   "! Aborting."
fi

# Name checks can still be fooled by a spoofed build.prop, and overlaying
# these libraries onto a device without the Dolby vendor stack would be
# pointless at best. Require the stack to actually be there.
if [ ! -f /vendor/lib64/soundfx/libhwdap.so ]; then
    ui_print "! No Dolby stack found at /vendor/lib64/soundfx/libhwdap.so."
    ui_print "! This ROM does not ship zorn's Dolby vendor blobs."
    abort   "! Aborting."
fi
ui_print "- Dolby vendor stack present  OK"

# A truncated download would overlay a broken library over a working vendor
# partition, so verify the payload before letting it be mounted at boot.
HWDAP="$MODPATH/payload/vendor/lib64/soundfx/libhwdap.so"
if [ ! -f "$HWDAP" ]; then
    abort "! Payload missing libhwdap.so - bad zip."
fi
SZ=$(stat -c %s "$HWDAP" 2>/dev/null)
if [ "$SZ" != "207344" ]; then
    abort "! libhwdap.so is $SZ bytes, expected 207344 - bad zip."
fi

C2SVC="$MODPATH/payload/vendor/bin/hw/vendor.dolby.media.c2@1.0-service"
SZ=$(stat -c %s "$C2SVC" 2>/dev/null)
if [ "$SZ" != "11528" ]; then
    abort "! codec service is $SZ bytes, expected 11528 - bad zip."
fi
ui_print "- Payload verified"

ui_print " "
ui_print "- What this fixes:"
ui_print "    This ROM ships a libhwdap.so built against a different"
ui_print "    libstagefright_foundation. Creating the Dolby effect"
ui_print "    segfaults the audio HAL, so Dolby never starts. The"
ui_print "    stock Dolby libraries are restored as a matched set."
ui_print " "
ui_print "- Nothing is written to /vendor or /product."
ui_print "  Files are overlaid at boot and vanish when the module"
ui_print "  is removed. Both partitions stay read-only."
ui_print " "
ui_print "- After reboot, open the Dolby app to enable it."
ui_print "  Mount log: /data/adb/dolbyzorn.log"
ui_print " "

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh"       0 0 0755
