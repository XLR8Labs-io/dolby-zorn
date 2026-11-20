#!/system/bin/sh
# Mounts stock HyperOS Dolby components into the read-only system partitions.
#
# KernelSU Next 3.4.2 on this device performs no module mounting at all - the
# boot log goes straight from running post-fs-data.sh scripts to finishing,
# and /proc/1/mountinfo shows no module mounts. So this module does its own.
#
# Overlay upperdir must live on tmpfs: /data is fscrypt-encrypted and the
# kernel rejects it with "overlayfs: filesystem on ... not supported".

MODDIR=${0%/*}
STAGE=/dev/dolbyzorn
LOG=/data/adb/dolbyzorn.log

log() { echo "$(date '+%H:%M:%S') $*" >>"$LOG"; }

: >"$LOG"
log "post-fs-data start, MODDIR=$MODDIR"

# overlay_add <target-dir> <payload-dir> <file-label> [file-mode] [dir-label]
#
# Adds the payload's entries to a read-only directory without touching the
# underlying partition. Lower stays erofs; our files come from the tmpfs upper.
#
# dir-label defaults to file-label, which is right wherever a directory and
# its contents share a context. /vendor/bin/hw is the exception: the binary
# inside is mediacodec_exec but the directory must stay vendor_file, since
# the merged directory takes the upper's label and every other vendor HAL
# lives there too. File mode defaults to 0644; executables pass 0755.
overlay_add() {
    target=$1
    src=$2
    label=$3
    fmode=${4:-0644}
    dlabel=${5:-$3}
    name=$(echo "$target" | sed 's|^/||; s|/|_|g')
    up=$STAGE/up/$name
    wk=$STAGE/wk/$name

    if [ ! -d "$target" ]; then
        log "SKIP $target (not present on this ROM)"
        return 1
    fi
    # Stacking a second overlay on the same target would hide the first.
    if grep -q "^dolbyzorn $target overlay" /proc/mounts 2>/dev/null; then
        log "SKIP $target (already mounted)"
        return 0
    fi
    if [ ! -d "$src" ]; then
        log "SKIP $target (payload $src missing)"
        return 1
    fi

    mkdir -p "$up" "$wk" || { log "FAIL $target (mkdir staging)"; return 1; }
    cp -a "$src"/. "$up"/ || { log "FAIL $target (copy payload)"; return 1; }

    chown -R 0:0 "$up"
    find "$up" -type d -exec chmod 0755 {} +
    find "$up" -type f -exec chmod "$fmode" {} +
    chcon -R "$label" "$up" || log "WARN $target (chcon failed)"
    # Restore directory labels from the live target so the merged directory
    # keeps the context the system expects.
    # Do not probe the live label with `stat -c %C` here: ksud puts BusyBox
    # ahead of toybox on PATH at post-fs-data, and BusyBox stat echoes an
    # unsupported %C back as the literal string "C".
    find "$up" -type d -exec chcon "$dlabel" {} + 2>/dev/null \
        || log "WARN $target (dir relabel to $dlabel failed)"

    if mount -t overlay dolbyzorn \
        -o "lowerdir=$target,upperdir=$up,workdir=$wk" "$target"; then
        log "OK   $target  added: $(ls "$up" | tr '\n' ' ')"
    else
        log "FAIL $target (overlay mount)"
        return 1
    fi
}

# The vendor libraries below are zorn's own, pulled from its stock firmware.
# Mounting them over a different device's vendor would be actively harmful, so
# refuse to touch anything unless this really is zorn.
# Which property carries the device name depends on the ROM: Infinity-X sets
# ro.product.vendor.device=zorn, PixelOS reports mivendor there and keeps zorn
# in ro.product.device. Checking only one aborted every mount on PixelOS.
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
    [ "$v" = "zorn" ] && { DEV=zorn; break; }
done

if [ "$DEV" != "zorn" ]; then
    log "ABORT: device reports '${DEV:-unknown}', expected zorn. Nothing mounted."
    exit 0
fi

if [ ! -f /vendor/lib64/soundfx/libhwdap.so ]; then
    log "ABORT: no Dolby stack in /vendor/lib64/soundfx. Nothing mounted."
    exit 0
fi

mkdir -p "$STAGE/up" "$STAGE/wk"

# Infinity-X replaced four libraries of the Dolby stack with builds that do
# not match this device's vendor:
#
#   soundfx/libhwdap.so   207344 -> 298385   the DAP effect itself
#   soundfx/libdlbvol.so   15264 ->  67721   Dolby volume
#   libdlbpreg.so          28336 ->  72505   parameter registry
#   libdlbdsservice.so    471408 -> 610577   DS service, used by the DMS HAL
#
# The mismatched libhwdap segfaulted the audio HAL (garbage ALooper pointer in
# QdspDriver's EventHandler). Restoring it fixed that, but leaving libdlbpreg
# mismatched left profile changes failing with "Failed to set parameters to
# DAP module in real time". The stack has to be restored as a matched set.
#
# One overlay on lib64 covers both levels: overlayfs merges the soundfx
# subdirectory with the lower one rather than shadowing it.
overlay_add /vendor/lib64 "$MODDIR/payload/vendor/lib64" u:object_r:vendor_file:s0

# The Dolby Codec2 service binary got the same treatment: 11528 bytes in stock
# firmware, 68049 here, while all three of its codec libraries are untouched.
# It SIGSEGVs at boot in BnHwBase::_hidl_interfaceChain with a null getImpl(),
# twice per boot, before init's third restart finally sticks. Executable, so
# 0755; the file is mediacodec_exec while /vendor/bin/hw stays vendor_file.
overlay_add /vendor/bin/hw "$MODDIR/payload/vendor/bin/hw" \
            u:object_r:mediacodec_exec:s0 0755 u:object_r:vendor_file:s0

# A client is needed to instantiate the effect. Lunaris as a priv-app, which
# is what its own installer intended.
overlay_add /product/priv-app        "$MODDIR/payload/product/priv-app"        u:object_r:system_file:s0
overlay_add /product/etc/permissions "$MODDIR/payload/product/etc/permissions" u:object_r:system_file:s0
overlay_add /product/etc/sysconfig   "$MODDIR/payload/product/etc/sysconfig"   u:object_r:system_file:s0

log "post-fs-data done"
