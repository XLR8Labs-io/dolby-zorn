#!/usr/bin/env bash
#
# Builds the flashable module.
#
# The five Dolby libraries this module restores are proprietary Dolby code
# licensed to Xiaomi, so they are not committed to this repository. They are
# extracted here from stock zorn firmware, which you already own for your own
# device. The LunarisDolby app is likewise supplied by you rather than vendored.
#
#   ./build.sh --firmware /path/to/stock_rom/images --apk /path/to/LunarisDolby.apk
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$REPO/build"
OUT="$REPO/dist"
FIRMWARE=""
APK=""

# Sizes are the integrity check that matters: a short download or the wrong
# device's firmware produces a module that overlays a broken library onto a
# working vendor partition. Taken from zorn HyperOS OS3.0.309.0.WOKCNXM.
declare -A WANT=(
  [lib64/soundfx/libhwdap.so]=207344
  [lib64/soundfx/libdlbvol.so]=15264
  [lib64/libdlbpreg.so]=28336
  [lib64/libdlbdsservice.so]=471408
  [bin/hw/vendor.dolby.media.c2@1.0-service]=11528
)

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
say() { printf '  %s\n' "$*"; }

usage() {
  cat <<EOF
usage: ./build.sh --firmware <path> --apk <path> [--out <dir>]

  --firmware  Either a directory holding stock super.img.* sparse chunks,
              or a single already-extracted vendor.img.
  --apk       LunarisDolby.apk. See README for where to obtain it.
  --out       Output directory (default: dist/)

Produces dist/DolbyZorn-<version>.zip, flashable in KernelSU / Magisk.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --firmware) FIRMWARE="${2:-}"; shift 2 ;;
    --apk)      APK="${2:-}";      shift 2 ;;
    --out)      OUT="${2:-}";      shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -n "$FIRMWARE" ] || { usage; die "--firmware is required"; }
[ -n "$APK" ]      || { usage; die "--apk is required"; }
[ -f "$APK" ]      || die "APK not found: $APK"

VERSION=$(sed -n 's/^version=//p' "$REPO/module/module.prop")
[ -n "$VERSION" ] || die "could not read version= from module/module.prop"

rm -rf "$BUILD"
mkdir -p "$BUILD" "$OUT"

# ---------------------------------------------------------------- vendor.img
if [ -d "$FIRMWARE" ]; then
  shopt -s nullglob
  chunks=("$FIRMWARE"/super.img.*)
  shopt -u nullglob
  [ ${#chunks[@]} -gt 0 ] || die "no super.img.* chunks in $FIRMWARE"
  command -v simg2img >/dev/null || die "simg2img not found (install android-tools)"
  command -v lpunpack >/dev/null || die "lpunpack not found (install android-tools)"

  say "joining ${#chunks[@]} sparse chunks (needs ~12 GB free, takes a minute)"
  mapfile -t sorted < <(printf '%s\n' "${chunks[@]}" | sort -t. -k3 -n)
  simg2img "${sorted[@]}" "$BUILD/super.raw.img"

  say "unpacking vendor_a"
  lpunpack --partition=vendor_a "$BUILD/super.raw.img" "$BUILD" >/dev/null
  rm -f "$BUILD/super.raw.img"
  VENDOR_IMG="$BUILD/vendor_a.img"
elif [ -f "$FIRMWARE" ]; then
  VENDOR_IMG="$FIRMWARE"
else
  die "--firmware is neither a directory nor a file: $FIRMWARE"
fi
[ -f "$VENDOR_IMG" ] || die "vendor image not produced: $VENDOR_IMG"

# ------------------------------------------------------------- extract blobs
# vendor is erofs. fsck.erofs can extract without privileges; otherwise fall
# back to a rootless loop mount via udisks, which is what most desktops allow.
STAGE="$BUILD/vendor"
mkdir -p "$STAGE"

if command -v fsck.erofs >/dev/null; then
  say "extracting vendor.img with fsck.erofs"
  fsck.erofs --extract="$STAGE" "$VENDOR_IMG" >/dev/null 2>&1 || die "fsck.erofs extraction failed"
  SRC="$STAGE"
elif command -v udisksctl >/dev/null; then
  say "mounting vendor.img (rootless, via udisks)"
  LOOP=$(udisksctl loop-setup -r -f "$VENDOR_IMG" 2>&1 | grep -oE '/dev/loop[0-9]+') \
    || die "could not attach loop device"
  MP=$(udisksctl mount -b "$LOOP" 2>&1 | grep -oE '/run/media/[^ ]+$') \
    || { udisksctl loop-delete -b "$LOOP" >/dev/null 2>&1; die "could not mount $LOOP"; }
  cleanup() {
    udisksctl unmount -b "$LOOP" >/dev/null 2>&1 || true
    udisksctl loop-delete -b "$LOOP" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  SRC="$MP"
else
  die "need either erofs-utils (fsck.erofs) or udisksctl to read vendor.img"
fi

PAYLOAD="$BUILD/payload"
mkdir -p "$PAYLOAD/vendor/lib64/soundfx" "$PAYLOAD/vendor/bin/hw"

say "extracting and verifying Dolby libraries"
for rel in "${!WANT[@]}"; do
  [ -f "$SRC/$rel" ] || die "missing in firmware: vendor/$rel (wrong device or wrong ROM?)"
  cp "$SRC/$rel" "$PAYLOAD/vendor/$rel"
  got=$(stat -c %s "$PAYLOAD/vendor/$rel")
  [ "$got" = "${WANT[$rel]}" ] \
    || die "vendor/$rel is $got bytes, expected ${WANT[$rel]} - not stock zorn firmware"
  say "  ok  $rel  ($got)"
done

# ------------------------------------------------------------------ assemble
say "assembling module"
STAGEMOD="$BUILD/module"
cp -a "$REPO/module" "$STAGEMOD"
rm -rf "$STAGEMOD/overlay"
mkdir -p "$STAGEMOD/payload/product/priv-app/LunarisDolby"
cp -a "$PAYLOAD/vendor" "$STAGEMOD/payload/"
cp -a "$REPO/module/overlay/product/etc" "$STAGEMOD/payload/product/"
cp "$APK" "$STAGEMOD/payload/product/priv-app/LunarisDolby/LunarisDolby.apk"

chmod 0755 "$STAGEMOD"/*.sh "$STAGEMOD/payload/vendor/bin/hw/"*

ZIP="$OUT/DolbyZorn-$VERSION.zip"
rm -f "$ZIP"
( cd "$STAGEMOD" && zip -qr "$ZIP" . -x '.*' )

rm -rf "$BUILD"
printf '\nbuilt: %s (%s)\n' "$ZIP" "$(du -h "$ZIP" | cut -f1)"
